#!/usr/bin/env bash
# Temporary file-backed swap for aap-demo deploy bursts on memory-constrained Linux hosts.
#
# Fedora and other distros often ship with zram swap (typically 8 GB). When CRC is
# allocated 16-24 GB, the host can run out of memory during image pulls and operator
# reconciliation. This script adds a removable swap file (default 16 GB) on top of
# existing swap. The file is NOT added to /etc/fstab — remove it after deploy.
#
# btrfs note: swap files require chattr +C (no copy-on-write) before writing.
# fallocate-created swap files fail on btrfs with compression enabled.
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
#   SKIP_TEMP_SWAP    - set to true to skip enable (used by local-prereq.sh)
set -euo pipefail

AAP_SWAP_SIZE_GB="${AAP_SWAP_SIZE_GB:-16}"
AAP_SWAP_FILE="${AAP_SWAP_FILE:-/swapfile-aap-demo}"
ACTION="${1:-enable}"

_swap_is_active() {
  swapon --show --noheadings 2>/dev/null | awk '{print $1}' | grep -qx "${AAP_SWAP_FILE}"
}

_show_status() {
  echo "Active swap devices:"
  swapon --show || true
  echo ""
  free -h | awk '/^Mem:|^Swap:/'
}

_create_swap_file() {
  local size_gb="$1"
  local swap_file="$2"
  local fs_type

  fs_type="$(findmnt -n -o FSTYPE --target "$(dirname "${swap_file}")" 2>/dev/null || true)"
  echo "Creating ${size_gb}GB swap file at ${swap_file} (${fs_type:-unknown fs}, requires sudo)..."

  if [[ "${fs_type}" == "btrfs" ]]; then
    # btrfs + compression breaks fallocate swap files; disable COW before writing.
    sudo touch "${swap_file}"
    sudo chattr +C "${swap_file}"
    sudo dd if=/dev/zero of="${swap_file}" bs=1M count=$((size_gb * 1024)) status=progress conv=fsync
  elif sudo fallocate -l "${size_gb}G" "${swap_file}" 2>/dev/null; then
    :
  else
    sudo dd if=/dev/zero of="${swap_file}" bs=1M count=$((size_gb * 1024)) status=progress conv=fsync
  fi

  sudo chmod 600 "${swap_file}"
  sudo mkswap "${swap_file}"
}

_enable_swap() {
  if [[ "${SKIP_TEMP_SWAP:-false}" == "true" ]]; then
    echo "Skipping temp swap (SKIP_TEMP_SWAP=true)"
    return 0
  fi

  if ! [[ "${AAP_SWAP_SIZE_GB}" =~ ^[0-9]+$ ]] || [[ "${AAP_SWAP_SIZE_GB}" -le 0 ]]; then
    echo "ERROR: AAP_SWAP_SIZE_GB must be a positive integer (got: ${AAP_SWAP_SIZE_GB})" >&2
    exit 1
  fi

  if _swap_is_active; then
    echo "✓ Temp swap already active: ${AAP_SWAP_FILE}"
    _show_status
    return 0
  fi

  if [[ -f "${AAP_SWAP_FILE}" ]]; then
    echo "Removing incompatible swap file at ${AAP_SWAP_FILE}..."
    sudo swapoff "${AAP_SWAP_FILE}" 2>/dev/null || true
    sudo rm -f "${AAP_SWAP_FILE}"
  fi

  _create_swap_file "${AAP_SWAP_SIZE_GB}" "${AAP_SWAP_FILE}"
  sudo swapon "${AAP_SWAP_FILE}"
  echo "✓ Temp swap enabled: ${AAP_SWAP_FILE} (${AAP_SWAP_SIZE_GB}GB)"
  echo ""
  _show_status
  echo ""
  echo "Remove after deploy:"
  echo "  ${BASH_SOURCE[0]} disable"
}

_disable_swap() {
  if _swap_is_active; then
    sudo swapoff "${AAP_SWAP_FILE}"
    echo "✓ Disabled temp swap: ${AAP_SWAP_FILE}"
  elif [[ -f "${AAP_SWAP_FILE}" ]]; then
    echo "Temp swap file exists but is not active: ${AAP_SWAP_FILE}"
  else
    echo "No temp swap file at ${AAP_SWAP_FILE}"
    return 0
  fi

  sudo rm -f "${AAP_SWAP_FILE}"
  echo "✓ Removed ${AAP_SWAP_FILE}"
}

case "${ACTION}" in
  enable)
    _enable_swap
    ;;
  disable)
    _disable_swap
    ;;
  status)
    _show_status
    ;;
  -h | --help | help)
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "ERROR: Unknown action: ${ACTION}" >&2
    echo "Usage: ${BASH_SOURCE[0]} [enable|disable|status]" >&2
    exit 1
    ;;
esac
