#!/usr/bin/env bash
# CRC VM disk and LVMS persistent-volume size (create-time) plus runtime
# disk-growth reconciliation. Sourced by includes/crc-create.sh and aap-demo.sh.
# CRC VM disk and LVMS persistent-volume size.
# Sourced by includes/crc-create.sh and aap-demo.sh.

aap_demo_crc_disk_default() {
  printf '%s\n' 120
}

aap_demo_crc_pv_default() {
  printf '%s\n' 70
}

# OpenShift Local rejects smaller values in `crc config set`.
aap_demo_crc_disk_minimum() {
  printf '%s\n' 31
}

aap_demo_crc_pv_minimum() {
  printf '%s\n' 15
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
  local disk_min pv_min
  disk_min="$(aap_demo_crc_disk_minimum)"
  pv_min="$(aap_demo_crc_pv_minimum)"
  if ! [[ "$disk" =~ ^[0-9]+$ ]] || [ "$disk" -lt "$disk_min" ]; then
    printf "Invalid disk size: '%s' (OpenShift Local requires at least %sGB)\n" "$disk" "$disk_min" >&2
    return 1
  fi
  if ! [[ "$pv" =~ ^[0-9]+$ ]] || [ "$pv" -lt "$pv_min" ]; then
    printf "Invalid persistent volume size: '%s' (OpenShift Local requires at least %sGB)\n" "$pv" "$pv_min" >&2
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

# Prints the live CRC disk size, or "unset" when CRC is still on its default.
# A fresh aap-demo config has no CRC_DISK, which is not the value CRC is using.
aap_demo_crc_disk_setting() {
  local output=""
  local line=""
  if ! output="$(crc config get disk-size 2>&1)"; then
    printf 'Unable to read the current OpenShift Local disk size.\n' >&2
    return 1
  fi
  if [[ "$output" == *"Configuration property 'disk-size' is not set"* ]]; then
    printf 'unset\n'
    return 0
  fi
  while IFS= read -r line; do
    if [[ "$line" =~ ^disk-size[[:space:]]*:[[:space:]]*([0-9]+)$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<<"$output"
  printf 'Unable to read the current OpenShift Local disk size.\n' >&2
  return 1
}

aap_demo_restore_crc_disk_setting() {
  local previous="$1"
  local requested="$2"
  if [ "$previous" = "unset" ]; then
    crc config unset disk-size >/dev/null 2>&1
    return $?
  fi
  if [ "$previous" = "$requested" ]; then
    return 0
  fi
  crc config set disk-size "$previous" >/dev/null 2>&1
  return $?
}

aap_demo_apply_crc_storage_config() {
  local disk="$1"
  local pv="$2"
  local previous_disk=""
  if ! command -v crc >/dev/null 2>&1; then
    printf 'crc is not installed. The size is saved for the next aap-demo create.\n'
    return 0
  fi
  if ! previous_disk="$(aap_demo_crc_disk_setting)"; then
    return 1
  fi
  if ! crc config set disk-size "$disk"; then
    printf 'OpenShift Local rejected disk size %sGB. The saved size was not changed.\n' "$disk" >&2
    return 1
  fi
  if ! crc config set persistent-volume-size "$pv"; then
    if ! aap_demo_restore_crc_disk_setting "$previous_disk" "$disk"; then
      printf 'OpenShift Local rejected persistent volume size %sGB, and the disk size could not be restored.\n' "$pv" >&2
      return 1
    fi
    printf 'OpenShift Local rejected persistent volume size %sGB. The saved size was not changed.\n' "$pv" >&2
    return 1
  fi
}

# --- Runtime CRC disk growth (aap-demo start) ---

_aap_demo_crc_filesystem_size() {
  local values total used available attempt
  # crc start returns once MicroShift is up, but the daemon's vsock SSH forward
  # (port 2222) can lag several seconds behind. Retry the SSH probe before
  # giving up so boot recovery does not fail on the transient gap.
  for attempt in $(seq 1 15); do
    if values=$(infra_exec_cmd df -Pk /var 2>/dev/null); then
      break
    fi
    values=""
    sleep 2
  done
  [ -n "$values" ] || return 1
  read -r total used available <<<"$(awk 'NR == 2 {print $2, $3, $4}' <<<"$values")"
  if ! [[ "$total" =~ ^[1-9][0-9]*$ && "$used" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] \
    || [ "$used" -gt "$total" ] || [ "$available" -gt "$total" ]; then
    echo "ERROR: Could not read CRC filesystem capacity from df." >&2
    return 1
  fi
  printf '%s %s %s\n' "$total" "$used" "$available"
}

aap_demo_start_storage() {
  local values total used available before target actual_bytes host_available config tmp
  local gib=1073741824
  local metadata="${HOME}/.crc/machines/crc/config.json"
  local pending="${AAP_DEMO_DIR:-${HOME}/.aap-demo}/storage-growth.pending"

  if ! values=$(_aap_demo_crc_filesystem_size); then
    _err "Could not check CRC disk usage; check 'aap-demo ssh' before retrying"
    return 1
  fi
  read -r total used available <<<"$values"
  printf 'CRC filesystem: %s%% used; %s GiB available\n' \
    "$((used * 100 / total))" "$((available / 1048576))"
  if [ ! -f "$pending" ] && [ "$((used * 100))" -lt "$((total * 90))" ]; then
    return 0
  fi

  if [ -f "$pending" ]; then
    read -r before target <"$pending" || return 1
    if ! [[ "$before" =~ ^[1-9][0-9]*$ && "$target" =~ ^[1-9][0-9]*$ ]]; then
      _err "Invalid pending CRC storage resize: $pending"
      return 1
    fi
    if [ "$total" -gt "$before" ] && [ "$((used * 100))" -lt "$((total * 90))" ]; then
      rm -f "$pending"
      return 0
    fi
    echo "Retrying the pending CRC disk growth to ${target} GiB..."
  else
    # CRC records the actual disk capacity in bytes, independent of saved preferences.
    actual_bytes=$(jq -er '.Driver.DiskCapacity |
      select(type == "number" and . > 0 and . == floor)' "$metadata") || {
      _err "Cannot determine the existing CRC disk capacity from $metadata"
      return 1
    }
    target=$(((actual_bytes * 120 + 100 * gib - 1) / (100 * gib)))
    host_available=$(df -Pk "$(dirname "$metadata")" | awk 'NR == 2 {print $4}')
    if ! [[ "$host_available" =~ ^[0-9]+$ ]] \
      || [ "$((host_available * 1024))" -lt "$((target * gib - actual_bytes))" ]; then
      _err "Not enough host disk space to grow CRC to ${target} GiB"
      return 1
    fi
    before="$total"
    mkdir -p "$(dirname "$pending")" || return 1
    (umask 077; printf '%s %s\n' "$before" "$target" >"$pending") || return 1
    echo "CRC filesystem is at least 90% full; growing the VM disk by 20% to ${target} GiB."
  fi

  # Persist the target before restarting; a retry must not request the old, smaller disk.
  crc config set disk-size "$target" || return 1
  config="${AAP_DEMO_CONFIG:-${HOME}/.aap-demo/config}"
  mkdir -p "$(dirname "$config")" || return 1
  tmp=$(mktemp "${config}.tmp.XXXXXX") || return 1
  if ! {
    if [ -f "$config" ]; then
      awk '!/^CRC_DISK=/' "$config"
    fi
    printf 'CRC_DISK=%s\n' "$target"
  } >"$tmp" || ! mv "$tmp" "$config"; then
    rm -f "$tmp"
    _err "Could not persist the CRC disk growth target"
    return 1
  fi
  export CRC_DISK="$target"

  echo "Stopping CRC briefly so CRC can grow its disk and root filesystem..."
  if ! crc stop; then
    _err "CRC could not stop gracefully; no forced power-off was attempted. Resolve the shutdown failure and retry 'aap-demo start'"
    return 1
  fi
  _start_crc_cluster || return 1
  setup_kubeconfig
  if ! values=$(_aap_demo_crc_filesystem_size); then
    _err "Could not verify the CRC filesystem after disk growth"
    return 1
  fi
  read -r total used available <<<"$values"
  actual_bytes=$(jq -er '.Driver.DiskCapacity' "$metadata") || return 1
  if [ "$actual_bytes" -lt "$((target * gib))" ] || [ "$total" -le "$before" ] \
    || [ "$((used * 100))" -ge "$((total * 90))" ]; then
    _err "CRC disk/filesystem growth was not completed or usage remains at least 90%; the target is preserved for retry"
    return 1
  fi
  rm -f "$pending"
  printf 'CRC storage grown to %s GiB; filesystem usage is now %s%%\n' \
    "$target" "$((used * 100 / total))"
}
