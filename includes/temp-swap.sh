#!/usr/bin/env bash
# Shared temp swap helpers for memory-constrained Linux hosts running CRC.
#
# Sourced by includes/crc-create.sh (interactive prompt) and scripts/enable-temp-swap.sh.

AAP_SWAP_SIZE_GB="${AAP_SWAP_SIZE_GB:-16}"
AAP_SWAP_FILE="${AAP_SWAP_FILE:-/swapfile-aap-demo}"

aap_demo_temp_swap_is_active() {
  swapon --show --noheadings 2>/dev/null | awk '{print $1}' | grep -qx "${AAP_SWAP_FILE}"
}

aap_demo_temp_swap_show_status() {
  echo "Active swap devices:"
  swapon --show || true
  echo ""
  free -h | awk '/^Mem:|^Swap:/'
}

aap_demo_temp_swap_host_swap_gb() {
  awk '/SwapTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "0"
}

aap_demo_temp_swap_create_file() {
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

aap_demo_temp_swap_enable() {
  if [[ "${SKIP_TEMP_SWAP:-false}" == "true" ]]; then
    echo "Skipping temp swap (SKIP_TEMP_SWAP=true)"
    return 0
  fi

  if ! [[ "${AAP_SWAP_SIZE_GB}" =~ ^[0-9]+$ ]] || [[ "${AAP_SWAP_SIZE_GB}" -le 0 ]]; then
    echo "ERROR: AAP_SWAP_SIZE_GB must be a positive integer (got: ${AAP_SWAP_SIZE_GB})" >&2
    return 1
  fi

  if aap_demo_temp_swap_is_active; then
    printf "  ${_GREEN:-}✓${_NC:-} Temp swap already active: ${AAP_SWAP_FILE}\n"
    return 0
  fi

  if [[ -f "${AAP_SWAP_FILE}" ]]; then
    echo "Removing incompatible swap file at ${AAP_SWAP_FILE}..."
    sudo swapoff "${AAP_SWAP_FILE}" 2>/dev/null || true
    sudo rm -f "${AAP_SWAP_FILE}"
  fi

  aap_demo_temp_swap_create_file "${AAP_SWAP_SIZE_GB}" "${AAP_SWAP_FILE}"
  sudo swapon "${AAP_SWAP_FILE}"
  printf "  ${_GREEN:-}✓${_NC:-} Temp swap enabled: ${AAP_SWAP_FILE} (${AAP_SWAP_SIZE_GB}GB)\n"
}

aap_demo_temp_swap_disable() {
  if aap_demo_temp_swap_is_active; then
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

# Interactive prompt used during aap-demo create (Linux + TTY only).
aap_demo_prompt_temp_swap() {
  local host_swap_gb default_confirm swap_confirm default_swap_gb input_swap_gb

  if [[ "$(uname -s)" != "Linux" ]]; then
    return 0
  fi

  if [[ "${SKIP_TEMP_SWAP:-false}" == "true" ]] || [[ "${QUIET:-false}" == "true" ]]; then
    return 0
  fi

  if aap_demo_temp_swap_is_active; then
    printf "  ${_GREEN}✓${_NC} Temp swap already active: ${AAP_SWAP_FILE}\n"
    return 0
  fi

  host_swap_gb="$(aap_demo_temp_swap_host_swap_gb)"
  default_swap_gb=16
  if [[ -f "${HOME}/.aap-demo/config" ]]; then
    local saved_swap
    saved_swap="$(grep '^AAP_SWAP_SIZE_GB=' "${HOME}/.aap-demo/config" 2>/dev/null | cut -d= -f2 || true)"
    [[ "${saved_swap:-}" =~ ^[0-9]+$ ]] && default_swap_gb="${saved_swap}"
  fi

  if [[ "${host_swap_gb}" -gt 0 ]]; then
    printf "  Host swap: ${host_swap_gb}GB (zram or other)\n"
  fi

  # Recommend swap on hosts with 36 GB RAM or less (typical aap-demo constraint).
  if [[ "${HOST_MEMORY_MB:-0}" -gt 36864 ]]; then
    default_confirm="n"
    printf "  Create temp swap file for deploy? [y/N]: "
  else
    default_confirm="Y"
    printf "  Create temp swap file for deploy? [Y/n]: "
  fi
  read -r swap_confirm </dev/tty
  swap_confirm="${swap_confirm:-${default_confirm}}"
  case "$(echo "${swap_confirm}" | tr '[:upper:]' '[:lower:]')" in
    y | yes)
      ;;
    *)
      echo "  Skipping temp swap"
      return 0
      ;;
  esac

  printf "  Temp swap size in GB [${default_swap_gb}]: "
  read -r input_swap_gb </dev/tty
  input_swap_gb="${input_swap_gb:-${default_swap_gb}}"
  if ! [[ "${input_swap_gb}" =~ ^[0-9]+$ ]] || [[ "${input_swap_gb}" -le 0 ]]; then
    printf "${_RED}▸${_NC} Invalid swap size: '${input_swap_gb}' (must be a positive integer in GB)\n"
    exit 1
  fi

  AAP_SWAP_SIZE_GB="${input_swap_gb}"
  if declare -F _save_config_key >/dev/null 2>&1; then
    _save_config_key "AAP_SWAP_SIZE_GB" "${AAP_SWAP_SIZE_GB}"
  fi

  aap_demo_temp_swap_enable
  echo ""
  echo "  Remove after deploy: ${SCRIPT_DIR}/scripts/enable-temp-swap.sh disable"
  echo ""
}
