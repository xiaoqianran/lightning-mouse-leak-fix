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

echo "install safety regressions passed"
