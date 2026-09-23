#!/usr/bin/env bash
# Persistent CRI-O image storage for the CRC/MicroShift VM.
#
# This is deliberately opt-in. The host-owned disk survives `crc delete` while
# the CRC VM and its normal disks do not. Persistent CRI-O storage is supported
# on Linux/libvirt; macOS/vfkit uses the OCI image cache.

_persistent_crio_store_enabled() {
  [ "${AAP_PERSISTENT_IMAGE_STORE:-false}" = "true" ]
}

_persistent_crio_store_os() {
  echo "${AAP_PERSISTENT_IMAGE_STORE_OS:-$(uname -s)}"
}

_persistent_crio_store_is_macos() {
  [ "$(_persistent_crio_store_os)" = "Darwin" ]
}

_persistent_crio_store_disk() {
  if [ -n "${AAP_IMAGE_STORE_DISK:-}" ]; then
    echo "$AAP_IMAGE_STORE_DISK"
  elif _persistent_crio_store_is_macos; then
    echo "${HOME}/.aap-demo/storage/crio-images.raw"
  else
    echo "${HOME}/.aap-demo/storage/crio-images.qcow2"
  fi
}

_persistent_crio_store_size_gb() {
  echo "${AAP_IMAGE_STORE_SIZE_GB:-60}"
}

_persistent_crio_store_unsupported_on_macos() {
  echo "Persistent CRI-O storage is unavailable on macOS/vfkit; using the OCI image cache" >&2
}

persistent_crio_store_create_disk() {
  _persistent_crio_store_create_disk
}

_persistent_crio_store_disk_size() {
  local disk attachment size
  disk="$(_persistent_crio_store_disk)"

  if _persistent_crio_store_is_macos && [ -e "$disk" ]; then
    stat -f '%z bytes' "$disk"
    return 0
  fi

  if command -v virsh >/dev/null 2>&1; then
    attachment="$(_persistent_crio_store_virsh domblklist crc --details 2>/dev/null \
      | awk -v disk="$disk" '$4 == disk {print $3; exit}')"
    if [ -n "$attachment" ]; then
      size="$(_persistent_crio_store_virsh domblkinfo crc "$attachment" --human 2>/dev/null \
        | awk -F': *' '/^Capacity:/ {print $2; exit}')"
      [ -n "$size" ] && {
        echo "$size"
        return 0
      }
    fi
  fi

  if command -v qemu-img >/dev/null 2>&1 && [ -e "$disk" ]; then
    size=$(qemu-img info --force-share "$disk" 2>/dev/null \
      | awk -F': *' '/^virtual size:/ {print $2; exit}')
    [ -n "$size" ] && {
      echo "$size"
      return 0
    }
  fi

  echo "unknown"
}

persistent_crio_store_status() {
  local disk target blklist attachment disk_state disk_size

  if _persistent_crio_store_is_macos; then
    printf "Persistent storage: unavailable on macOS/vfkit (using OCI image cache)\n"
    return 0
  fi

  disk="$(_persistent_crio_store_disk)"
  target="${AAP_IMAGE_STORE_TARGET:-vdb}"
  disk_state=$([ -e "$disk" ] && echo present || echo missing)

  if [ ! -e "$disk" ] && ! _persistent_crio_store_enabled; then
    printf "Persistent storage: disabled\n"
    return 0
  fi

  printf "Persistent storage:\n"
  if [ "$disk_state" = "present" ]; then
    disk_size="$(_persistent_crio_store_disk_size)"
    printf "  Disk:        %s (present, %s)\n" "$disk" "$disk_size"
  else
    printf "  Disk:        %s (missing)\n" "$disk"
  fi

  if ! command -v virsh >/dev/null 2>&1; then
    printf "  Attachment:  unavailable (virsh not found)\n"
    return 0
  fi

  blklist="$(_persistent_crio_store_virsh domblklist crc --details 2>/dev/null || true)"
  attachment=$(echo "$blklist" | awk -v disk="$disk" '$4 == disk {print $3; exit}')
  if [ -n "$attachment" ]; then
    printf "  Attachment:  attached as %s\n" "$attachment"
  elif echo "$blklist" | awk -v target="$target" '$3 == target {found=1} END {exit !found}'; then
    printf "  Attachment:  target %s is occupied by another disk\n" "$target"
  else
    printf "  Attachment:  detached\n"
  fi
}

_persistent_crio_store_virsh() {
  virsh -c "${AAP_LIBVIRT_URI:-qemu:///system}" "$@"
}

