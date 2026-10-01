#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$(cat "${repo_root}/aap-demo.sh")"

if ! grep -q '^check_python_windows()' <<<"$script"; then
  echo '✗ deploy script must define the Windows Python prerequisite check' >&2
  exit 1
fi
if ! grep -q 'MINGW\* | MSYS\* | CYGWIN\*)' <<<"$script"; then
  echo '✗ Python prerequisite must be guarded for Windows shells' >&2
  exit 1
fi
if ! grep -q "'import sys'" <<<"$script"; then
  echo '✗ Python prerequisite must validate an executable runtime' >&2
  exit 1
fi
if ! grep -q 'winget install --id Python.Python.3.12' <<<"$script"; then
  echo '✗ Python prerequisite must provide the winget install command' >&2
  exit 1
fi

echo 'Windows Python prerequisite checks passed'
