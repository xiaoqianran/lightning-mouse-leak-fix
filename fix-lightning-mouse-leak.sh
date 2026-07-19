#!/usr/bin/env bash
# =============================================================================
# fix-lightning-mouse-leak.sh
#
# 用于修复 Lightning AI Studio（以及类似的 code-server + GNU screen + TUI
# 环境）终端鼠标追踪乱码的一次性、幂等脚本。
#
# 问题表现
# -------
# 移动鼠标时，Shell 或 Grok 输入框会出现如下原始乱码：
#   80;5M79;5M77;6M57;10M48;12M40;15M...
#
# 根本原因（分层说明）
# -------------------
# 1. xterm 鼠标追踪模式（CSI ?1000/1002/1003/1005/1006/1015 h）会让终端在
#    每次鼠标移动或点击时发送 SGR/X10 报告。
# 2. Lightning 通过 /settings/.lightningrc 导出 LESS='... --mouse ...'，
#    导致 `less` 启用鼠标追踪。
# 3. 默认 vimrc 中经常包含 `set mouse=a` 和 `ttymouse=xterm2`。
# 4. Lightning 使用 GNU screen（/settings/zsh -> screen）保持 Shell 会话，
#    实际读取的是 /settings/.screenrc，而不是 ~/.screenrc。
# 5. Grok Build TUI 启动时会启用鼠标捕获（?1000h ... ?1006h）。在
#    code-server / screen 下，这些报告经常未被 TUI 消费，并以 "80;5M"
#    一类裸片段泄漏到输入缓冲区。
#
# 修复策略（多层防护）
# -------------------------------
# A. Shell 防护：在 Lightning 启动脚本之后移除 LESS 中的 --mouse，并发送关闭鼠标序列。
# B. 编辑器和终端复用器默认值：关闭 vim、screen 和 tmux 的鼠标功能。
# C. 立即向所有可写 PTY 和活动 screen 会话发送 CSI 禁用序列。
# D. Grok PTY 过滤器：将鼠标启用 CSI 改写为禁用，并过滤明确的输入鼠标报告。
#
# 用法
# -----
#   bash fix-lightning-mouse-leak.sh              # 安装并应用
#   bash fix-lightning-mouse-leak.sh --check      # 仅验证
#   bash fix-lightning-mouse-leak.sh --now        # 仅立即关闭 CSI 鼠标模式
#   bash fix-lightning-mouse-leak.sh --uninstall  # 移除钩子（保留备份）
#
# 安装后请重新启动所有正在运行的 `grok` 进程（退出后再次运行 `grok`）。
#
# 临时绕过 Grok 过滤器（可能再次出现乱码）：
#   GROK_ALLOW_MOUSE=1 grok
#
# 可移植：只使用 $HOME，不写死 Studio 名称，可以安全地重复运行。
# =============================================================================
set -euo pipefail

VERSION="2.5.0"
# Must appear in grok-wrapper.sh header; --check requires this (not bare ELF).
WRAPPER_IDENTITY="mouse-leak-filter-entry"
MARKER_BEGIN="# >>> mouse-leak fix (lightning) >>>"
MARKER_END="# <<< mouse-leak fix (lightning) <<<"
# 首版 Studio 修复所用的旧标记，仍按“已安装”处理
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
# 路径
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
LIGHTNING_SCREENRC="${LIGHTNING_SCREENRC:-/settings/.screenrc}"
LIGHTNING_RC="${LIGHTNING_RC:-/settings/.lightningrc}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# ---------------------------------------------------------------------------
# 立即操作：马上关闭当前机器上的鼠标追踪
# ---------------------------------------------------------------------------
mouse_off_bytes() {
  # 为每种常见鼠标模式生成 ESC [ ? <模式> l
  printf '\033[?9l\033[?1000l\033[?1001l\033[?1002l\033[?1003l\033[?1005l\033[?1006l\033[?1007l\033[?1015l\033[?1016l'
}

