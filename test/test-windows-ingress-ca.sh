#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
trust_script="$(cat "${repo_root}/includes/ingress-ca-trust.sh")"
wrapper="$(cat "${repo_root}/powershell/aap-demo.ps1")"

if ! grep -q 'MINGW\* | MSYS\* | CYGWIN\*)' <<<"$trust_script"; then
  echo '✗ ingress trust must have a Windows shell guard' >&2
  exit 1
fi
if ! grep -q 'Git Bash.*certutil' <<<"$trust_script"; then
  echo '✗ ingress trust must document the Windows certutil/NSS distinction' >&2
  exit 1
fi
if ! grep -q 'Install-AapIngressCaTrust' <<<"$wrapper" \
  || ! grep -q 'Write-Warning' <<<"$wrapper"; then
  echo '✗ Windows wrapper must restore CA trust without module-private warning calls' >&2
  exit 1
fi

echo 'Windows ingress CA checks passed'
