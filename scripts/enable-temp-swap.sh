#!/usr/bin/env bash
# Temporary file-backed swap for aap-demo deploy bursts on Linux hosts.
#
# During interactive aap-demo create on Linux, you are prompted to enable temp swap
# before CPU and memory allocation. Use this script to manage swap manually.
#
# Usage:
#   ./scripts/enable-temp-swap.sh              # enable default 16 GB swap
#   AAP_SWAP_SIZE_GB=24 ./scripts/enable-temp-swap.sh
#   ./scripts/enable-temp-swap.sh disable      # swapoff and remove file
#   ./scripts/enable-temp-swap.sh status       # show active swap devices
#
# Environment:
#   AAP_SWAP_SIZE_GB  - swap file size in GB (default: 16)
#   AAP_SWAP_FILE     - path to swap file (default: /swapfile-aap-demo)
#   SKIP_TEMP_SWAP    - set to true to skip enable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-enable}"

# shellcheck source=includes/temp-swap.sh
source "${SCRIPT_DIR}/includes/temp-swap.sh"

if ! aap_demo_temp_swap_is_linux; then
  echo "Temp swap is only supported on Linux (Fedora/RHEL)." >&2
  exit 1
fi

case "${ACTION}" in
  enable)
    if aap_demo_temp_swap_enable; then
      echo ""
      aap_demo_temp_swap_show_status
      echo ""
      echo "Remove after deploy:"
      echo "  ${BASH_SOURCE[0]} disable"
    fi
    ;;
  disable)
    aap_demo_temp_swap_disable
    ;;
  status)
    aap_demo_temp_swap_show_status
    ;;
  -h | --help | help)
    sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "ERROR: Unknown action: ${ACTION}" >&2
    echo "Usage: ${BASH_SOURCE[0]} [enable|disable|status]" >&2
    exit 1
    ;;
esac
