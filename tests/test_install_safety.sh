#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/fix-lightning-mouse-leak.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

run_installer() {
  local test_home="$1"
  HOME="$test_home" \
  LIGHTNING_RC="$test_home/no-lightningrc" \
  LIGHTNING_SCREENRC="$test_home/no-screenrc" \
    bash "$SCRIPT" --quiet >/dev/null
}

run_check() {
  local test_home="$1"
  shift
  HOME="$test_home" \
  LIGHTNING_RC="$test_home/no-lightningrc" \
  LIGHTNING_SCREENRC="$test_home/no-screenrc" \
  PATH="${1:-$test_home/.local/bin:/usr/bin:/bin}" \
    bash "$SCRIPT" --check
}

# Regression: if ~/.local/bin/grok is a symlink to the vendor binary, installing
# the wrapper must replace the symlink itself and leave the ELF byte-for-byte
# unchanged. This is the exact shape of the destructive failure from v1/manual
# installation attempts.
HOME_WITH_GROK="$TEST_ROOT/with-grok"
mkdir -p "$HOME_WITH_GROK/.grok/downloads" "$HOME_WITH_GROK/.grok/bin" \
  "$HOME_WITH_GROK/.local/bin"
cp /bin/true "$HOME_WITH_GROK/.grok/downloads/grok-linux-x86_64"
chmod +x "$HOME_WITH_GROK/.grok/downloads/grok-linux-x86_64"
ln -s ../downloads/grok-linux-x86_64 "$HOME_WITH_GROK/.grok/bin/grok"
ln -s "$HOME_WITH_GROK/.grok/downloads/grok-linux-x86_64" \
  "$HOME_WITH_GROK/.local/bin/grok"
before=$(sha256sum "$HOME_WITH_GROK/.grok/downloads/grok-linux-x86_64")
run_installer "$HOME_WITH_GROK"
after=$(sha256sum "$HOME_WITH_GROK/.grok/downloads/grok-linux-x86_64")
[ "$after" = "$before" ]
[ ! -L "$HOME_WITH_GROK/.local/bin/grok" ]
[ -L "$HOME_WITH_GROK/.grok/bin/grok" ]
cmp -s /bin/true "$HOME_WITH_GROK/.grok/downloads/grok-linux-x86_64"
HOME="$HOME_WITH_GROK" "$HOME_WITH_GROK/.local/bin/grok" --version
grep -q 'mouse-leak-filter-entry' "$HOME_WITH_GROK/.local/bin/grok"
grep -q 'grok()' "$HOME_WITH_GROK/.zshrc"

# --check must PASS when filtered entry is installed
run_check "$HOME_WITH_GROK" "$HOME_WITH_GROK/.local/bin:/usr/bin:/bin" >/dev/null

# Regression: --check must FAIL for bare ELF / symlink-to-ELF (old false-PASS).
# Reproduces: PATH with only ~/.grok/bin (symlink to ELF); file(1) says
# "symbolic link" not ELF, and head -5 FILTER|mouse-filter never matched.
HOME_BARE="$TEST_ROOT/bare-elf-check"
mkdir -p "$HOME_BARE/.grok/downloads" "$HOME_BARE/.grok/bin" \
  "$HOME_BARE/.local/bin" "$HOME_BARE/.config/shell"
