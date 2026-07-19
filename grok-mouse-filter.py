#!/usr/bin/python3
"""PTY 包装器：阻止 TUI 应用（Grok）启用终端鼠标追踪。

注意：请用系统 /usr/bin/python3 运行。Lightning 的 /commands/python3 或
conda 环境的 python 偶发会在 import 标准库时卡住，导致 `grok` 打不开。

在 Lightning Studio（code-server + GNU screen）中，Grok 发出的鼠标启用 CSI
会使每次鼠标移动都以 ``80;5M79;5M...`` 一类文本泄漏到输入框中。

过滤器只移除能从协议上明确识别的鼠标字节。普通文本、粘贴内容、键盘协议、
OSC 剪贴板通信和焦点事件均会保留。
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

# 特意排除 1004：它代表焦点报告，而不是鼠标报告。
MOUSE_MODES = (9, 1000, 1001, 1002, 1003, 1005, 1006, 1007, 1015, 1016)
MOUSE_MODE_SET = {str(m).encode() for m in MOUSE_MODES}
DECSET_RE = re.compile(rb"\x1b\[\?([0-9;]+)([hl])")
MOUSE_IN_RE = re.compile(
    rb"(?:"
    rb"\x1b\[<\d+(?:;\d+)*[Mm]"  # SGR 1006
    rb"|\x1b\[M[\x00-\xff]{3}"  # X10 1000（M 后面恰好有 3 个字节）
    rb")"
)
# 不完整 CSI/SS3 的暂存超时（秒）。必须及时转发单独的 Esc，避免它与下一个按键
#（Ctrl+U、字母等）粘连。
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
    """只剥离带 ESC 前缀、能够明确识别的鼠标报告。

    无法安全判定裸 ``80;5M79;5M`` 一类字节，因为它们可能是键入或粘贴的内容。
    在输出侧阻止鼠标 DECSET，可以从源头阻止新报告，同时不破坏正常输入。
    """
    return MOUSE_IN_RE.sub(b"", data)


def _is_incomplete_esc_suffix(buf: bytes) -> bool:
    """如果缓冲区末尾是不完整且需要暂存的终端转义序列，则返回真。"""
    if not buf:
        return False
    # 查找最后一个 ESC
    esc = buf.rfind(b"\x1b")
    if esc < 0:
        return False
    seq = buf[esc:]
    # 单独的 ESC：超时前视为不完整，之后由调用方转发
    if seq == b"\x1b":
        return True
    # OSC：ESC ] ... BEL 或 ST
    if seq.startswith(b"\x1b]"):
        if seq.endswith(b"\x07") or seq.endswith(b"\x1b\\"):
            return False
        return True
    # SS3：ESC O <结束字节>
    if seq.startswith(b"\x1bO"):
        return len(seq) < 3
    # CSI：ESC [ 参数/中间字节 结束字节（@-~）
    if seq.startswith(b"\x1b["):
        if len(seq) == 2:
            return True
        for i, b in enumerate(seq[2:], start=2):
            if 0x40 <= b <= 0x7E:  # 结束字节
                # 找到结束字节即代表序列完整；其后若有内容则一并转发
                return False
        return True  # 尚未出现结束字节
    # ESC 后跟一个不是 CSI/OSC/SS3 起始字符的字符：
    # 将其视为完整的双字节序列（单独 ESC 已在上方处理；ESC 后跟普通字母
    # 表示 Alt+字母，收齐两个字节即为完整）
    if len(seq) >= 2:
        return False
    return True


def split_hold(buf: bytes) -> tuple[bytes, bytes]:
    """将缓冲区拆成（立即转发内容，暂存内容），只暂存不完整的 ESC 序列。"""
    if not buf:
        return b"", b""
    esc = buf.rfind(b"\x1b")
    if esc < 0:
        return buf, b""
    # 如果末尾没有不完整序列，则全部转发
    if not _is_incomplete_esc_suffix(buf):
        return buf, b""
    # 从最后一个 ESC 开始暂存，先转发前缀
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

            # 超时后转发不完整的键盘 ESC，绝不能与下一个按键粘连
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