# True when path is a filtered shell wrapper (identity marker), not a bare ELF.
is_filtered_grok_entry() {
  local g="$1"
  [ -n "$g" ] && [ -e "$g" ] && [ -r "$g" ] || return 1
  # Symlink to vendor ELF must fail (file without -L often says "symbolic link").
  if is_elf_file "$g"; then
    return 1
  fi
  # Also reject if resolved target is ELF (broken wrapper that is a symlink chain).
  local resolved
  resolved="$(readlink -f "$g" 2>/dev/null || printf '%s' "$g")"
  if [ -n "$resolved" ] && [ "$resolved" != "$g" ] && is_elf_file "$resolved"; then
    return 1
  fi
  grep -q "$WRAPPER_IDENTITY" "$g" 2>/dev/null
}

# List PIDs of running grok processes that are NOT under the PTY filter parent.
# Prints one "pid|exe|ppid|parent_comm" line per unfiltered process.
list_unfiltered_grok_pids() {
  local pid exe ppid pcomm cmdline
  for pid in $(ps -eo pid=,comm= 2>/dev/null | awk '$2=="grok"{print $1}'); do
    [ -r "/proc/$pid/exe" ] || continue
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    [ -n "$exe" ] || continue
    # Filter parent is python running grok-mouse-filter; child ELF is OK.
    ppid="$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)"
    pcomm=""
    if [ -n "$ppid" ] && [ -r "/proc/$ppid/cmdline" ]; then
      cmdline="$(tr '\0' ' ' <"/proc/$ppid/cmdline" 2>/dev/null || true)"
      case "$cmdline" in
        *grok-mouse-filter*) continue ;;  # filtered child — good
      esac
      pcomm="$(cat "/proc/$ppid/comm" 2>/dev/null || true)"
    fi
    # Top-level process that is the vendor ELF (or named grok) without filter parent
    if is_elf_file "$exe" || [[ "$exe" == *grok* ]]; then
      printf '%s|%s|%s|%s\n' "$pid" "$exe" "${ppid:-?}" "${pcomm:-?}"
    fi
  done
}

warn_running_unfiltered_grok() {
  local line count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
    warn "Running unfiltered Grok (must restart): $line"
  done < <(list_unfiltered_grok_pids || true)
  if [ "$count" -gt 0 ]; then
    warn "Exit those Grok sessions (/exit or Ctrl+C), then run: hash -r; grok"
    warn "Already-running unfiltered TUI cannot be hot-patched."
  fi
  return 0
}