cp /bin/true "$HOME_BARE/.grok/downloads/grok-linux-x86_64"
chmod +x "$HOME_BARE/.grok/downloads/grok-linux-x86_64"
ln -sfn ../downloads/grok-linux-x86_64 "$HOME_BARE/.grok/bin/grok"
# Minimal hooks so other checks do not dominate — only grok identity should fail
cat >"$HOME_BARE/.config/shell/mouse-leak-guard.sh" <<'EOF'
sanitize_less_value() { printf '%s' "$1"; }
mouse_tracking_off_payload() { printf '\033[?1000l'; }
export_sanitized_less() { :; }
mouse_leak_guard_init() { :; }
EOF
# Intentionally NO filtered wrapper; plant a non-identity shell script that
# would have false-passed the old "check manually" branch.
printf '#!/bin/sh\necho fake\n' >"$HOME_BARE/.local/bin/grok"
chmod +x "$HOME_BARE/.local/bin/grok"
# Also leave filter/bin stubs so file-existence checks pass
printf '#!/usr/bin/env python3\n' >"$HOME_BARE/.local/bin/grok-mouse-filter.py"
chmod +x "$HOME_BARE/.local/bin/grok-mouse-filter.py"
printf '#!/bin/sh\n' >"$HOME_BARE/.local/bin/mouse-tracking-off"
chmod +x "$HOME_BARE/.local/bin/mouse-tracking-off"
printf '# >>> mouse-leak fix (lightning) >>>\n# mouse-leak-guard\n# <<< mouse-leak fix (lightning) <<<\n' \
  >"$HOME_BARE/.zshrc"
if run_check "$HOME_BARE" "$HOME_BARE/.local/bin:/usr/bin:/bin" >/dev/null 2>&1; then
  echo "FAIL: --check should reject non-identity wrapper" >&2
  exit 1
fi
# Symlink-to-ELF as command -v grok (PATH prefers vendor bin only)
rm -f "$HOME_BARE/.local/bin/grok"
if run_check "$HOME_BARE" "$HOME_BARE/.grok/bin:/usr/bin:/bin" >/dev/null 2>&1; then
  echo "FAIL: --check should reject bare ELF via ~/.grok/bin symlink" >&2
  exit 1
fi

# Regression: installing the fix before Grok exists must remain usable after
# the vendor later installs its ELF; re-running the fixer is not required.
HOME_BEFORE_GROK="$TEST_ROOT/before-grok"
mkdir -p "$HOME_BEFORE_GROK"
run_installer "$HOME_BEFORE_GROK"
mkdir -p "$HOME_BEFORE_GROK/.grok/downloads" "$HOME_BEFORE_GROK/.grok/bin"
cp /bin/true "$HOME_BEFORE_GROK/.grok/downloads/grok-linux-x86_64"
chmod +x "$HOME_BEFORE_GROK/.grok/downloads/grok-linux-x86_64"
ln -s ../downloads/grok-linux-x86_64 "$HOME_BEFORE_GROK/.grok/bin/grok"
HOME="$HOME_BEFORE_GROK" "$HOME_BEFORE_GROK/.local/bin/grok" --version
grep -q 'mouse-leak-filter-entry' "$HOME_BEFORE_GROK/.local/bin/grok"

# Interactive launch decision: shipped wrapper must exec the PTY filter when
# stdin/stdout are TTYs and GROK_ALLOW_MOUSE is unset; management flags and
# GROK_ALLOW_MOUSE=1 must hit the real ELF directly.
HOME_LAUNCH="$TEST_ROOT/launch-path"
mkdir -p "$HOME_LAUNCH/.local/bin" "$HOME_LAUNCH/.grok/downloads"
# REAL must be ELF (wrapper rejects non-ELF). Tiny C spy logs argv then exits.
cat >"$HOME_LAUNCH/real_spy.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  const char *log = getenv("GROK_REAL_LOG");
  if (log) {
    FILE *f = fopen(log, "a");
    if (f) {
      fputs("REAL_RAN", f);
      for (int i = 1; i < argc; i++) {
        fputc(':', f);
        fputs(argv[i], f);
      }
      fputc('\n', f);
      fclose(f);
    }
  }
  return 0;
}
EOF
if ! command -v gcc >/dev/null 2>&1; then
  echo "FAIL: gcc required for launch-path ELF spy" >&2
  exit 1
