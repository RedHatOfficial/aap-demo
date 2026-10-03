#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$(cat "${repo_root}/config/manifests/nfs-server.yaml")"
create_script="$(cat "${repo_root}/includes/crc-create.sh")"

if ! grep -q '__NFS_BACKING_STORAGE_SIZE__' <<<"$manifest"; then
  echo '✗ NFS manifest must expose its backing PVC size' >&2
  exit 1
fi
if ! grep -q 'NFS_BACKING_STORAGE_SIZE.*5Gi' <<<"$create_script"; then
  echo '✗ create flow must default the NFS backing PVC to 5Gi' >&2
  exit 1
fi
if ! grep -q '__NFS_BACKING_STORAGE_SIZE__' <<<"$create_script"; then
  echo '✗ create flow must render the configured NFS backing size' >&2
  exit 1
fi

echo 'NFS storage size checks passed'
