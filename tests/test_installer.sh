#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/fix-lightning-mouse-leak.sh"
WRAPPER="$ROOT/grok-wrapper.sh"

bash -n "$SCRIPT"
bash -n "$WRAPPER"
grep -q 'export OPENCODE_DISABLE_MOUSE=1' "$SCRIPT"
grep -q 'agent|completions|export|help|inspect' "$WRAPPER"
! grep -q 'cp "$GROK_BIN_DIR/grok" "$GROK_BIN_DIR/agent"' "$SCRIPT"
! grep -qE '(cat|cp|mv).*>?"?\$GROK_BIN_DIR/agent' "$SCRIPT"
grep -q 'atomic_install_file "$src_wrap" "$GROK_WRAPPER_LOCAL"' "$SCRIPT"
grep -q 'Safety OK: vendor Grok ELF was not modified' "$SCRIPT"
# Identity marker must be present; weak head -5 FILTER|mouse-filter is banned
grep -q 'mouse-leak-filter-entry' "$WRAPPER"
grep -q 'WRAPPER_IDENTITY="mouse-leak-filter-entry"' "$SCRIPT"
grep -q 'is_filtered_grok_entry' "$SCRIPT"
# Must not rely on the old false-PASS pattern alone
! grep -q "head -5 \"\$g\".*FILTER\|mouse-filter" "$SCRIPT"
# Shell hook must define absolute grok() to beat hash/PATH
grep -q 'grok()' "$SCRIPT"
grep -q 'hash -r' "$SCRIPT"
# Interactive TTY path must exec python filter (not bare REAL)
grep -q 'exec "\$PY" "\$FILTER" "\$REAL"' "$WRAPPER"
grep -q 'GROK_ALLOW_MOUSE' "$WRAPPER"
echo "installer regression checks passed"
