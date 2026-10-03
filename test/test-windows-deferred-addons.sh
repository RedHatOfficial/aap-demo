#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$(cat "${repo_root}/aap-demo.sh")"

for expected in 'reject_windows_deferred_addon' 'fleet | local-cache' 'AAP_DEMO_SKIP_CACHE=true' '_DESTROY_SKIP_CACHE=true'; do
  if ! grep -q "$expected" <<<"$script"; then
    echo "✗ Windows deferred addon/cache policy missing: $expected" >&2
    exit 1
  fi
done

echo 'Windows Fleet and cache deferral checks passed'
