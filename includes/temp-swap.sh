#!/usr/bin/env bash
# Shared temp swap helpers for memory-constrained hosts running CRC.
#
# Linux (Fedora/RHEL): file-backed swap via swapon/mkswap (btrfs, xfs, ext4).
# macOS: reserves disk space so dynamic_pager can grow kernel swap during deploy.
#
# Sourced by includes/crc-create.sh (interactive prompt) and scripts/enable-temp-swap.sh.

AAP_SWAP_SIZE_GB="${AAP_SWAP_SIZE_GB:-16}"

aap_demo_temp_swap_platform() {
  case "$(uname -s)" in
    Linux) echo "linux" ;;
    Darwin) echo "darwin" ;;
    *) echo "unsupported" ;;
  esac
}

aap_demo_temp_swap_file_path() {
  if [[ -n "${AAP_SWAP_FILE:-}" ]]; then
    echo "${AAP_SWAP_FILE}"
    return 0
  fi

  case "$(aap_demo_temp_swap_platform)" in
    darwin) echo "${HOME}/.aap-demo/aap-swap-reserve" ;;
    *) echo "/swapfile-aap-demo" ;;
  esac
}

aap_demo_temp_swap_marker_path() {
  echo "${HOME}/.aap-demo/.temp-swap-active"
}

aap_demo_temp_swap_host_swap_gb() {
  case "$(aap_demo_temp_swap_platform)" in
    linux)
      awk '/SwapTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "0"
      ;;
    darwin)
      local total_mb
      total_mb="$(sysctl -n vm.swapusage 2>/dev/null | sed -E 's/.*total = ([0-9.]+)M.*/\1/')"
      if [[ "${total_mb}" =~ ^[0-9.]+$ ]]; then
        awk -v m="${total_mb}" 'BEGIN {printf "%d", m/1024}'
      else
        echo "0"
      fi
      ;;
    *)
      echo "0"
      ;;
  esac
}

aap_demo_temp_swap_show_status() {
  case "$(aap_demo_temp_swap_platform)" in
    linux)
      echo "Active swap devices:"
      swapon --show || true
      echo ""
      free -h | awk '/^Mem:|^Swap:/'
      ;;
    darwin)
      echo "macOS swap (managed by dynamic_pager):"
      sysctl vm.swapusage 2>/dev/null || true
      if [[ -f "$(aap_demo_temp_swap_marker_path)" ]]; then
        echo ""
        echo "aap-demo disk reserve: $(aap_demo_temp_swap_file_path)"
      fi
      echo ""
      df -h "${HOME}" | awk 'NR==1 || NR==2'
      ;;
    *)
      echo "Temp swap is not supported on this platform."
      ;;
  esac
}

