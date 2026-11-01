#!/usr/bin/env bash
# Read-only secret scan. Does not rewrite .secrets.baseline.
# Requires detect-secrets 1.5.0, the version that produced the baseline.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! command -v detect-secrets >/dev/null 2>&1; then
  echo "detect-secrets 1.5.0 is required: pip install 'detect-secrets==1.5.0'" >&2
  exit 1
fi

version="$(detect-secrets --version 2>&1 | head -n 1)"
case "$version" in
  *1.5.0*) ;;
  *)
    echo "detect-secrets 1.5.0 is required (found: ${version})" >&2
    exit 1
    ;;
esac

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# scan without --baseline prints JSON and leaves the baseline file alone.
detect-secrets scan --exclude-files '\.secrets\.baseline' >"$tmp"

python3 scripts/compare_secrets.py "$tmp" .secrets.baseline

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git diff --exit-code -- .secrets.baseline
fi
