#!/usr/bin/env bash
# Verify CRC resource prompts remain available through wrapped or captured runs.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if AAP_DEMO_INTERACTIVE=1 AAP_DEMO_CONFIGURE_COREDNS_ONLY=1 bash -c \
  "source '${REPO_ROOT}/includes/crc-create.sh'; aap_demo_resource_prompt_enabled"; then
  echo 'CRC resource prompt bridge check passed'
else
  echo 'CRC resource prompt bridge check failed' >&2
  exit 1
fi

status=$(AAP_DEMO_CONFIGURE_COREDNS_ONLY=1 bash -c \
  "source '${REPO_ROOT}/includes/crc-create.sh'; aap_demo_normalize_crc_status Nonexistent")
if [ "$status" != 'Unknown' ]; then
  echo "CRC fresh-install status was not normalized for prompting: $status" >&2
  exit 1
fi
echo 'CRC fresh-install status normalization check passed'
