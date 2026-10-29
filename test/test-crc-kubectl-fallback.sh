#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$(cat "${repo_root}/includes/crc-create.sh")"

if ! grep -q 'command -v oc' <<<"$script" || ! grep -q 'kubectl()' <<<"$script"; then
  echo "✗ crc-create.sh must fall back to oc when kubectl is unavailable" >&2
  exit 1
fi

echo 'CRC kubectl fallback checks passed'

# Exercise the actual selection block with a kubectl that exists but cannot run.
selection=$(sed -n '/^if ! command -v kubectl /,/^fi$/p' "${repo_root}/includes/crc-create.sh")
(
  kubectl() { return 126; }
  oc() { printf '%s\n' "oc $*"; }
  eval "$selection"
  [[ "$(kubectl get nodes)" == 'oc get nodes' ]]
)
echo 'Unusable kubectl falls back to oc'
