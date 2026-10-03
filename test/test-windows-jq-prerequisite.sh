#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$(cat "${repo_root}/aap-demo.sh")"

if ! grep -q '^check_jq_windows()' <<<"$script"; then
  echo '✗ deploy script must define the Windows jq prerequisite check' >&2
  exit 1
fi
if ! grep -q 'MINGW\* | MSYS\* | CYGWIN\*)' <<<"$script"; then
  echo '✗ jq prerequisite must be guarded for Windows shells' >&2
  exit 1
fi
if ! grep -q 'command -v jq' <<<"$script"; then
  echo '✗ Windows jq prerequisite must check PATH' >&2
  exit 1
fi
if ! grep -q 'winget install --id jqlang.jq' <<<"$script"; then
  echo '✗ Windows jq prerequisite must provide the winget install command' >&2
  exit 1
fi

echo 'Windows jq prerequisite checks passed'
