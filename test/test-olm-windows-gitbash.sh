#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$(cat "${repo_root}/addons/olm/deploy.sh")"

for expected in 'MINGW' 'operator-sdk_linux_amd64' 'ssh' 'kube_config' 'sudo KUBECONFIG'; do
  if ! grep -q "$expected" <<<"$script"; then
    echo "✗ Windows Git Bash OLM install must use the CRC VM path: $expected" >&2
    exit 1
  fi
done

echo 'Windows Git Bash OLM checks passed'