aap_demo_temp_swap_is_active() {
  local swap_file marker_path

  swap_file="$(aap_demo_temp_swap_file_path)"
  marker_path="$(aap_demo_temp_swap_marker_path)"

  case "$(aap_demo_temp_swap_platform)" in
    linux)
      swapon --show --noheadings 2>/dev/null | awk '{print $1}' | grep -qx "${swap_file}"
      ;;
    darwin)
      [[ -f "${marker_path}" && -f "${swap_file}" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

aap_demo_temp_swap_ensure_linux_tools() {
  local missing=""

  for cmd in swapon mkswap; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing="${missing} ${cmd}"
    fi
  done

  if [[ -n "${missing}" ]]; then
    echo "ERROR: Missing Linux swap tools:${missing}" >&2
    echo "  Fedora/RHEL: sudo dnf install util-linux" >&2
    return 1
  fi
}

aap_demo_temp_swap_create_file_linux() {
  local size_gb="$1"
  local swap_file="$2"
  local fs_type

  aap_demo_temp_swap_ensure_linux_tools || return 1

  fs_type="$(findmnt -n -o FSTYPE --target "$(dirname "${swap_file}")" 2>/dev/null || true)"
  echo "Creating ${size_gb}GB Linux swap file at ${swap_file} (${fs_type:-unknown fs}, requires sudo)..."

  case "${fs_type}" in
    btrfs)
      # Fedora default: compression + COW breaks fallocate swap files.
      sudo touch "${swap_file}"
      sudo chattr +C "${swap_file}" 2>/dev/null || true
      sudo dd if=/dev/zero of="${swap_file}" bs=1M count=$((size_gb * 1024)) status=progress conv=fsync
      ;;
    xfs | ext4 | ext3 | ext2)
      if sudo fallocate -l "${size_gb}G" "${swap_file}" 2>/dev/null; then
        :
      else
        sudo dd if=/dev/zero of="${swap_file}" bs=1M count=$((size_gb * 1024)) status=progress conv=fsync
      fi
      ;;
    *)
      if sudo fallocate -l "${size_gb}G" "${swap_file}" 2>/dev/null; then
        :
      else
        sudo dd if=/dev/zero of="${swap_file}" bs=1M count=$((size_gb * 1024)) status=progress conv=fsync
      fi
      ;;
  esac

  sudo chmod 600 "${swap_file}"
  sudo mkswap "${swap_file}"

  if command -v getenforce >/dev/null 2>&1 && command -v chcon >/dev/null 2>&1; then
    if [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
      sudo chcon -t swapfile_t "${swap_file}" 2>/dev/null || true
    fi
  fi
}

aap_demo_temp_swap_create_file_darwin() {
  local size_gb="$1"
  local swap_file="$2"
  local free_gb

  mkdir -p "$(dirname "${swap_file}")"
  free_gb="$(df -g "${swap_file}" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ "${free_gb:-0}" =~ ^[0-9]+$ ]] && [[ "${free_gb}" -lt "${size_gb}" ]]; then
    echo "ERROR: Need ${size_gb}GB free on $(dirname "${swap_file}") (have ${free_gb}GB)" >&2
    echo "  macOS grows swap dynamically; free disk space is required." >&2
    return 1
  fi

  echo "Reserving ${size_gb}GB disk at ${swap_file} for macOS dynamic swap..."
  if command -v mkfile >/dev/null 2>&1; then
    mkfile -n "${size_gb}g" "${swap_file}"
  else
    dd if=/dev/zero of="${swap_file}" bs=1m count=$((size_gb * 1024)) status=progress
  fi
  chmod 600 "${swap_file}"
}

aap_demo_temp_swap_write_marker() {
  local swap_file="$1"
  local size_gb="$2"
  local marker_path

  marker_path="$(aap_demo_temp_swap_marker_path)"
  mkdir -p "$(dirname "${marker_path}")"
  cat >"${marker_path}" <<EOF
AAP_SWAP_FILE=${swap_file}
AAP_SWAP_SIZE_GB=${size_gb}
AAP_SWAP_PLATFORM=$(aap_demo_temp_swap_platform)
EOF
}

