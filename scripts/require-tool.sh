#!/usr/bin/env bash
# Pre-commit helper: verify a tool exists, then exec it.
# Usage: require-tool.sh <tool> <install-hint> [tool-args...] [files...]
tool="$1" hint="$2"
shift 2

# Auto-activate .venv-lint if the tool isn't on PATH
if ! command -v "$tool" >/dev/null 2>&1; then
  VENV_BIN="$(cd "$(dirname "$0")/.." && pwd)/.venv-lint/bin"
  if [ -x "${VENV_BIN}/${tool}" ]; then
    export PATH="${VENV_BIN}:${PATH}"
  else
    echo "$tool not found ($hint)" >&2
    exit 1
  fi
fi
exec "$tool" "$@"