apply_now() {
  log "Emitting mouse-off CSI (only to real /dev/tty — never spray all PTYs)"
  local payload
  payload="$(mouse_off_bytes)"
  # Only the current controlling terminal. Writing to every /dev/pts dumps
  # visible garbage (1000l1002l...) into interactive shells.
  if [ -w /dev/tty ] 2>/dev/null; then
    { printf '%s' "$payload" >/dev/tty; } 2>/dev/null || true
  fi
  if command -v screen >/dev/null 2>&1; then
    local sock name
    for sock in /run/screen/S-"$(id -un)"/* /run/screen/S-"${USER:-}"/*; do
      [ -e "$sock" ] || continue
      name="$(basename "$sock")"
      screen -S "$name" -X eval 'mousetrack off' 2>/dev/null || true
      log "screen mousetrack off: $name"
    done
  fi
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
  export OPENCODE_DISABLE_MOUSE=1
  log "Set OPENCODE_DISABLE_MOUSE=1 for this process"
  # Prefer filtered entry in *this* shell; hash -r so PATH picks up new wrapper.
  if [ -x "$GROK_WRAPPER_LOCAL" ]; then
    hash -r 2>/dev/null || true
    log "PATH tip: ensure $LOCAL_BIN is before $GROK_BIN_DIR (hooks do this in new shells)"
  fi
  warn_running_unfiltered_grok
  log "Immediate mouse-off applied"
}


# ---------------------------------------------------------------------------
# 文件安装辅助函数（幂等标记块）
# ---------------------------------------------------------------------------
ensure_dir() { mkdir -p "$1"; }

# Replace the directory entry itself instead of opening the destination for
# writing. This is security- and data-safety-critical: ~/.local is shared by
# Lightning Studios and ~/.local/bin/grok may be a symlink. A plain
# `cp source "$GROK_WRAPPER_LOCAL"` would follow that symlink and could
# overwrite the vendor ELF that it points to.
atomic_install_file() {
  local src="$1" dst="$2" mode="${3:-755}" tmp
  tmp="${dst}.tmp.$$"
  rm -f "$tmp"
  cp "$src" "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dst"
}

is_elf_file() {
  local f="$1" magic
  [ -f "$f" ] && [ -r "$f" ] && [ -x "$f" ] || return 1
  magic="$(LC_ALL=C head -c 4 "$f" 2>/dev/null)" || return 1
  [ "$magic" = $'\x7fELF' ]
}

file_identity() {
  # Follow symlinks: an accidental write through ~/.local/bin/grok changes
  # the target's size/mtime even though the symlink itself looks unchanged.
  stat -Lc '%d:%i:%s:%Y' "$1" 2>/dev/null
}

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local b="${f}.bak.mouse-leak.$(date +%Y%m%d%H%M%S)"
  cp -a "$f" "$b"
  log "Backup: $b"
}

# 移除 MARKER_BEGIN 与 MARKER_END 之间的标记块（包含边界行）。
strip_marked_block() {
  local f="$1"
  [ -f "$f" ] || return 0
  # 同时移除可能存在的旧版 Studio 标记
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
# 安装内容：Shell 防护脚本
# ---------------------------------------------------------------------------
install_guard_sh() {
  ensure_dir "$CONFIG_SHELL_DIR"
  cat >"$GUARD_SH" <<'EOF'
# mouse-leak-guard.sh——移除 LESS 中的 --mouse 并关闭 xterm 鼠标模式
# 由 fix-lightning-mouse-leak.sh 安装，可安全地重复安装。

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
    $'\033[?9l' \
    $'\033[?1000l' \
    $'\033[?1001l' \
    $'\033[?1002l' \
    $'\033[?1003l' \
    $'\033[?1005l' \
    $'\033[?1006l' \
    $'\033[?1007l' \
    $'\033[?1015l' \
    $'\033[?1016l'
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
# mouse-tracking-off——发送 xterm 鼠标模式的 CSI 禁用序列并清理 LESS
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
    echo "modes_disabled=9,1000,1001,1002,1003,1005,1006,1007,1015,1016"
  } >"\$2"
fi
if { true >/dev/tty; } 2>/dev/null; then
  apply_mouse_tracking_off
else
  mouse_tracking_off_payload >/dev/null
fi
export_sanitized_less
[ -t 1 ] || echo "mouse-tracking-off: mouse modes disabled; LESS sanitized" >&2
EOF
  chmod +x "$MOUSE_OFF_BIN"
  log "Wrote $MOUSE_OFF_BIN"
}

# ---------------------------------------------------------------------------
# 安装内容：Grok PTY 鼠标过滤器（Grok TUI 的关键修复）
# ---------------------------------------------------------------------------
install_filter_py() {
  ensure_dir "$LOCAL_BIN"
  # 优先使用 Git 仓库随附的同目录文件，确保过滤逻辑只有一份来源。
  if [ -f "$SCRIPT_DIR/grok-mouse-filter.py" ]; then
    cp "$SCRIPT_DIR/grok-mouse-filter.py" "$FILTER_PY"
    chmod +x "$FILTER_PY"
    log "Wrote $FILTER_PY (from repo grok-mouse-filter.py)"
    return 0
  fi
  die "missing $SCRIPT_DIR/grok-mouse-filter.py (install from the complete repository, not the shell script alone)"
  # 下方内容只为兼容旧打包副本而保留；v2 不会执行，避免静默安装过期的内嵌过滤器。
  cat >"$FILTER_PY" <<'PY'
#!/usr/bin/env python3
"""PTY 包装器：阻止 TUI 应用（Grok）启用终端鼠标追踪。

在 Lightning Studio（code-server + GNU screen）中，Grok 发出的鼠标启用 CSI
会使每次鼠标移动都以 ``80;5M79;5M...`` 一类文本泄漏到输入框中。

此包装器会：
  1. 在 PTY 下运行真实二进制文件。
  2. 将鼠标“启用”CSI（?NNNNh）改写为“禁用”（?NNNNl）。
  3. 从标准输入中剥离鼠标报告和裸 ``N;NM`` 报告串。
  4. 在启动及退出时发送完整的鼠标关闭序列。
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
    if is_elf_file "$c"; then
      printf '%s' "$c"
      return 0
    fi
  done
  # 如果当前 grok 是指向真实二进制文件的符号链接，则跟随该链接
  if [ -L "$GROK_BIN_DIR/grok" ]; then
    local t
    t="$(readlink -f "$GROK_BIN_DIR/grok" 2>/dev/null || true)"
    if [ -n "$t" ] && is_elf_file "$t"; then
      printf '%s' "$t"
      return 0
    fi
  fi
  # 搜索下载目录
  if [ -d "$HOME/.grok/downloads" ]; then
    c="$(find "$HOME/.grok/downloads" -type f -name 'grok*' -perm -111 2>/dev/null | head -1 || true)"
    if [ -n "$c" ] && is_elf_file "$c"; then
      printf '%s' "$c"
      return 0
    fi
  fi
  return 1
}

install_grok_wrappers() {
  local real="" real_id_before="" real_id_after=""
  ensure_dir "$LOCAL_BIN"
  if real="$(resolve_grok_real)"; then
    real="$(readlink -f "$real" 2>/dev/null || printf '%s' "$real")"
    real_id_before="$(file_identity "$real")"
    log "Found Grok binary: $real ($(wc -c <"$real" | tr -d ' ') bytes)"
  else
    warn "Grok binary not found yet (or not a real ELF) — installing smart wrapper anyway"
  fi

  if [ -f "$GROK_BIN_DIR/grok" ] && grep -qE 'mouse-leak PTY filter|Grok entry \+ mouse-leak' "$GROK_BIN_DIR/grok" 2>/dev/null; then
    rm -f "$GROK_BIN_DIR/grok"
    if real="$(resolve_grok_real)"; then
      ln -sfn "$real" "$GROK_BIN_DIR/grok"
    fi
    log "Restored vendor Grok entrypoint (v1 migration)"
  fi

  local src_wrap="$SCRIPT_DIR/grok-wrapper.sh"
  if [ ! -f "$src_wrap" ]; then
    die "missing $src_wrap (re-clone https://github.com/xiaoqianran/lightning-mouse-leak-fix)"
  fi
  atomic_install_file "$src_wrap" "$GROK_WRAPPER_LOCAL" 755
  if ! is_filtered_grok_entry "$GROK_WRAPPER_LOCAL"; then
    die "installed wrapper missing identity marker '$WRAPPER_IDENTITY': $GROK_WRAPPER_LOCAL"
  fi
  log "Wrote $GROK_WRAPPER_LOCAL atomically (v$VERSION; symlinks are not followed)"

  if [ -n "$real" ]; then
    real_id_after="$(file_identity "$real")"
    [ "$real_id_after" = "$real_id_before" ] \
      || die "SAFETY CHECK FAILED: Grok ELF changed during wrapper install: $real"
    is_elf_file "$real" \
      || die "SAFETY CHECK FAILED: Grok binary is no longer an ELF: $real"
    log "Safety OK: vendor Grok ELF was not modified"
  fi

  local cand="$HOME/.grok/downloads/grok-linux-x86_64"
  if [ -e "$cand" ]; then
    local magic sz
    magic=$(head -c 4 "$cand" 2>/dev/null || true)
    sz=$(wc -c <"$cand" 2>/dev/null | tr -d ' ')
    if [ "$magic" != $'\x7fELF' ]; then
      warn "WARNING: $cand is NOT a real Grok ELF (size=${sz}). Often a shell script was copied over the binary."
      warn "Fix: curl -fsSL https://x.ai/cli/install.sh | bash"
    fi
  fi

  if real="$(resolve_grok_real)"; then
    if "$GROK_WRAPPER_LOCAL" --version >/dev/null 2>&1; then
      log "Smoke OK: grok --version via wrapper"
    else
      warn "Smoke FAILED: wrapper could not run --version"
    fi
  else
    warn "No real Grok ELF yet — install Grok first, then: grok --version"
  fi
}

install_shell_rc_hooks() {
  local body
  body=$(cat <<EOF
# 在 Lightning 启动脚本设置 LESS=...--mouse... 后进行清理并关闭鼠标模式。
if [ -f "\$HOME/.config/shell/mouse-leak-guard.sh" ]; then
  # shellcheck source=/dev/null
  . "\$HOME/.config/shell/mouse-leak-guard.sh"
  mouse_leak_guard_init
fi
# 优先使用经过滤的 Grok 和辅助工具。
export PATH="\$HOME/.local/bin:\$HOME/.grok/bin:\$PATH"
# OpenCode 提供原生开关。无需增加额外 PTY，即可保留 attach、run、serve、
# ACP/MCP、插件、管道、剪贴板及键盘协议。
export OPENCODE_DISABLE_MOUSE=1
# Absolute-path grok() bypasses zsh/bash command hash and PATH order so that
# interactive \`grok\` always hits the PTY filter wrapper (not ~/.grok/bin ELF).
if [ -x "\$HOME/.local/bin/grok" ]; then
  grok() {
    "\$HOME/.local/bin/grok" "\$@"
  }
fi
hash -r 2>/dev/null || true
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
  # 替换生效中的 mouse=a/ttymouse 设置，并保留用户的其他配置
  if [ -f "$f" ] && grep -qvE '^\s*("|$)|set mouse|ttymouse' "$f"; then
    # 存在非鼠标配置：移除鼠标设置行后追加本工具的配置块
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
# 由 fix-lightning-mouse-leak.sh 安装
defmousetrack off
mousetrack off
EOF
  log "Wrote $HOME/.screenrc"

  cat >"$HOME/.tmux.conf" <<'EOF'
# 由 fix-lightning-mouse-leak.sh 安装
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
    # 在 [ui] 后插入配置项
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
# 自检（无需网络，直接测试实际安装的函数）
# ---------------------------------------------------------------------------
run_selftest() {
  log "Running self-test..."
  need_cmd python3
  need_cmd awk

  # LESS 清理
  # shellcheck source=/dev/null
  . "$GUARD_SH"
  local got
  got="$(sanitize_less_value '--no-init --raw-control-chars --mouse --wheel-lines=3')"
  [ "$got" = "--no-init --raw-control-chars" ] || die "sanitize_less_value failed: [$got]"

  # 关闭序列所含模式
  local pay
  pay="$(mouse_tracking_off_payload | od -An -tx1)"
  echo "$pay" | grep -q '1b 5b 3f 31 30 30 30 6c' || die "payload missing 1000l"

  # 过滤器单元检查
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
assert f(g) == g, "ordinary/pasted text must never be guessed away"
for m in (1000, 1002, 1003, 1005, 1006, 1015):
    assert f"?{m}l".encode() in off
print("filter self-test OK")
PY

  # 包装器必须带身份标记并引用过滤器（禁止仅靠 head -5 弱匹配）
  is_filtered_grok_entry "$GROK_WRAPPER_LOCAL" \
    || die "local grok wrapper missing identity '$WRAPPER_IDENTITY': $GROK_WRAPPER_LOCAL"
  grep -q 'grok-mouse-filter' "$GROK_WRAPPER_LOCAL" || die "local grok wrapper missing filter path"
  # 新 Shell 中的 LESS / OPENCODE / grok 解析
  if command -v zsh >/dev/null 2>&1; then
    local less_z oc_z g_z
    less_z="$(zsh -ic 'echo $LESS' 2>/dev/null | tail -1 || true)"
    case "$less_z" in
      *--mouse*) die "fresh zsh still has LESS --mouse: $less_z" ;;
    esac
    oc_z="$(zsh -ic 'echo $OPENCODE_DISABLE_MOUSE' 2>/dev/null | tail -1 || true)"
    [ "$oc_z" = "1" ] || die "fresh zsh OPENCODE_DISABLE_MOUSE != 1: [$oc_z]"
    g_z="$(zsh -ic 'command -v grok' 2>/dev/null | tail -1 || true)"
    # With grok() function, command -v may print the function; resolve via type -a / absolute.
    if ! zsh -ic '[ -x "$HOME/.local/bin/grok" ] && grok(){ "$HOME/.local/bin/grok" "$@"; }; type grok' 2>/dev/null | grep -q function; then
      # Fall back: PATH entry must be filtered
      if [ -n "$g_z" ] && [ -e "$g_z" ]; then
        is_filtered_grok_entry "$g_z" || die "fresh zsh grok is not filtered entry: $g_z"
      fi
    fi
    log "fresh zsh LESS OK: ${less_z:-<empty>}; OPENCODE=$oc_z"
  fi
  log "Self-test PASSED"
}

# ---------------------------------------------------------------------------
# 检查与卸载
# ---------------------------------------------------------------------------
run_check() {
  local fail=0
  [ -f "$GUARD_SH" ] && log "OK: $GUARD_SH" || { warn "missing $GUARD_SH"; fail=1; }
  [ -x "$FILTER_PY" ] && log "OK: $FILTER_PY" || { warn "missing $FILTER_PY"; fail=1; }
  [ -x "$MOUSE_OFF_BIN" ] && log "OK: $MOUSE_OFF_BIN" || { warn "missing $MOUSE_OFF_BIN"; fail=1; }
  if [ -x "$GROK_WRAPPER_LOCAL" ] && is_filtered_grok_entry "$GROK_WRAPPER_LOCAL"; then
    log "OK: filtered wrapper $GROK_WRAPPER_LOCAL"
  else
    warn "FAIL: missing or unfiltered wrapper at $GROK_WRAPPER_LOCAL"
    fail=1
  fi
  if [ -f "$HOME/.zshrc" ] && grep -q 'mouse-leak-guard\|mouse-leak fix' "$HOME/.zshrc"; then
    log "OK: .zshrc hooked"
  else
    warn "FAIL: .zshrc not hooked"; fail=1
  fi
  if [ -f "$HOME/.zshrc" ] && grep -q 'grok()' "$HOME/.zshrc" 2>/dev/null; then
    log "OK: .zshrc defines grok() absolute entry"
  else
    warn "FAIL: .zshrc missing grok() function (re-run install)"; fail=1
  fi
  if [ -f "$LIGHTNING_SCREENRC" ]; then
    grep -q 'mousetrack off' "$LIGHTNING_SCREENRC" && log "OK: lightning screenrc" || warn "lightning screenrc missing mousetrack off"
  fi
  if command -v zsh >/dev/null 2>&1; then
    local less_z oc_z
    less_z="$(zsh -ic 'echo $LESS' 2>/dev/null | tail -1 || true)"
    case "$less_z" in
      *--mouse*) warn "FAIL: LESS still has --mouse ($less_z)"; fail=1 ;;
      *) log "OK: LESS has no --mouse ($less_z)" ;;
    esac
    oc_z="$(zsh -ic 'echo ${OPENCODE_DISABLE_MOUSE-}' 2>/dev/null | tail -1 || true)"
    if [ "$oc_z" = "1" ]; then
      log "OK: OPENCODE_DISABLE_MOUSE=1"
    else
      warn "FAIL: fresh shell OPENCODE_DISABLE_MOUSE is [$oc_z] (want 1)"; fail=1
    fi
  fi
  # What does `grok` resolve to under a PATH shaped like post-install interactive shells?
  # Prefer absolute filtered entry; reject bare ELF and symlink-to-ELF (old false-PASS).
  local g=""
  if [ -x "$GROK_WRAPPER_LOCAL" ]; then
    g="$GROK_WRAPPER_LOCAL"
  elif command -v grok >/dev/null 2>&1; then
    g="$(command -v grok)"
  fi
  if [ -n "$g" ]; then
    if is_filtered_grok_entry "$g"; then
      log "OK: grok -> filtered wrapper ($g)"
    elif is_elf_file "$g"; then
      warn "FAIL: grok is bare ELF (not filtered): $g — re-run install; hash -r; prefer ~/.local/bin"
      fail=1
    else
      local resolved
      resolved="$(readlink -f "$g" 2>/dev/null || printf '%s' "$g")"
      if is_elf_file "$resolved"; then
        warn "FAIL: grok is symlink to bare ELF (not filtered): $g -> $resolved"
        fail=1
      else
        warn "FAIL: grok at $g is not a mouse-leak-filter-entry wrapper"
        fail=1
      fi
    fi
  else
    warn "FAIL: grok not found on PATH and no $GROK_WRAPPER_LOCAL"
    fail=1
  fi
  # Simulate hostile PATH where vendor bin wins — must still detect failure if that is what command -v sees
  if [ -x "$GROK_BIN_DIR/grok" ] && is_elf_file "$GROK_BIN_DIR/grok"; then
    local hostile
    hostile="$(PATH="$GROK_BIN_DIR:/usr/bin:/bin" command -v grok 2>/dev/null || true)"
    if [ -n "$hostile" ] && ! is_filtered_grok_entry "$hostile"; then
      log "OK: bare-ELF-first PATH would resolve to unfiltered ($hostile) — install hooks use grok() to override"
    fi
  fi
  # Running unfiltered TUI is a residual failure mode (not a hard check fail if install is correct)
  local unf
  unf="$(list_unfiltered_grok_pids || true)"
  if [ -n "$unf" ]; then
    warn "NOTE: unfiltered Grok still running (restart required):"
    printf '%s\n' "$unf" | while IFS= read -r line; do warn "  $line"; done
    warn "NOTE: --check can PASS install state while an old TUI still leaks mouse; exit it and relaunch."
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
    # 旧版 Studio 标记
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
  for f in "$FILTER_PY" "$MOUSE_OFF_BIN" "$GROK_WRAPPER_LOCAL" "$GUARD_SH"; do
    if [ -e "$f" ]; then
      mv "$f" "${f}.disabled.$(date +%Y%m%d%H%M%S)"
      log "Disabled $f"
    fi
  done
  log "Uninstall done. Restart shells. Restart grok if needed."
}

# ---------------------------------------------------------------------------
# 主流程
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

  # 完整安装
  need_cmd python3
  need_cmd awk
  need_cmd file
  need_cmd stat

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
  hash -r 2>/dev/null || true

  cat <<EOF

=============================================================================
INSTALL COMPLETE (v$VERSION)

What was installed
  - $GUARD_SH
  - $MOUSE_OFF_BIN
  - $FILTER_PY          ← only used for interactive Grok TUI
  - $GROK_WRAPPER_LOCAL  (identity: $WRAPPER_IDENTITY)
  - OPENCODE_DISABLE_MOUSE=1 in shell hooks (native OpenCode support)
  - grok() shell function → absolute $GROK_WRAPPER_LOCAL (beats hash/PATH)
  - Shell hooks in ~/.zshrc and ~/.bashrc (after Lightning managed block)
  - ~/.vimrc mouse off, ~/.screenrc / ~/.tmux.conf, optional /settings/.screenrc
  - ~/.grok/config.toml mouse hover off (if .grok exists)

IMPORTANT — why "--check OK" can still feel broken
  1) Long-lived shells keep old LESS / command hash until re-source or new shell.
  2) Already-running unfiltered Grok (bare ELF under zsh) must be exited.
  3) Next launch must use the filtered entry (grok function or ~/.local/bin first).

Do this now in every open terminal
      hash -r
      source ~/.zshrc 2>/dev/null || source ~/.bashrc
      # or open a new shell tab
      # exit any running Grok TUI, then:
      grok

Manual reset anytime
      mouse_off
      mouse-tracking-off
      bash $0 --now

Verify later
      bash $0 --check

Allow mouse again (may reintroduce leak)
      GROK_ALLOW_MOUSE=1 grok
=============================================================================
EOF
}

main
