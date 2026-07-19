#!/usr/bin/env bash
# =============================================================================
# fix-lightning-mouse-leak.sh
#
# One-shot, idempotent fix for terminal mouse-tracking garbage on Lightning AI
# Studios (and similar code-server + GNU screen + TUI environments).
#
# Symptom
# -------
# Moving the mouse dumps literal junk into the shell / Grok prompt, e.g.:
#   80;5M79;5M77;6M57;10M48;12M40;15M...
#
# Root cause (layers)
# -------------------
# 1. xterm mouse-tracking modes (CSI ?1000/1002/1003/1005/1006/1015 h) make the
#    terminal emit SGR/X10 reports on every motion/click.
# 2. Lightning exports LESS='... --mouse ...' via /settings/.lightningrc, so
#    `less` enables tracking.
# 3. Default vimrc often has `set mouse=a` + `ttymouse=xterm2`.
# 4. Lightning persists shells with GNU screen (/settings/zsh -> screen) using
#    /settings/.screenrc — NOT ~/.screenrc.
# 5. Grok Build TUI enables mouse capture on start (?1000h ... ?1006h). On
#    code-server / screen, those reports are often NOT consumed by the TUI and
#    leak into the input buffer as bare fragments like "80;5M".
#
# Fix strategy (defense in depth)
# -------------------------------
# A. Shell guard: strip --mouse from LESS after Lightning rc; emit mouse-off.
# B. Editor / multiplexer defaults: vim mouse off; screen/tmux mousetrack off.
# C. Immediate CSI disable on all writable PTYs + live screen sessions.
# D. Grok PTY filter: rewrite mouse-enable CSI to disable; strip inbound reports
#    and bare "N;NM" bursts before they reach the TUI.
#
# Usage
# -----
#   bash fix-lightning-mouse-leak.sh              # install + apply
#   bash fix-lightning-mouse-leak.sh --check      # verify only
#   bash fix-lightning-mouse-leak.sh --now        # only immediate CSI off
#   bash fix-lightning-mouse-leak.sh --uninstall  # remove hooks (keep backups)
#
# After install: RESTART any running `grok` process (exit and run `grok` again).
#
# Opt-out of Grok filter (may reintroduce leak):
#   GROK_ALLOW_MOUSE=1 grok
#
# Portable: uses $HOME; does not hard-code a studio name. Safe to re-run.
# =============================================================================
set -euo pipefail

VERSION="1.0.0"
MARKER_BEGIN="# >>> mouse-leak fix (lightning) >>>"
MARKER_END="# <<< mouse-leak fix (lightning) <<<"
# Legacy markers from the first studio fix — still treated as "already installed"
LEGACY_MARKERS=(
  "mouse-leak-guard"
  "mouse-filter PATH"
  "mouse-leak fix (studio)"
)

HOME="${HOME:-$(cd ~ && pwd)}"
export HOME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DO_INSTALL=1
DO_CHECK=0
DO_NOW=0
DO_UNINSTALL=0
VERBOSE=1

log()  { printf '+ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,55p' "$0" | sed 's/^# \?//'
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --check) DO_CHECK=1; DO_INSTALL=0 ;;
    --now) DO_NOW=1; DO_INSTALL=0 ;;
    --uninstall) DO_UNINSTALL=1; DO_INSTALL=0 ;;
    --quiet|-q) VERBOSE=0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
CONFIG_SHELL_DIR="$HOME/.config/shell"
LOCAL_BIN="$HOME/.local/bin"
GUARD_SH="$CONFIG_SHELL_DIR/mouse-leak-guard.sh"
FILTER_PY="$LOCAL_BIN/grok-mouse-filter.py"
MOUSE_OFF_BIN="$LOCAL_BIN/mouse-tracking-off"
GROK_WRAPPER_LOCAL="$LOCAL_BIN/grok"
GROK_BIN_DIR="$HOME/.grok/bin"
GROK_REAL_CANDIDATES=(
  "$HOME/.grok/downloads/grok-linux-x86_64"
  "$HOME/.grok/downloads/grok"
  "$GROK_BIN_DIR/grok.real"
)
LIGHTNING_SCREENRC="/settings/.screenrc"
LIGHTNING_RC="/settings/.lightningrc"

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# ---------------------------------------------------------------------------
# Immediate: disable mouse tracking on this machine right now
# ---------------------------------------------------------------------------
mouse_off_bytes() {
  # ESC [ ? <mode> l for each common mouse mode
  printf '\033[?1000l\033[?1002l\033[?1003l\033[?1005l\033[?1006l\033[?1015l'
}

