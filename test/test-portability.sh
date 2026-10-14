#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cli="${repo_root}/aap-demo.sh"

if grep -Fq 'compgen -G' "$cli"; then
  echo "FAIL: mkcert path detection still depends on compgen" >&2
  exit 1
fi
if grep -Fq 'client-certificate=<' "$cli" || grep -Fq 'client-key=<' "$cli"; then
  echo "FAIL: kubeconfig credential setup still uses process substitution" >&2
  exit 1
fi
if ! grep -Fq 'client-certificate="$cert_tmp"' "$cli" \
  || ! grep -Fq 'client-key="$key_tmp"' "$cli"; then
  echo "FAIL: kubeconfig credential setup does not use temporary files" >&2
  exit 1
fi
if ! grep -Fq 'rm -f "$cert_tmp" "$key_tmp"' "$cli" \
  || ! grep -Fq 'TEMP_FILES=("$TEMP_KUBECONFIG")' "$cli"; then
  echo "FAIL: decoded kubeconfig credentials are not removed after embedding" >&2
  exit 1
fi
if ! grep -Fq 'cert_tmp=$(mktemp) || {' "$cli" \
  || ! grep -Fq 'key_tmp=$(mktemp) || {' "$cli"; then
  echo "FAIL: kubeconfig temp-file creation lacks explicit error handling" >&2
  exit 1
fi

if ! grep -Fq 'command -v jq' "${repo_root}/includes/json-utils.sh"; then
  echo "FAIL: JSON utilities must prefer jq when available" >&2
  exit 1
fi

echo "PASS: portability-sensitive shell constructs use portable paths"