_persistent_crio_store_create_disk() {
  local disk size
  if _persistent_crio_store_is_macos; then
    _persistent_crio_store_unsupported_on_macos
    return 1
  fi

  disk="$(_persistent_crio_store_disk)"
  size="$(_persistent_crio_store_size_gb)"

  if [ -e "$disk" ]; then
    return 0
  fi
  if ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -le 0 ]; then
    echo "ERROR: AAP_IMAGE_STORE_SIZE_GB must be a positive integer" >&2
    return 1
  fi
  mkdir -p "$(dirname "$disk")"
  echo "Creating persistent CRI-O image disk: ${disk} (${size}GB)"
  qemu-img create -f qcow2 -o lazy_refcounts=on "$disk" "${size}G"
}

_persistent_crio_store_attach() {
  local disk target blklist
  disk="$(_persistent_crio_store_disk)"
  target="${AAP_IMAGE_STORE_TARGET:-vdb}"

  _persistent_crio_store_create_disk || return 1
  blklist="$(_persistent_crio_store_virsh domblklist crc --details 2>/dev/null || true)"
  if echo "$blklist" | awk -v target="$target" -v disk="$disk" \
    '$3 == target && $4 == disk {found=1} END {exit !found}'; then
    return 0
  fi
  if echo "$blklist" | awk -v target="$target" '$3 == target {found=1} END {exit !found}'; then
    echo "ERROR: CRC disk target ${target} is already attached to a different source" >&2
    return 1
  fi

  echo "Attaching persistent CRI-O image disk to CRC (${target})..."
  _persistent_crio_store_virsh attach-disk crc "$disk" "$target" \
    --targetbus virtio --driver qemu --subdriver qcow2 --persistent --live
}

