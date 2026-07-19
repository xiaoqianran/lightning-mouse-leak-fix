#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/fix-lightning-mouse-leak.sh"

bash -n "$SCRIPT"
grep -q 'export OPENCODE_DISABLE_MOUSE=1' "$SCRIPT"
grep -q 'agent|completions|export|help|inspect' "$ROOT/grok-wrapper.sh"
! grep -q 'cp "$GROK_BIN_DIR/grok" "$GROK_BIN_DIR/agent"' "$SCRIPT"
! grep -qE '(cat|cp|mv).*>?"?\$GROK_BIN_DIR/agent' "$SCRIPT"
grep -q 'atomic_install_file "$src_wrap" "$GROK_WRAPPER_LOCAL"' "$SCRIPT"
grep -q 'Safety OK: vendor Grok ELF was not modified' "$SCRIPT"
echo "installer regression checks passed"
