#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$(cat "${repo_root}/aap-demo.sh")"

if ! grep -q 'AAP_DEMO_SKIP_CACHE' <<<"$script"; then
  echo '✗ deploy must provide an explicit local-cache bypass' >&2
  exit 1
fi
if ! grep -q -- 'Skipping local image cache' <<<"$script"; then
  echo '✗ deploy cache bypass must report that it is active' >&2
  exit 1
fi

echo 'Deploy cache skip checks passed'