_persistent_crio_store_mount() {
  local target device format_allowed
  target="${AAP_IMAGE_STORE_TARGET:-vdb}"
  format_allowed="${AAP_IMAGE_STORE_FORMAT:-false}"

  infra_exec_cmd bash -s -- "$target" "$format_allowed" <<'REMOTE'
set -eu
target="$1"
format_allowed="$2"
device="/dev/${target}"
mountpoint="/var/lib/containers/storage"
staging="/var/lib/containers/.aap-demo-persistent-storage"
selinux_marker="$mountpoint/.aap-demo-selinux-restored"

udevadm settle || true
if ! [ -b "$device" ]; then
  echo "ERROR: Persistent CRI-O disk $device is not present" >&2
  exit 1
fi

if ! blkid "$device" >/dev/null 2>&1; then
  if [ "$format_allowed" != "true" ]; then
    echo "ERROR: $device has no filesystem. Set AAP_IMAGE_STORE_FORMAT=true once to format it." >&2
    exit 2
  fi
  mkfs.xfs -f "$device"
fi

filesystem_type="$(blkid -s TYPE -o value "$device")"
filesystem_uuid="$(blkid -s UUID -o value "$device")"
if [ -z "$filesystem_type" ] || [ -z "$filesystem_uuid" ]; then
  echo "ERROR: Could not read the filesystem identity from $device" >&2
  exit 1
fi

systemctl stop microshift 2>/dev/null || true
systemctl stop crio 2>/dev/null || true
mkdir -p "$mountpoint" "$staging"

if mountpoint -q "$mountpoint"; then
  mounted_source="$(findmnt -n -o SOURCE --target "$mountpoint")"
  if [ "$(readlink -f "$mounted_source")" != "$(readlink -f "$device")" ]; then
    echo "ERROR: $mountpoint is already mounted from $mounted_source" >&2
    exit 1
  fi
else
  mount "$device" "$staging"
  if [ -z "$(find "$staging" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    cp -a "$mountpoint"/. "$staging"/ 2>/dev/null || true
  fi
  umount "$staging"
  mount "$device" "$mountpoint"
fi

# Make the mount available before CRI-O starts after a VM reboot. The CRC VM is
# disposable, so this drop-in is intentionally guest-local and is recreated
# whenever the persistent store is prepared.
mkdir -p /etc/systemd/system/crio.service.d
cat > /etc/systemd/system/crio.service.d/10-aap-demo-persistent-storage.conf <<'UNIT'
[Unit]
RequiresMountsFor=/var/lib/containers/storage
UNIT
fstab_tmp="$(mktemp)"
awk -v mountpoint="$mountpoint" '$2 != mountpoint {print}' /etc/fstab > "$fstab_tmp"
printf 'UUID=%s %s %s defaults,nofail 0 0\n' \
  "$filesystem_uuid" "$mountpoint" "$filesystem_type" >> "$fstab_tmp"
cat "$fstab_tmp" > /etc/fstab
rm -f "$fstab_tmp"
systemctl daemon-reload

if [ -e "$selinux_marker" ]; then
  restorecon -F "$mountpoint" 2>/dev/null || true
else
  restorecon -RF "$mountpoint" 2>/dev/null || true
  touch "$selinux_marker"
fi
systemctl start crio
systemctl restart microshift 2>/dev/null || true
REMOTE
}

_persistent_crio_store_attached() {
  local target disk
  target="${AAP_IMAGE_STORE_TARGET:-vdb}"
  disk="$(_persistent_crio_store_disk)"
  _persistent_crio_store_virsh domblklist crc --details 2>/dev/null \
    | awk -v target="$target" -v disk="$disk" \
      '$3 == target && $4 == disk {found=1} END {exit !found}'
}

persistent_crio_store_prepare() {
  _persistent_crio_store_enabled || return 0
  if _persistent_crio_store_is_macos; then
    _persistent_crio_store_unsupported_on_macos
    return 1
  fi
  command -v virsh >/dev/null 2>&1 || {
    echo "ERROR: virsh is unavailable; cannot prepare persistent CRI-O storage" >&2
    return 1
  }
  command -v qemu-img >/dev/null 2>&1 || {
    echo "ERROR: qemu-img is unavailable; cannot prepare persistent CRI-O storage" >&2
    return 1
  }

  _persistent_crio_store_attach || return 1
  if _persistent_crio_store_mount; then
    return 0
  fi

  echo "WARNING: Persistent CRI-O storage could not be mounted; detaching it and using the OCI cache" >&2
  if ! persistent_crio_store_detach true; then
    echo "ERROR: Could not cleanly detach the failed persistent CRI-O storage setup" >&2
    return 2
  fi
  return 1
}

persistent_crio_store_prepare_or_fallback() {
  persistent_crio_store_prepare && return 0
  local prepare_status=$?
  if [ "$prepare_status" -eq 2 ]; then
    echo "ERROR: Persistent CRI-O storage cleanup failed; refusing to continue" >&2
    return 1
  fi
  if _persistent_crio_store_enabled; then
    echo "WARNING: Continuing with the OCI image-cache fallback" >&2
  fi
  return 0
}

persistent_crio_store_detach() {
  _persistent_crio_store_enabled || return 0
  if _persistent_crio_store_is_macos; then
    return 0
  fi
  local target restore_services crc_state detach_live
  target="${AAP_IMAGE_STORE_TARGET:-vdb}"
  restore_services="${1:-false}"
  detach_live=false

  _persistent_crio_store_attached || return 0
  crc_state="$(_persistent_crio_store_virsh domstate crc 2>/dev/null || true)"
  case "$crc_state" in
    running)
      detach_live=true
      infra_exec_cmd bash -s -- "$target" "$restore_services" <<'REMOTE' || return 1
set -eu
target="$1"
restore_services="$2"
systemctl stop microshift 2>/dev/null || true
systemctl stop crio 2>/dev/null || true
if mountpoint -q /var/lib/containers/storage; then
  mounted_source="$(findmnt -n -o SOURCE --target /var/lib/containers/storage)"
  if [ "$(readlink -f "$mounted_source")" = "$(readlink -f "/dev/$target")" ]; then
    # CRI-O can leave overlay submounts behind after MicroShift stops. Unmount
    # the persistent mount tree as a unit and fail closed if anything remains.
    if ! umount --recursive /var/lib/containers/storage; then
      echo "ERROR: Persistent CRI-O storage is still busy; leaving it attached" >&2
      systemctl start crio 2>/dev/null || true
      systemctl restart microshift 2>/dev/null || true
      exit 1
    fi
  else
    echo "Persistent storage is not mounted at /var/lib/containers/storage; leaving the active mount in place" >&2
  fi
fi
if [ "$restore_services" = "true" ]; then
  systemctl start crio
  systemctl restart microshift 2>/dev/null || true
fi
REMOTE
      ;;
    "")
      echo "ERROR: Could not determine CRC VM state; refusing to detach persistent storage" >&2
      return 1
      ;;
    *)
      echo "Persistent CRI-O storage is attached but CRC is ${crc_state}; detaching without guest unmount"
      ;;
  esac

  if [ "$detach_live" = true ]; then
    _persistent_crio_store_virsh detach-disk crc "$target" --persistent --live
  else
    _persistent_crio_store_virsh detach-disk crc "$target" --persistent
  fi
}
