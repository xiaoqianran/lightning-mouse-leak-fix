#!/usr/bin/env bash
# Grok entry + mouse-leak PTY filter (fix-lightning-mouse-leak.sh v2.3)
# Works under bash and when invoked from zsh (this file is bash; zsh just execs it).
set -u

_find_python() {
  local p
  for p in /usr/bin/python3 /bin/python3; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

_is_elf() {
  local f="$1" b
  [ -n "$f" ] && [ -e "$f" ] && [ -r "$f" ] && [ -x "$f" ] || return 1
  b=$(head -c 4 "$f" 2>/dev/null) || return 1
  [ "$b" = $'\x7fELF' ]
}

_find_real_grok() {
  local self c t home
  home="${HOME:-}"
  [ -n "$home" ] || home="$(cd ~ && pwd)"
  self="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

  _try() {
    local p="$1" r
    [ -n "$p" ] || return 1
    [ -e "$p" ] || return 1
    r="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
    [ "$r" = "$self" ] && return 1
    _is_elf "$r" || return 1
    printf '%s' "$r"
    return 0
  }

  if [ -n "${GROK_REAL_BIN:-}" ]; then
    _try "$GROK_REAL_BIN" && return 0
  fi

  for c in \
    "$home/.grok/downloads/grok-linux-x86_64" \
    "$home/.grok/downloads/grok-linux-aarch64" \
    "$home/.grok/downloads/grok" \
    "$home/.grok/bin/grok.real" \
    "$home/.grok/bin/grok" \
    "$home/.grok/bin/agent"
  do
    _try "$c" && return 0
  done

  if [ -d "$home/.grok/downloads" ]; then
    for c in "$home/.grok/downloads"/grok*; do
      _try "$c" && return 0
    done
  fi

  local p
  for p in $(command -v -a grok 2>/dev/null; type -a grok 2>/dev/null | awk '{print $NF}'); do
    _try "$p" && return 0
  done

  return 1
}

_diagnose_missing() {
  local home f sz first
  home="${HOME:-}"
  echo "grok: 未找到真实 Grok 二进制（ELF，通常约 100MB+）。" >&2
  echo "  这与 zsh/bash 无关：包装器会拒绝「假」文件（例如被覆盖成 shell 脚本）。" >&2
  echo "  HOME=${home:-<unset>}" >&2
  f="${home}/.grok/downloads/grok-linux-x86_64"
  if [ -e "$f" ]; then
    sz=$(wc -c <"$f" 2>/dev/null | tr -d ' ')
    first=$(head -c 80 "$f" 2>/dev/null | tr -cd '\11\12\15\40-\176')
    echo "  发现文件但不是 ELF: $f" >&2
    echo "    大小: ${sz} 字节（真身通常 > 50_000_000）" >&2
    echo "    开头: ${first:0:60}..." >&2
    if [ "${sz:-0}" -lt 100000 ] 2>/dev/null; then
      echo "  → 真身已被损坏/替换（常见：误把包装脚本拷成 grok-linux-x86_64）。" >&2
      echo "  → 请重新安装 Grok:" >&2
      echo "       curl -fsSL https://x.ai/cli/install.sh | bash" >&2
    fi
  else
    echo "  不存在: $f" >&2
    echo "  → 请先安装: curl -fsSL https://x.ai/cli/install.sh | bash" >&2
  fi
  if [ -d "${home}/.grok/downloads" ]; then
    echo "  downloads:" >&2
    ls -la "${home}/.grok/downloads" 2>&1 | sed 's/^/    /' >&2 || true
  fi
  if [ -d "${home}/.grok/bin" ]; then
    echo "  bin:" >&2
    ls -la "${home}/.grok/bin" 2>&1 | sed 's/^/    /' >&2 || true
  fi
  echo "  装好后验证:" >&2
  echo "    file ~/.grok/downloads/grok-linux-x86_64   # 应含 ELF" >&2
  echo "    wc -c ~/.grok/downloads/grok-linux-x86_64  # 应远大于 1MB" >&2
  echo "    grok --version" >&2
}

REAL=""
if ! REAL="$(_find_real_grok)"; then
  _diagnose_missing
  exit 127
fi

FILTER="${GROK_MOUSE_FILTER:-${HOME}/.local/bin/grok-mouse-filter.py}"

if [ "${GROK_ALLOW_MOUSE:-0}" = "1" ]; then
  exec "$REAL" "$@"
fi

case "${1-}" in
  -h|--help|-v|--version|agent|completions|export|help|inspect|leader|login|logout|mcp|memory|models|plugin|sessions|setup|trace|update|version|worktree|wrap)
    exec "$REAL" "$@"
    ;;
esac
for _arg in "$@"; do
  case "$_arg" in
    -p|--single|--single=*|--prompt-file|--prompt-file=*|--prompt-json|--prompt-json=*|--json-schema|--json-schema=*)
      exec "$REAL" "$@"
      ;;
  esac
done

if [ ! -t 0 ] || [ ! -t 1 ]; then
  exec "$REAL" "$@"
fi

if [ ! -f "$FILTER" ]; then
  exec "$REAL" "$@"
fi
PY="$(_find_python || true)"
if [ -z "${PY:-}" ]; then
  echo "grok: 警告: 无系统 python3，直连 Grok" >&2
  exec "$REAL" "$@"
fi

exec "$PY" "$FILTER" "$REAL" "$@"