fi
gcc -O0 -o "$HOME_LAUNCH/.grok/downloads/grok-linux-x86_64" "$HOME_LAUNCH/real_spy.c"
chmod +x "$HOME_LAUNCH/.grok/downloads/grok-linux-x86_64"
cp "$ROOT/grok-wrapper.sh" "$HOME_LAUNCH/.local/bin/grok"
chmod +x "$HOME_LAUNCH/.local/bin/grok"
grep -q 'mouse-leak-filter-entry' "$HOME_LAUNCH/.local/bin/grok"
export GROK_REAL_LOG="$HOME_LAUNCH/real.log"
: >"$GROK_REAL_LOG"
# --version is a management subcommand → always direct-exec REAL (no filter)
HOME="$HOME_LAUNCH" "$HOME_LAUNCH/.local/bin/grok" --version >/dev/null
grep -q 'REAL_RAN:--version' "$GROK_REAL_LOG"
# GROK_ALLOW_MOUSE=1 must always hit REAL even with empty (would-be interactive) args
: >"$GROK_REAL_LOG"
HOME="$HOME_LAUNCH" GROK_ALLOW_MOUSE=1 "$HOME_LAUNCH/.local/bin/grok" >/dev/null 2>&1 || true
grep -q 'REAL_RAN' "$GROK_REAL_LOG"
# Non-TTY empty args: wrapper sees ! -t 0 / ! -t 1 → direct REAL
: >"$GROK_REAL_LOG"
HOME="$HOME_LAUNCH" "$HOME_LAUNCH/.local/bin/grok" >/dev/null 2>&1 || true
grep -q 'REAL_RAN' "$GROK_REAL_LOG"
# PTY + no bypass: must exec python FILTER (spy filter logs and exits)
export GROK_LAUNCH_LOG="$HOME_LAUNCH/filter-launch.log"
: >"$GROK_LAUNCH_LOG"
# Spy must be valid Python: wrapper does `exec "$PY" "$FILTER" "$REAL"`.
cat >"$HOME_LAUNCH/.local/bin/grok-mouse-filter.py" <<'EOF'
#!/usr/bin/env python3
import os, sys
log = os.environ.get("GROK_LAUNCH_LOG", "")
if log:
    with open(log, "w") as f:
        f.write("FILTER_RAN:" + (sys.argv[1] if len(sys.argv) > 1 else "?") + "\n")
sys.exit(0)
EOF
chmod +x "$HOME_LAUNCH/.local/bin/grok-mouse-filter.py"
HOME_LAUNCH="$HOME_LAUNCH" GROK_LAUNCH_LOG="$GROK_LAUNCH_LOG" python3 - <<'PY'
import os, pty, select, time
home = os.environ["HOME_LAUNCH"]
os.environ["HOME"] = home
log_path = os.environ["GROK_LAUNCH_LOG"]
os.environ["GROK_LAUNCH_LOG"] = log_path
os.environ.pop("GROK_ALLOW_MOUSE", None)
wrapper = os.path.join(home, ".local/bin/grok")
pid, fd = pty.fork()
if pid == 0:
    os.execv(wrapper, [wrapper])
deadline = time.time() + 5
while time.time() < deadline:
    try:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                os.read(fd, 4096)
            except OSError:
                break
    except Exception:
        break
    try:
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid == pid:
            break
    except ChildProcessError:
        break
else:
    try:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    except Exception:
        pass
log = open(log_path).read()
assert "FILTER_RAN:" in log, f"interactive PTY launch did not use filter: {log!r}"
print("pty interactive launch used filter:", log.strip())
# Second run for consistency
open(log_path, "w").close()
pid, fd = pty.fork()
if pid == 0:
    os.execv(wrapper, [wrapper])
deadline = time.time() + 5
while time.time() < deadline:
    try:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                os.read(fd, 4096)
            except OSError:
                break
    except Exception:
        break
    try:
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid == pid:
            break
    except ChildProcessError:
        break
else:
    try:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    except Exception:
        pass
log2 = open(log_path).read()
assert "FILTER_RAN:" in log2, f"second PTY launch did not use filter: {log2!r}"
print("pty interactive launch used filter (2nd):", log2.strip())
PY

echo "install safety regressions passed"
