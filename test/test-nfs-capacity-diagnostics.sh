#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
create_script="$(cat "${repo_root}/includes/crc-create.sh")"

for expected in \
  'NFS backing PVC could not be provisioned' \
  'no enough space left on VG' \
  'CRC_DISK' \
  'CRC_PV_SIZE'; do
  if ! grep -q "$expected" <<<"$create_script"; then
    echo "✗ NFS capacity diagnostics must mention: $expected" >&2
    exit 1
  fi
done

echo 'NFS capacity diagnostics checks passed'
