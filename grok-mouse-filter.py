#!/usr/bin/env python3
"""PTY wrapper: stop TUI apps (Grok) from enabling terminal mouse tracking.

On Lightning Studio (code-server + GNU screen), Grok's mouse-enable CSI causes
every mouse move to leak as text like ``80;5M79;5M...`` into the prompt.

Also carefully passes keyboard keys (Esc, Ctrl+U, arrows, etc.) without
gluing bare Esc to the next keystroke.
"""
from __future__ import annotations

import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time
import tty

MOUSE_MODES = (1000, 1002, 1003, 1005, 1006, 1015)
MOUSE_MODE_SET = {str(m).encode() for m in MOUSE_MODES}
DECSET_RE = re.compile(rb"\x1b\[\?([0-9;]+)([hl])")
MOUSE_IN_RE = re.compile(
    rb"(?:"
    rb"\x1b\[<\d+(?:;\d+)*[Mm]"  # SGR 1006
    rb"|\x1b\[M[\x00-\xff]{3}"  # X10 1000 (exactly 3 bytes after M)
    rb")"
)
# Bare leaked motion fragments: 80;5M79;5M... (2+ reports)
BARE_MOUSE_RE = re.compile(rb"(?:\d{1,4};\d{1,4}[Mm]){2,}")

# Incomplete CSI/SS3 hold timeout (seconds). Bare Esc must flush so it is not
# glued to the next key (Ctrl+U, letters, etc.).
HOLD_TIMEOUT_S = 0.05


def mouse_off_payload() -> bytes:
    return b"".join(f"\x1b[?{m}l".encode() for m in MOUSE_MODES)


def neutralize_output(data: bytes) -> bytes:
    def repl(m: re.Match[bytes]) -> bytes:
        modes = m.group(1).split(b";")
        action = m.group(2)
        if not any(x in MOUSE_MODE_SET for x in modes):
            return m.group(0)
        out = b""
        kept: list[bytes] = []
        for mm in modes:
            if mm in MOUSE_MODE_SET:
                out += b"\x1b[?" + mm + b"l"
            elif mm:
                kept.append(mm)
        if kept:
            out += b"\x1b[?" + b";".join(kept) + action
        return out

    return DECSET_RE.sub(repl, data)


def filter_input(data: bytes) -> bytes:
    """Strip mouse reports only — never drop keyboard Esc / CSI / controls."""
    data = MOUSE_IN_RE.sub(b"", data)
    data = BARE_MOUSE_RE.sub(b"", data)
    return data


def _is_incomplete_esc_suffix(buf: bytes) -> bool:
    """True if buf ends with an incomplete terminal escape sequence to hold."""
    if not buf:
        return False
    # Find last ESC
    esc = buf.rfind(b"\x1b")
    if esc < 0:
        return False
    seq = buf[esc:]
    # Bare ESC — incomplete until timeout (caller flushes)
    if seq == b"\x1b":
        return True
    # OSC: ESC ] ... BEL or ST
    if seq.startswith(b"\x1b]"):
        if seq.endswith(b"\x07") or seq.endswith(b"\x1b\\"):
            return False
        return True
    # SS3: ESC O <final>
    if seq.startswith(b"\x1bO"):
        return len(seq) < 3
    # CSI: ESC [ params/intermediates final(@-~)
    if seq.startswith(b"\x1b["):
        if len(seq) == 2:
            return True
        for i, b in enumerate(seq[2:], start=2):
            if 0x40 <= b <= 0x7E:  # final byte
                # Complete when final is the last byte; else junk after final → flush all
                return False
        return True  # no final yet
    # ESC + one other char that is NOT start of CSI/OSC/SS3:
    # treat as complete 2-byte sequence (e.g. ESC alone already handled;
    # ESC followed by plain letter is Alt+letter — complete when we have 2 bytes)
    if len(seq) >= 2:
        return False
    return True


def split_hold(buf: bytes) -> tuple[bytes, bytes]:
    """Split buf into (forward_now, hold). Only hold incomplete ESC sequences."""
    if not buf:
        return b"", b""
    esc = buf.rfind(b"\x1b")
    if esc < 0:
        return buf, b""
    # If nothing incomplete at end, forward all
    if not _is_incomplete_esc_suffix(buf):
        return buf, b""
    # Hold from last ESC; forward prefix
    return buf[:esc], buf[esc:]


def _set_winsize(fd: int, rows: int, cols: int) -> None:
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass


def _get_winsize(fd: int) -> tuple[int, int]:
    try:
        raw = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\x00" * 8)
        rows, cols, _, _ = struct.unpack("HHHH", raw)
        return max(rows, 1), max(cols, 1)
    except OSError:
        return 24, 80


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: grok-mouse-filter.py <real-binary> [args...]", file=sys.stderr)
        return 2
    real_bin = argv[1]
    real_args = argv[1:]
    if not os.path.isfile(real_bin) or not os.access(real_bin, os.X_OK):
        print(f"grok-mouse-filter: not executable: {real_bin}", file=sys.stderr)
        return 127

    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()
    try:
        os.write(stdout_fd, mouse_off_payload())
    except OSError:
        pass

    if not os.isatty(stdin_fd):
        os.execv(real_bin, real_args)

    old_tty = termios.tcgetattr(stdin_fd)
    child_pid = None
    master_fd = None

    def _forward_sig(signum: int, _frame) -> None:
        if child_pid:
            try:
                os.kill(child_pid, signum)
            except OSError:
                pass

    def _on_winch(_signum, _frame) -> None:
        if master_fd is None:
            return
        rows, cols = _get_winsize(stdin_fd)
        _set_winsize(master_fd, rows, cols)
        if child_pid:
            try:
                os.kill(child_pid, signal.SIGWINCH)
            except OSError:
                pass

    try:
        tty.setraw(stdin_fd)
        child_pid, master_fd = pty.fork()
        if child_pid == 0:
            os.execv(real_bin, real_args)

        rows, cols = _get_winsize(stdin_fd)
        _set_winsize(master_fd, rows, cols)
        signal.signal(signal.SIGWINCH, _on_winch)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGQUIT):
            signal.signal(sig, _forward_sig)

        fl = fcntl.fcntl(master_fd, fcntl.F_GETFL)
        fcntl.fcntl(master_fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
        fl_in = fcntl.fcntl(stdin_fd, fcntl.F_GETFL)
        fcntl.fcntl(stdin_fd, fcntl.F_SETFL, fl_in | os.O_NONBLOCK)

        in_buf = b""
        out_buf = b""
        in_hold_since: float | None = None
        out_hold_since: float | None = None

        while True:
            try:
                readable, _, _ = select.select([master_fd, stdin_fd], [], [], 0.02)
            except (InterruptedError, select.error):
                continue

            now = time.monotonic()

            if stdin_fd in readable:
                try:
                    chunk = os.read(stdin_fd, 8192)
                except OSError as e:
                    if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                        chunk = b""
                    else:
                        break
                if not chunk:
                    try:
                        os.close(master_fd)
                    except OSError:
                        pass
                    break
                in_buf += chunk
                filtered = filter_input(in_buf)
                forward, in_buf = split_hold(filtered)
                if in_buf:
                    in_hold_since = in_hold_since or now
                else:
                    in_hold_since = None
                if forward:
                    try:
                        os.write(master_fd, forward)
                    except OSError:
                        break

            # Flush incomplete keyboard ESC after timeout (do NOT glue to next key)
            if in_buf and in_hold_since is not None and (now - in_hold_since) >= HOLD_TIMEOUT_S:
                try:
                    os.write(master_fd, in_buf)
                except OSError:
                    break
                in_buf = b""
                in_hold_since = None

            if master_fd in readable:
                try:
                    chunk = os.read(master_fd, 8192)
                except OSError as e:
                    if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                        chunk = b""
                    else:
                        break
                if not chunk:
                    break
                out_buf += chunk
                converted = neutralize_output(out_buf)
                forward, out_buf = split_hold(converted)
                if out_buf:
                    out_hold_since = out_hold_since or now
                else:
                    out_hold_since = None
                if forward:
                    try:
                        os.write(stdout_fd, forward)
                    except OSError:
                        break

            if out_buf and out_hold_since is not None and (now - out_hold_since) >= HOLD_TIMEOUT_S:
                try:
                    os.write(stdout_fd, out_buf)
                except OSError:
                    break
                out_buf = b""
                out_hold_since = None

        try:
            _, status = os.waitpid(child_pid, 0)
        except OSError:
            status = 0
        if os.WIFEXITED(status):
            return os.WEXITSTATUS(status)
        if os.WIFSIGNALED(status):
            return 128 + os.WTERMSIG(status)
        return 0
    finally:
        try:
            os.write(stdout_fd, mouse_off_payload())
        except OSError:
            pass
        try:
            termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_tty)
        except Exception:
            pass
        if master_fd is not None:
            try:
                os.close(master_fd)
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main(sys.argv))