apply_now() {
  log "Emitting mouse-off CSI (modes 1000/1002/1003/1005/1006/1015)"
  local payload
  payload="$(mouse_off_bytes)"

  # Current tty
  if { true >/dev/tty; } 2>/dev/null; then
    printf '%s' "$payload" >/dev/tty 2>/dev/null || true
  fi

  # All writable user PTYs
  local pts
  for pts in /dev/pts/*; do
    [ -e "$pts" ] || continue
    [ -w "$pts" ] || continue
    printf '%s' "$payload" >"$pts" 2>/dev/null || true
  done

  # Live GNU screen sessions
  if command -v screen >/dev/null 2>&1; then
    local sock name
    for sock in /run/screen/S-"$(id -un)"/* /run/screen/S-"${USER:-}"/*; do
      [ -e "$sock" ] || continue
      name="$(basename "$sock")"
      screen -S "$name" -X eval 'mousetrack off' 2>/dev/null || true
      screen -S "$name" -X stuff "$payload" 2>/dev/null || true
    done
  fi

  # Neutralize LESS in this process (exported to children of this script only)
  if [ -n "${LESS-}" ]; then
    LESS="$(printf '%s' "$LESS" | awk '{
      out=""
      for(i=1;i<=NF;i++){
        if($i=="--mouse" || $i ~ /^--wheel-lines=/) continue
        out=(out==""?$i:out" "$i)
      }
      printf "%s", out
    }')"
    export LESS
    log "Sanitized LESS for this process: ${LESS:-<empty>}"
  fi
  log "Immediate mouse-off applied"
}

# ---------------------------------------------------------------------------
# File install helpers (idempotent marker blocks)
# ---------------------------------------------------------------------------
ensure_dir() { mkdir -p "$1"; }

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local b="${f}.bak.mouse-leak.$(date +%Y%m%d%H%M%S)"
  cp -a "$f" "$b"
  log "Backup: $b"
}

# Remove a marked block between MARKER_BEGIN and MARKER_END (inclusive).
strip_marked_block() {
  local f="$1"
  [ -f "$f" ] || return 0
  # Also strip legacy studio markers if present
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    /# >>> mouse-leak-guard >>>/ {skip=1; next}
    /# <<< mouse-leak-guard <<</ {skip=0; next}
    /# >>> mouse-filter PATH >>>/ {skip=1; next}
    /# <<< mouse-filter PATH <<</ {skip=0; next}
    /# >>> mouse-leak fix \(studio\) >>>/ {skip=1; next}
    /# <<< mouse-leak fix \(studio\) <<</ {skip=0; next}
    !skip {print}
  ' "$f" >"${f}.tmp.$$"
  mv "${f}.tmp.$$" "$f"
}

append_marked_block() {
  local f="$1"
  local body="$2"
  touch "$f"
  strip_marked_block "$f"
  {
    printf '\n%s\n' "$MARKER_BEGIN"
    printf '%s\n' "$body"
    printf '%s\n' "$MARKER_END"
  } >>"$f"
  log "Updated: $f"
}

# ---------------------------------------------------------------------------
# Payload: shell guard
# ---------------------------------------------------------------------------
install_guard_sh() {
  ensure_dir "$CONFIG_SHELL_DIR"
  cat >"$GUARD_SH" <<'EOF'
# mouse-leak-guard.sh — strip LESS --mouse and disable xterm mouse modes
# Installed by fix-lightning-mouse-leak.sh — safe to re-install.

sanitize_less_value() {
  printf '%s' "$1" | awk '{
    out = ""
    for (i = 1; i <= NF; i++) {
      if ($i == "--mouse" || $i ~ /^--wheel-lines=/) continue
      out = (out == "" ? $i : out " " $i)
    }
    printf "%s", out
  }'
}

mouse_tracking_off_payload() {
  printf '%s' \
    $'\033[?1000l' \
    $'\033[?1002l' \
    $'\033[?1003l' \
    $'\033[?1005l' \
    $'\033[?1006l' \
    $'\033[?1015l'
}

apply_mouse_tracking_off() {
  _mlg_payload=$(mouse_tracking_off_payload)
  if [ -n "${1-}" ]; then
    { printf '%s' "$_mlg_payload" >"$1"; } 2>/dev/null || true
  elif { true >/dev/tty; } 2>/dev/null; then
    { printf '%s' "$_mlg_payload" >/dev/tty; } 2>/dev/null || true
  else
    printf '%s' "$_mlg_payload"
  fi
  unset _mlg_payload
}

export_sanitized_less() {
  if [ -n "${LESS+x}" ]; then
    LESS=$(sanitize_less_value "$LESS")
    export LESS
  fi
}

mouse_leak_guard_init() {
  export_sanitized_less
  if [ -t 1 ] || { true >/dev/tty; } 2>/dev/null; then
    apply_mouse_tracking_off
  fi
  mouse_off() {
    apply_mouse_tracking_off
    export_sanitized_less
    echo "mouse tracking disabled; LESS=${LESS-<unset>}" >&2
  }
}
EOF
  log "Wrote $GUARD_SH"
}

install_mouse_off_bin() {
  ensure_dir "$LOCAL_BIN"
  cat >"$MOUSE_OFF_BIN" <<EOF
#!/usr/bin/env bash
# mouse-tracking-off — emit CSI disable for xterm mouse modes; sanitize LESS
set -euo pipefail
GUARD="\${HOME}/.config/shell/mouse-leak-guard.sh"
[ -f "\$GUARD" ] || { echo "missing \$GUARD" >&2; exit 1; }
# shellcheck source=/dev/null
. "\$GUARD"
if [ "\${1-}" = "--log" ] && [ -n "\${2-}" ]; then
  payload=\$(mouse_tracking_off_payload)
  {
    echo "payload_len=\${#payload}"
    echo -n "payload_hex="
    printf '%s' "\$payload" | od -An -tx1 | tr -s ' ' | sed 's/^ //'
    echo
    echo "modes_disabled=1000,1002,1003,1005,1006,1015"
  } >"\$2"
fi
if { true >/dev/tty; } 2>/dev/null; then
  apply_mouse_tracking_off
else
  mouse_tracking_off_payload >/dev/null
fi
export_sanitized_less
[ -t 1 ] || echo "mouse-tracking-off: disabled modes 1000,1002,1003,1005,1006,1015; LESS sanitized" >&2
EOF
  chmod +x "$MOUSE_OFF_BIN"
  log "Wrote $MOUSE_OFF_BIN"
}

# ---------------------------------------------------------------------------
# Payload: Grok PTY mouse filter (the critical fix for Grok TUI)
# ---------------------------------------------------------------------------
install_filter_py() {
  ensure_dir "$LOCAL_BIN"
  # Prefer sibling file shipped in the git repo (keeps filter logic in one place).
  if [ -f "$SCRIPT_DIR/grok-mouse-filter.py" ]; then
    cp "$SCRIPT_DIR/grok-mouse-filter.py" "$FILTER_PY"
    chmod +x "$FILTER_PY"
    log "Wrote $FILTER_PY (from repo grok-mouse-filter.py)"
    return 0
  fi
  cat >"$FILTER_PY" <<'PY'
#!/usr/bin/env python3
"""PTY wrapper: stop TUI apps (Grok) from enabling terminal mouse tracking.

On Lightning Studio (code-server + GNU screen), Grok's mouse-enable CSI causes
every mouse move to leak as text like ``80;5M79;5M...`` into the prompt.

This wrapper:
  1. Runs the real binary under a PTY.
  2. Rewrites mouse *enable* CSI (?NNNNh) to *disable* (?NNNNl).
  3. Strips inbound mouse reports and bare ``N;NM`` bursts from stdin.
  4. Emits a full mouse-off sequence on start and exit.
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
import tty

MOUSE_MODES = (1000, 1002, 1003, 1005, 1006, 1015)
MOUSE_MODE_SET = {str(m).encode() for m in MOUSE_MODES}
DECSET_RE = re.compile(rb"\x1b\[\?([0-9;]+)([hl])")
MOUSE_IN_RE = re.compile(
    rb"(?:"
    rb"\x1b\[<\d+(?:;\d+)*[Mm]"
    rb"|\x1b\[\d+;\d+(?:;\d+)*[Mm]"
    rb"|\x1b\[M[\x00-\xff]{3}"
    rb")"
)
BARE_MOUSE_RE = re.compile(rb"(?:\d{1,4};\d{1,4}[Mm]){2,}")
INCOMPLETE_ESC_RE = re.compile(
    rb"\x1b(?:\[[0-9;?/<]*[a-zA-Z~]|\].*?(?:\x07|\x1b\\)|.)\Z"
)


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
    data = MOUSE_IN_RE.sub(b"", data)
    data = BARE_MOUSE_RE.sub(b"", data)
    return data


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


def _split_hold(buf: bytes) -> tuple[bytes, bytes]:
    esc = buf.rfind(b"\x1b")
    if esc >= 0 and not INCOMPLETE_ESC_RE.search(buf[esc:]):
        return buf[:esc], buf[esc:]
    return buf, b""


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
        while True:
            try:
                readable, _, _ = select.select([master_fd, stdin_fd], [], [], 0.2)
            except (InterruptedError, select.error):
                continue

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
                filtered, in_buf = _split_hold(filtered)
                if filtered:
                    try:
                        os.write(master_fd, filtered)
                    except OSError:
                        break

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
                converted, out_buf = _split_hold(converted)
                if converted:
                    try:
                        os.write(stdout_fd, converted)
                    except OSError:
                        break

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
PY
  chmod +x "$FILTER_PY"
  log "Wrote $FILTER_PY"
}

resolve_grok_real() {
  local c
  for c in "${GROK_REAL_CANDIDATES[@]}"; do
    if [ -f "$c" ] && [ -x "$c" ]; then
      # If it's our wrapper script, skip
      if head -1 "$c" 2>/dev/null | grep -q 'python\|bash'; then
        # might be wrapper — only accept ELF
        if file "$c" 2>/dev/null | grep -qi 'ELF'; then
          printf '%s' "$c"
          return 0
        fi
        continue
      fi
      printf '%s' "$c"
      return 0
    fi
  done
  # Follow current grok if it's a symlink to a real binary
  if [ -L "$GROK_BIN_DIR/grok" ]; then
    local t
    t="$(readlink -f "$GROK_BIN_DIR/grok" 2>/dev/null || true)"
    if [ -n "$t" ] && [ -x "$t" ] && file "$t" 2>/dev/null | grep -qi 'ELF'; then
      printf '%s' "$t"
      return 0
    fi
  fi
  # Search downloads
  if [ -d "$HOME/.grok/downloads" ]; then
    c="$(find "$HOME/.grok/downloads" -type f -name 'grok*' -perm -111 2>/dev/null | head -1 || true)"
    if [ -n "$c" ] && file "$c" 2>/dev/null | grep -qi 'ELF'; then
      printf '%s' "$c"
      return 0
    fi
  fi
  return 1
}

install_grok_wrappers() {
  ensure_dir "$LOCAL_BIN"
  local real=""
  if real="$(resolve_grok_real)"; then
    log "Found Grok binary: $real"
  else
    warn "Grok binary not found — installing filter + wrappers for when Grok is installed later"
    real="$HOME/.grok/downloads/grok-linux-x86_64"
  fi

  # Local PATH wrapper (always first in PATH after our hook)
  cat >"$GROK_WRAPPER_LOCAL" <<EOF
#!/usr/bin/env bash
# Grok entrypoint with mouse-leak PTY filter (fix-lightning-mouse-leak.sh)
set -euo pipefail
REAL="\${GROK_REAL_BIN:-$real}"
FILTER="\${GROK_MOUSE_FILTER:-$FILTER_PY}"
if [ "\${GROK_ALLOW_MOUSE:-0}" = "1" ]; then
  exec "\$REAL" "\$@"
fi
if [ ! -x "\$REAL" ]; then
  echo "grok: real binary not found at \$REAL" >&2
  echo "Set GROK_REAL_BIN=/path/to/grok-linux-x86_64" >&2
  exit 127
fi
exec python3 "\$FILTER" "\$REAL" "\$@"
EOF
  chmod +x "$GROK_WRAPPER_LOCAL"
  log "Wrote $GROK_WRAPPER_LOCAL"

  # ~/.grok/bin/grok — preferred by grok installer PATH
  if [ -d "$GROK_BIN_DIR" ] || [ -x "$real" ] || [ -d "$HOME/.grok" ]; then
    ensure_dir "$GROK_BIN_DIR"
    # Preserve real binary as grok.real if current grok is ELF symlink/binary
    if [ -e "$GROK_BIN_DIR/grok" ]; then
      if file "$GROK_BIN_DIR/grok" 2>/dev/null | grep -qi 'ELF'; then
        # Running process may hold the inode; replace via unlink
        if [ ! -e "$GROK_BIN_DIR/grok.real" ]; then
          cp -a "$GROK_BIN_DIR/grok" "$GROK_BIN_DIR/grok.real" 2>/dev/null \
            || ln -sfn "$(readlink -f "$GROK_BIN_DIR/grok" 2>/dev/null || echo "$real")" \
                 "$GROK_BIN_DIR/grok.real"
        fi
      fi
      rm -f "$GROK_BIN_DIR/grok"
    fi
    if [ -x "$real" ] && [ ! -e "$GROK_BIN_DIR/grok.real" ]; then
      ln -sfn "$real" "$GROK_BIN_DIR/grok.real" 2>/dev/null || true
    fi
    cat >"$GROK_BIN_DIR/grok" <<EOF
#!/usr/bin/env bash
# Grok entrypoint with mouse-leak PTY filter (fix-lightning-mouse-leak.sh)
set -euo pipefail
REAL="\${GROK_REAL_BIN:-$real}"
FILTER="\${GROK_MOUSE_FILTER:-$FILTER_PY}"
if [ "\${GROK_ALLOW_MOUSE:-0}" = "1" ]; then
  exec "\$REAL" "\$@"
fi
if [ ! -x "\$REAL" ]; then
  # Fall back to grok.real symlink
  if [ -x "$GROK_BIN_DIR/grok.real" ]; then
    REAL="$GROK_BIN_DIR/grok.real"
  else
    echo "grok: real binary not found at \$REAL" >&2
    exit 127
  fi
fi
exec python3 "\$FILTER" "\$REAL" "\$@"
EOF
    chmod +x "$GROK_BIN_DIR/grok"
    log "Wrote $GROK_BIN_DIR/grok"

    # agent is often the same binary
    if [ -L "$GROK_BIN_DIR/agent" ] || [ -f "$GROK_BIN_DIR/agent" ] || [ -x "$real" ]; then
      rm -f "$GROK_BIN_DIR/agent"
      cp "$GROK_BIN_DIR/grok" "$GROK_BIN_DIR/agent"
      chmod +x "$GROK_BIN_DIR/agent"
      log "Wrote $GROK_BIN_DIR/agent (same filter wrapper)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Shell rc / vim / screen / tmux / grok config
# ---------------------------------------------------------------------------
install_shell_rc_hooks() {
  local body
  body=$(cat <<EOF
# After Lightning rc (LESS=...--mouse...): sanitize + disable mouse modes.
if [ -f "\$HOME/.config/shell/mouse-leak-guard.sh" ]; then
  # shellcheck source=/dev/null
  . "\$HOME/.config/shell/mouse-leak-guard.sh"
  mouse_leak_guard_init
fi
# Prefer filtered grok + helpers.
export PATH="\$HOME/.local/bin:\$HOME/.grok/bin:\$PATH"
EOF
)
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    touch "$rc"
    append_marked_block "$rc" "$body"
  done
}

install_vimrc() {
  local f="$HOME/.vimrc"
  if [ -f "$f" ] && grep -q 'mouse-leak fix' "$f" 2>/dev/null; then
    log "vimrc already patched"
    return 0
  fi
  if [ -f "$f" ]; then
    backup_file "$f"
  fi
  # Replace active mouse=a / ttymouse settings; keep other user config if any
  if [ -f "$f" ] && grep -qvE '^\s*("|$)|set mouse|ttymouse' "$f"; then
    # Has non-mouse content: strip mouse lines and append our block
    grep -vE '^\s*set mouse=|^\s*set ttymouse=' "$f" >"${f}.tmp.$$" || true
    mv "${f}.tmp.$$" "$f"
    append_marked_block "$f" '" Mouse tracking off — leftover SGR reports look like 80;5M...
set mouse=
" Do not set ttymouse'
  else
    cat >"$f" <<'EOF'
" Installed by fix-lightning-mouse-leak.sh
" mouse=a leaves xterm mouse modes stuck after unclean vim exit.
set mouse=
EOF
    log "Wrote $f"
  fi
}

install_user_screen_tmux() {
  cat >"$HOME/.screenrc" <<'EOF'
# Installed by fix-lightning-mouse-leak.sh
defmousetrack off
mousetrack off
EOF
  log "Wrote $HOME/.screenrc"

  cat >"$HOME/.tmux.conf" <<'EOF'
# Installed by fix-lightning-mouse-leak.sh
set -g mouse off
EOF
  log "Wrote $HOME/.tmux.conf"
}

install_lightning_screenrc() {
  if [ ! -f "$LIGHTNING_SCREENRC" ]; then
    warn "No $LIGHTNING_SCREENRC (not a Lightning shell-persistence host?) — skip"
    return 0
  fi
  if [ ! -w "$LIGHTNING_SCREENRC" ]; then
    warn "Cannot write $LIGHTNING_SCREENRC — put mousetrack off in ~/.screenrc only"
    return 0
  fi
  if grep -q 'mousetrack off' "$LIGHTNING_SCREENRC" 2>/dev/null; then
    log "$LIGHTNING_SCREENRC already has mousetrack off"
    return 0
  fi
  backup_file "$LIGHTNING_SCREENRC"
  {
    printf '\n%s\n' "$MARKER_BEGIN"
    echo "# Lightning uses this file (not ~/.screenrc) for persistent zsh sessions."
    echo "defmousetrack off"
    echo "mousetrack off"
    printf '%s\n' "$MARKER_END"
  } >>"$LIGHTNING_SCREENRC"
  log "Patched $LIGHTNING_SCREENRC"
}

install_grok_config() {
  local cfg="$HOME/.grok/config.toml"
  [ -d "$HOME/.grok" ] || return 0
  touch "$cfg"
  if grep -q 'mouse_reporting_toggle' "$cfg" 2>/dev/null; then
    log "Grok config already has mouse_reporting_toggle"
    return 0
  fi
  backup_file "$cfg"
  if grep -q '^\[ui\]' "$cfg" 2>/dev/null; then
    # Insert keys after [ui]
    awk '
      BEGIN{done=0}
      /^\[ui\]/ {print; print "mouse_reporting_toggle = true  # Ctrl+r /toggle-mouse-reporting"; print "mouse_hover = false"; done=1; next}
      {print}
      END{if(!done){print ""; print "[ui]"; print "mouse_reporting_toggle = true"; print "mouse_hover = false"}}
    ' "$cfg" >"${cfg}.tmp.$$"
    mv "${cfg}.tmp.$$" "$cfg"
  else
    cat >>"$cfg" <<'EOF'

[ui]
mouse_reporting_toggle = true
mouse_hover = false
EOF
  fi
  log "Updated $cfg"
}

# ---------------------------------------------------------------------------
# Self-test (no network; exercises real installed functions)
# ---------------------------------------------------------------------------
run_selftest() {
  log "Running self-test..."
  need_cmd python3
  need_cmd awk

  # LESS sanitize
  # shellcheck source=/dev/null
  . "$GUARD_SH"
  local got
  got="$(sanitize_less_value '--no-init --raw-control-chars --mouse --wheel-lines=3')"
  [ "$got" = "--no-init --raw-control-chars" ] || die "sanitize_less_value failed: [$got]"

  # Payload modes
  local pay
  pay="$(mouse_tracking_off_payload | od -An -tx1)"
  echo "$pay" | grep -q '1b 5b 3f 31 30 30 30 6c' || die "payload missing 1000l"

  # Filter unit checks
  python3 - "$FILTER_PY" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read().replace('if __name__ == "__main__":\n    sys.exit(main(sys.argv))\n', '')
ns = {}
exec(compile(src, path, "exec"), ns)
n, f, off = ns["neutralize_output"], ns["filter_input"], ns["mouse_off_payload"]()
out = n(b"\x1b[?1000h\x1b[?1002h\x1b[?1006h")
assert b"?1000h" not in out and b"?1000l" in out
assert n(b"\x1b[?25h") == b"\x1b[?25h"
assert f(b"a\x1b[<32;80;5Mb") == b"ab"
g = b"80;5M79;5M77;6M57;10M"
assert f(g) == b""
for m in (1000, 1002, 1003, 1005, 1006, 1015):
    assert f"?{m}l".encode() in off
print("filter self-test OK")
PY

  # Wrappers mention filter
  grep -q 'grok-mouse-filter\|FILTER' "$GROK_WRAPPER_LOCAL" || die "local grok wrapper missing filter"
  # Fresh shell LESS
  if command -v zsh >/dev/null 2>&1; then
    local less_z
    less_z="$(zsh -ic 'echo $LESS' 2>/dev/null | tail -1 || true)"
    case "$less_z" in
      *--mouse*) die "fresh zsh still has LESS --mouse: $less_z" ;;
    esac
    log "fresh zsh LESS OK: ${less_z:-<empty>}"
  fi
  log "Self-test PASSED"
}

# ---------------------------------------------------------------------------
# Check / uninstall
# ---------------------------------------------------------------------------
run_check() {
  local fail=0
  check() {
    if "$@"; then log "OK: $*"; else warn "FAIL: $*"; fail=1; fi
  }
  [ -f "$GUARD_SH" ] && log "OK: $GUARD_SH" || { warn "missing $GUARD_SH"; fail=1; }
  [ -x "$FILTER_PY" ] && log "OK: $FILTER_PY" || { warn "missing $FILTER_PY"; fail=1; }
  [ -x "$MOUSE_OFF_BIN" ] && log "OK: $MOUSE_OFF_BIN" || { warn "missing $MOUSE_OFF_BIN"; fail=1; }
  [ -x "$GROK_WRAPPER_LOCAL" ] && log "OK: $GROK_WRAPPER_LOCAL" || { warn "missing wrapper"; fail=1; }
  if [ -f "$HOME/.zshrc" ] && grep -q 'mouse-leak-guard\|mouse-leak fix' "$HOME/.zshrc"; then
    log "OK: .zshrc hooked"
  else
    warn "FAIL: .zshrc not hooked"; fail=1
  fi
  if [ -f "$LIGHTNING_SCREENRC" ]; then
    grep -q 'mousetrack off' "$LIGHTNING_SCREENRC" && log "OK: lightning screenrc" || warn "lightning screenrc missing mousetrack off"
  fi
  if command -v zsh >/dev/null 2>&1; then
    local less_z
    less_z="$(zsh -ic 'echo $LESS' 2>/dev/null | tail -1 || true)"
    case "$less_z" in
      *--mouse*) warn "FAIL: LESS still has --mouse ($less_z)"; fail=1 ;;
      *) log "OK: LESS has no --mouse ($less_z)" ;;
    esac
  fi
  # which grok
  if command -v grok >/dev/null 2>&1; then
    local g
    g="$(command -v grok)"
    if head -5 "$g" 2>/dev/null | grep -q 'FILTER\|mouse-filter'; then
      log "OK: grok -> filtered wrapper ($g)"
    elif file "$g" 2>/dev/null | grep -qi 'ELF'; then
      warn "grok is bare ELF (not filtered): $g — re-run install"
      fail=1
    else
      log "OK: grok at $g (check manually)"
    fi
  fi
  [ "$fail" -eq 0 ] || die "check found problems (re-run without --check to fix)"
  log "Check PASSED"
}

run_uninstall() {
  log "Removing hooks (files under .local/bin kept with .disabled suffix)"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$rc" ] && strip_marked_block "$rc" && log "Cleaned $rc"
  done
  if [ -f "$LIGHTNING_SCREENRC" ] && [ -w "$LIGHTNING_SCREENRC" ]; then
    strip_marked_block "$LIGHTNING_SCREENRC"
    # legacy studio marker
    if grep -q 'mouse-leak fix (studio)' "$LIGHTNING_SCREENRC"; then
      awk '
        /# >>> mouse-leak fix \(studio\) >>>/ {skip=1; next}
        /# <<< mouse-leak fix \(studio\) <<</ {skip=0; next}
        !skip {print}
      ' "$LIGHTNING_SCREENRC" >"${LIGHTNING_SCREENRC}.tmp.$$"
      mv "${LIGHTNING_SCREENRC}.tmp.$$" "$LIGHTNING_SCREENRC"
    fi
    log "Cleaned $LIGHTNING_SCREENRC"
  fi
  # Restore grok if grok.real exists
  if [ -e "$GROK_BIN_DIR/grok.real" ]; then
    rm -f "$GROK_BIN_DIR/grok"
    ln -sfn "$(readlink -f "$GROK_BIN_DIR/grok.real" 2>/dev/null || echo "$GROK_BIN_DIR/grok.real")" \
      "$GROK_BIN_DIR/grok" 2>/dev/null \
      || cp -a "$GROK_BIN_DIR/grok.real" "$GROK_BIN_DIR/grok"
    log "Restored $GROK_BIN_DIR/grok from grok.real"
  fi
  for f in "$FILTER_PY" "$MOUSE_OFF_BIN" "$GROK_WRAPPER_LOCAL" "$GUARD_SH"; do
    if [ -e "$f" ]; then
      mv "$f" "${f}.disabled.$(date +%Y%m%d%H%M%S)"
      log "Disabled $f"
    fi
  done
  log "Uninstall done. Restart shells. Restart grok if needed."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "fix-lightning-mouse-leak.sh v$VERSION  HOME=$HOME"

  if [ "$DO_UNINSTALL" -eq 1 ]; then
    run_uninstall
    return 0
  fi

  if [ "$DO_NOW" -eq 1 ]; then
    apply_now
    return 0
  fi

  if [ "$DO_CHECK" -eq 1 ]; then
    run_check
    return 0
  fi

  # Full install
  need_cmd python3
  need_cmd awk
  need_cmd file

  if [ -f "$LIGHTNING_RC" ]; then
    log "Detected Lightning rc: $LIGHTNING_RC"
    if grep -q -- '--mouse' "$LIGHTNING_RC" 2>/dev/null; then
      log "Confirmed Lightning exports LESS with --mouse (we override after source)"
    fi
  else
    warn "No $LIGHTNING_RC — still installing portable mitigations"
  fi

  install_guard_sh
  install_mouse_off_bin
  install_filter_py
  install_grok_wrappers
  install_shell_rc_hooks
  install_vimrc
  install_user_screen_tmux
  install_lightning_screenrc
  install_grok_config
  apply_now
  run_selftest

  cat <<EOF

=============================================================================
INSTALL COMPLETE (v$VERSION)

What was installed
  - $GUARD_SH
  - $MOUSE_OFF_BIN
  - $FILTER_PY          ← critical for Grok TUI
  - $GROK_WRAPPER_LOCAL
  - Shell hooks in ~/.zshrc and ~/.bashrc (after Lightning managed block)
  - ~/.vimrc mouse off, ~/.screenrc / ~/.tmux.conf, optional /settings/.screenrc
  - ~/.grok/config.toml mouse_reporting_toggle (if .grok exists)

IMPORTANT — restart Grok
  Already-running Grok processes still use the old binary path.
  Exit Grok (/exit or Ctrl+C), then:

      grok

Manual reset anytime
      mouse_off
      mouse-tracking-off

Verify later
      bash $0 --check

Allow mouse again (may reintroduce leak)
      GROK_ALLOW_MOUSE=1 grok
=============================================================================
EOF
}

main
