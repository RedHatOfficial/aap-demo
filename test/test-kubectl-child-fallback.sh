#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$(cat "${repo_root}/aap-demo.sh")"

if ! grep -q 'export -f kubectl' <<<"$script"; then
  echo '✗ oc fallback must be exported to child Bash processes' >&2
  exit 1
fi

echo 'kubectl child-process fallback checks passed'