aap_demo_temp_swap_enable() {
  local swap_file platform

  if [[ "${SKIP_TEMP_SWAP:-false}" == "true" ]]; then
    echo "Skipping temp swap (SKIP_TEMP_SWAP=true)"
    return 0
  fi

  platform="$(aap_demo_temp_swap_platform)"
  if [[ "${platform}" == "unsupported" ]]; then
    echo "Temp swap is not supported on $(uname -s)."
    return 0
  fi

  if ! [[ "${AAP_SWAP_SIZE_GB}" =~ ^[0-9]+$ ]] || [[ "${AAP_SWAP_SIZE_GB}" -le 0 ]]; then
    echo "ERROR: AAP_SWAP_SIZE_GB must be a positive integer (got: ${AAP_SWAP_SIZE_GB})" >&2
    return 1
  fi

  swap_file="$(aap_demo_temp_swap_file_path)"

  if aap_demo_temp_swap_is_active; then
    printf "  ${_GREEN:-}✓${_NC:-} Temp swap already active: ${swap_file}\n"
    return 0
  fi

  if [[ -f "${swap_file}" ]]; then
    echo "Removing previous temp swap file at ${swap_file}..."
    case "${platform}" in
      linux)
        sudo swapoff "${swap_file}" 2>/dev/null || true
        ;;
    esac
    rm -f "${swap_file}" 2>/dev/null || sudo rm -f "${swap_file}"
  fi
  rm -f "$(aap_demo_temp_swap_marker_path)"

  case "${platform}" in
    linux)
      aap_demo_temp_swap_create_file_linux "${AAP_SWAP_SIZE_GB}" "${swap_file}" || return 1
      sudo swapon "${swap_file}" || {
        echo "ERROR: swapon failed for ${swap_file}" >&2
        echo "  On btrfs use chattr +C before writing; on RHEL ensure SELinux swapfile_t." >&2
        return 1
      }
      ;;
    darwin)
      aap_demo_temp_swap_create_file_darwin "${AAP_SWAP_SIZE_GB}" "${swap_file}" || return 1
      ;;
  esac

  aap_demo_temp_swap_write_marker "${swap_file}" "${AAP_SWAP_SIZE_GB}"

  case "${platform}" in
    linux)
      printf "  ${_GREEN:-}✓${_NC:-} Temp swap enabled: ${swap_file} (${AAP_SWAP_SIZE_GB}GB)\n"
      ;;
    darwin)
      printf "  ${_GREEN:-}✓${_NC:-} Disk reserved for macOS swap: ${swap_file} (${AAP_SWAP_SIZE_GB}GB)\n"
      printf "    macOS grows kernel swap automatically when memory is under pressure.\n"
      ;;
  esac
}

aap_demo_temp_swap_disable() {
  local swap_file marker_path platform

  swap_file="$(aap_demo_temp_swap_file_path)"
  marker_path="$(aap_demo_temp_swap_marker_path)"
  platform="$(aap_demo_temp_swap_platform)"

  case "${platform}" in
    linux)
      if aap_demo_temp_swap_is_active; then
        sudo swapoff "${swap_file}"
        echo "✓ Disabled temp swap: ${swap_file}"
      elif [[ -f "${swap_file}" ]]; then
        echo "Temp swap file exists but is not active: ${swap_file}"
      else
        echo "No temp swap file at ${swap_file}"
        rm -f "${marker_path}"
        return 0
      fi
      sudo rm -f "${swap_file}"
      ;;
    darwin)
      if [[ -f "${swap_file}" ]]; then
        rm -f "${swap_file}"
        echo "✓ Removed macOS disk reserve: ${swap_file}"
      else
        echo "No temp swap reserve at ${swap_file}"
      fi
      ;;
    *)
      echo "Temp swap is not supported on $(uname -s)."
      return 0
      ;;
  esac

  rm -f "${marker_path}"
  echo "✓ Temp swap cleanup complete"
}

# Interactive prompt used during aap-demo create (Linux/macOS + TTY).
aap_demo_prompt_temp_swap() {
  local host_swap_gb default_confirm swap_confirm default_swap_gb input_swap_gb platform

  platform="$(aap_demo_temp_swap_platform)"
  if [[ "${platform}" == "unsupported" ]]; then
    return 0
  fi

  if [[ "${SKIP_TEMP_SWAP:-false}" == "true" ]] || [[ "${QUIET:-false}" == "true" ]]; then
    return 0
  fi

  if aap_demo_temp_swap_is_active; then
    printf "  ${_GREEN}✓${_NC} Temp swap already active: $(aap_demo_temp_swap_file_path)\n"
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
    case "${platform}" in
      darwin) printf "  Host swap: ${host_swap_gb}GB (macOS dynamic)\n" ;;
      *) printf "  Host swap: ${host_swap_gb}GB (zram or other)\n" ;;
    esac
  fi

  if [[ "${HOST_MEMORY_MB:-0}" -gt 36864 ]]; then
    default_confirm="n"
    printf "  Create temp swap for deploy? [y/N]: "
  else
    default_confirm="Y"
    printf "  Create temp swap for deploy? [Y/n]: "
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
