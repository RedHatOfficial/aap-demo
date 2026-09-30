#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$(cat "${repo_root}/includes/crc-create.sh")"

if ! grep -q 'command -v oc' <<<"$script" || ! grep -q 'kubectl()' <<<"$script"; then
  echo "✗ crc-create.sh must fall back to oc when kubectl is unavailable" >&2
  exit 1
fi

echo 'CRC kubectl fallback checks passed'
