#!/usr/bin/env bash
# CRC VM disk and LVMS persistent-volume size.
# Sourced by includes/crc-create.sh and aap-demo.sh.

aap_demo_crc_disk_default() {
  printf '%s\n' 120
}

aap_demo_crc_pv_default() {
  printf '%s\n' 70
}

aap_demo_crc_storage_config_file() {
  if [ -n "${AAP_DEMO_CONFIG:-}" ]; then
    printf '%s\n' "$AAP_DEMO_CONFIG"
  else
    printf '%s\n' "${HOME}/.aap-demo/config"
  fi
}

aap_demo_resource_prompt_enabled() {
  if [ -t 0 ] || [ "${AAP_DEMO_INTERACTIVE:-}" = "1" ]; then
    return 0
  fi

  local _tty_fd
  if { exec {_tty_fd}</dev/tty; } 2>/dev/null; then
    if [ -t "$_tty_fd" ]; then
      exec {_tty_fd}<&-
      return 0
    fi
    exec {_tty_fd}<&-
  fi
  return 1
}

aap_demo_config_value() {
  local key="$1"
  local config value
  config="$(aap_demo_crc_storage_config_file)"
  if [ ! -f "$config" ]; then
    printf '\n'
    return 0
  fi
  value="$(grep "^${key}=" "$config" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
  printf '%s\n' "$value"
}

aap_demo_resolve_crc_storage() {
  local saved_disk saved_pv default_disk default_pv
  saved_disk="$(aap_demo_config_value CRC_DISK)"
  saved_pv="$(aap_demo_config_value CRC_PV_SIZE)"
  [[ "$saved_disk" =~ ^[0-9]+$ ]] || saved_disk=""
  [[ "$saved_pv" =~ ^[0-9]+$ ]] || saved_pv=""
  default_disk="$(aap_demo_crc_disk_default)"
  default_pv="$(aap_demo_crc_pv_default)"
  CRC_DISK="${CRC_DISK:-${VM_DISK_SIZE:-${saved_disk:-$default_disk}}}"
  CRC_PV_SIZE="${CRC_PV_SIZE:-${VM_PV_SIZE:-${saved_pv:-$default_pv}}}"
}

aap_demo_validate_crc_storage() {
  local disk="$1"
  local pv="$2"
  if ! [[ "$disk" =~ ^[0-9]+$ ]] || [ "$disk" -le 0 ]; then
    printf "Invalid disk size: '%s' (must be a positive integer in GB)\n" "$disk" >&2
    return 1
  fi
  if ! [[ "$pv" =~ ^[0-9]+$ ]] || [ "$pv" -le 0 ]; then
    printf "Invalid persistent volume size: '%s' (must be a positive integer in GB)\n" "$pv" >&2
    return 1
  fi
  if [ "$pv" -ge "$disk" ]; then
    printf 'Persistent volume size (%sGB) must be less than disk size (%sGB)\n' "$pv" "$disk" >&2
    return 1
  fi
}

aap_demo_prompt_crc_storage() {
  local disk_default="${CRC_DISK}"
  local pv_default="${CRC_PV_SIZE}"
  local input_disk input_pv

  printf '  Disk in GB [%s]: ' "$disk_default"
  if ! read -r input_disk </dev/tty; then
    printf 'Unable to read disk size from the terminal.\n' >&2
    return 1
  fi
  input_disk="${input_disk:-$disk_default}"

  printf '  Persistent volume storage in GB [%s]: ' "$pv_default"
  if ! read -r input_pv </dev/tty; then
    printf 'Unable to read persistent volume size from the terminal.\n' >&2
    return 1
  fi
  input_pv="${input_pv:-$pv_default}"

  if ! aap_demo_validate_crc_storage "$input_disk" "$input_pv"; then
    return 1
  fi
  CRC_DISK="$input_disk"
  CRC_PV_SIZE="$input_pv"
}

aap_demo_save_config_value() {
  local key="$1"
  local value="$2"
  local config
  config="$(aap_demo_crc_storage_config_file)"
  mkdir -p "$(dirname "$config")"
  if [ -f "$config" ] && grep -q "^${key}=" "$config"; then
    sed -i.bak "s/^${key}=.*/${key}=${value}/" "$config"
    rm -f "${config}.bak"
  else
    printf '%s=%s\n' "$key" "$value" >>"$config"
  fi
}

aap_demo_save_crc_storage() {
  aap_demo_save_config_value CRC_DISK "$CRC_DISK"
  aap_demo_save_config_value CRC_PV_SIZE "$CRC_PV_SIZE"
  export CRC_DISK CRC_PV_SIZE
}

aap_demo_print_crc_storage() {
  printf 'CRC storage:\n'
  printf '  Disk: %s GB\n' "$1"
  printf '  Persistent volume storage: %s GB\n' "$2"
}

aap_demo_note_crc_storage_limits() {
  local disk="$1"
  local default_disk
  default_disk="$(aap_demo_crc_disk_default)"
  if [ "$disk" -lt "$default_disk" ]; then
    printf 'Note: %sGB is below the %sGB disk used for a full AAP install. Image pulls and the NFS volume can run out of space at this size.\n' \
      "$disk" "$default_disk"
  fi
}

aap_demo_note_existing_crc_disk() {
  if [ -e "${HOME}/.crc/machines/crc/.crc-exist" ] || [ -d "${HOME}/.crc/machines/crc" ]; then
    printf 'The current cluster keeps its existing disk. Run aap-demo destroy && aap-demo create to build a VM with the saved size.\n'
    return 0
  fi
  return 1
}

aap_demo_apply_crc_storage_config() {
  local disk="$1"
  local pv="$2"
  if ! command -v crc >/dev/null 2>&1; then
    printf 'crc is not installed. The size is saved for the next aap-demo create.\n'
    return 0
  fi
  if ! crc config set disk-size "$disk"; then
    printf 'Saved the size, but crc config set disk-size failed.\n' >&2
    return 1
  fi
  if ! crc config set persistent-volume-size "$pv"; then
    printf 'Saved the size, but crc config set persistent-volume-size failed.\n' >&2
    return 1
  fi
}
