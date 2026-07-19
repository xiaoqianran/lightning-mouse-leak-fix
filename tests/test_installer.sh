#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/fix-lightning-mouse-leak.sh"

bash -n "$SCRIPT"
grep -q 'export OPENCODE_DISABLE_MOUSE=1' "$SCRIPT"
grep -q 'agent|completions|export|help|inspect' "$SCRIPT"
grep -q '不修改 Grok 自行管理的.*agent' "$SCRIPT"
! grep -q 'cp "$GROK_BIN_DIR/grok" "$GROK_BIN_DIR/agent"' "$SCRIPT"
echo "installer regression checks passed"
