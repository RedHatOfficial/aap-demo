#!/usr/bin/env bash
# =============================================================================
# fleet.sh — QEMU VM lifecycle for AAP fleet nodes
# =============================================================================

if [ -n "${_FLEET_LOADED:-}" ]; then return 0; fi
_FLEET_LOADED=1

FLEET_DIR="${HOME}/.aap-demo/fleet"
FLEET_NODE_MEM="${FLEET_NODE_MEM:-1024}"
FLEET_NODE_CPUS="${FLEET_NODE_CPUS:-2}"
FLEET_NODE_PORT_BASE=2200

# -----------------------------------------------------------------------------
# Architecture detection
# -----------------------------------------------------------------------------

_fleet_detect_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    arm64 | aarch64) echo "aarch64" ;;
    x86_64) echo "x86_64" ;;
    *)
      _err "Unsupported architecture: $arch"
      return 1
      ;;
  esac
}

_fleet_qemu_binary() {
  local arch
  arch=$(_fleet_detect_arch) || return 1
  echo "qemu-system-${arch}"
}

_fleet_qemu_accel() {
  case "$(uname -s)" in
    Darwin) echo "hvf" ;;
    Linux) echo "kvm" ;;
    *)
      _err "Unsupported OS for QEMU acceleration"
      return 1
      ;;
  esac
}

_fleet_qemu_machine() {
  local arch
  arch=$(_fleet_detect_arch) || return 1
  case "$arch" in
    aarch64) echo "virt" ;;
    x86_64) echo "q35" ;;
  esac
}

_fleet_qemu_bios_args() {
  local arch
  arch=$(_fleet_detect_arch) || return 1
  if [ "$arch" != "aarch64" ]; then
    return 0
  fi

  local bios_paths=(
    "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
    "/usr/local/share/qemu/edk2-aarch64-code.fd"
    "/usr/share/qemu/edk2-aarch64-code.fd"
    "/usr/share/AAVMF/AAVMF_CODE.fd"
  )
  for p in "${bios_paths[@]}"; do
    if [ -f "$p" ]; then
      echo "-bios $p"
      return 0
    fi
  done

  _err "UEFI firmware for aarch64 not found"
  echo "  Searched: ${bios_paths[*]}"
  return 1
}

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------

fleet_check_prereqs() {
  local image_path="${1:-}"
  local errors=0

  local qemu_bin
  qemu_bin=$(_fleet_qemu_binary) || return 1

  if ! command -v "$qemu_bin" &>/dev/null; then
    _err "$qemu_bin not found"
    case "$(uname -s)" in
      Darwin) echo "  Install: brew install qemu" ;;
      Linux) echo "  Install: sudo dnf install qemu-kvm (or qemu-system-x86)" ;;
    esac
    errors=$((errors + 1))
  fi

  if ! command -v qemu-img &>/dev/null; then
    _err "qemu-img not found"
    case "$(uname -s)" in
      Darwin) echo "  Install: brew install qemu" ;;
      Linux) echo "  Install: sudo dnf install qemu-img" ;;
    esac
    errors=$((errors + 1))
  fi

  local mkiso_cmd
  mkiso_cmd=$(_fleet_mkisofs_cmd)
  if [ -z "$mkiso_cmd" ]; then
    _err "mkisofs/genisoimage not found"
    case "$(uname -s)" in
      Darwin) echo "  Install: brew install cdrtools" ;;
      Linux) echo "  Install: sudo dnf install genisoimage" ;;
    esac
    errors=$((errors + 1))
  fi

  if [ -n "$image_path" ]; then
    _fleet_validate_image "$image_path" || errors=$((errors + 1))
  fi

  _fleet_qemu_bios_args >/dev/null 2>&1 || {
    local arch
    arch=$(_fleet_detect_arch)
    if [ "$arch" = "aarch64" ]; then
      errors=$((errors + 1))
    fi
  }

  if [ "$errors" -gt 0 ]; then
    return 1
  fi
  return 0
}

_fleet_validate_image() {
  local image_path="$1"

  if [ ! -f "$image_path" ]; then
    _err "QCOW2 image not found: $image_path"
    return 1
  fi

  if ! qemu-img info "$image_path" &>/dev/null; then
    _err "Invalid disk image: $image_path"
    return 1
  fi

  local fmt
  fmt=$(qemu-img info --output=json "$image_path" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('format',''))" 2>/dev/null || echo "")
  if [ "$fmt" != "qcow2" ]; then
    _err "Image is not QCOW2 format (detected: ${fmt:-unknown}): $image_path"
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# SSH key management
# -----------------------------------------------------------------------------

_fleet_generate_ssh_key() {
  local key_path="${FLEET_DIR}/ssh_key"
  if [ -f "$key_path" ]; then
    return 0
  fi
  mkdir -p "$FLEET_DIR"
  ssh-keygen -t ed25519 -f "$key_path" -N "" -C "aap-demo-fleet" -q
  chmod 600 "$key_path"
  chmod 644 "${key_path}.pub"
}

_fleet_ssh_public_key() {
  cat "${FLEET_DIR}/ssh_key.pub"
}

_fleet_ssh_private_key_path() {
  echo "${FLEET_DIR}/ssh_key"
}

# -----------------------------------------------------------------------------
# Cloud-init ISO creation
# -----------------------------------------------------------------------------

_fleet_mkisofs_cmd() {
  if command -v mkisofs &>/dev/null; then
    echo "mkisofs"
  elif command -v genisoimage &>/dev/null; then
    echo "genisoimage"
  fi
}

_fleet_create_cloud_init_iso() {
  local node_dir="$1"
  local index="$2"
  local hostname="aap-fleet-node-${index}"

  local ci_dir="${node_dir}/cloud-init"
  mkdir -p "$ci_dir"

  local pub_key
  pub_key=$(_fleet_ssh_public_key)

  sed "s|__SSH_PUBLIC_KEY__|${pub_key}|g" \
    "${SCRIPT_DIR}/config/cloud-init/user-data.template" >"${ci_dir}/user-data"

  sed -e "s|__INSTANCE_ID__|${hostname}|g" \
    -e "s|__HOSTNAME__|${hostname}|g" \
    "${SCRIPT_DIR}/config/cloud-init/meta-data.template" >"${ci_dir}/meta-data"

  local mkiso_cmd
  mkiso_cmd=$(_fleet_mkisofs_cmd)
  "$mkiso_cmd" -o "${node_dir}/cloud-init.iso" -V cidata -J -r "$ci_dir" 2>/dev/null

  rm -rf "$ci_dir"
}

# -----------------------------------------------------------------------------
# Port management
# -----------------------------------------------------------------------------

_fleet_node_port() {
  local index="$1"
  echo $((FLEET_NODE_PORT_BASE + index))
}

_fleet_check_port_available() {
  local port="$1"
  if lsof -i ":${port}" &>/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Index management
# -----------------------------------------------------------------------------

_fleet_next_index() {
  local index=1
  while [ -d "${FLEET_DIR}/node-${index}" ]; do
    index=$((index + 1))
  done
  echo "$index"
}

_fleet_running_indices() {
  local indices=()
  for meta in "${FLEET_DIR}"/node-*/meta; do
    [ -f "$meta" ] || continue
    local idx
    idx=$(grep '^INDEX=' "$meta" 2>/dev/null | cut -d= -f2)
    [ -n "$idx" ] && indices+=("$idx")
  done
  printf '%s\n' "${indices[@]}" | sort -n
}

# -----------------------------------------------------------------------------
# VM lifecycle
# -----------------------------------------------------------------------------

fleet_node_create() {
  local image_path="$1"
  local index="$2"
  local port
  port=$(_fleet_node_port "$index")
  local hostname="aap-fleet-node-${index}"
  local node_dir="${FLEET_DIR}/node-${index}"

  if [ -d "$node_dir" ]; then
    _err "Node ${index} already exists"
    return 1
  fi

  if ! _fleet_check_port_available "$port"; then
    _err "Port $port is already in use"
    return 1
  fi

  mkdir -p "$node_dir"

  # Copy base image if not already present
  local base_image="${FLEET_DIR}/base.qcow2"
  if [ ! -f "$base_image" ]; then
    echo "  Copying base image..."
    cp "$image_path" "$base_image"
  fi

  # Create thin overlay
  qemu-img create -b "$base_image" -F qcow2 -f qcow2 "${node_dir}/disk.qcow2" >/dev/null 2>&1

  # Generate cloud-init ISO
  _fleet_create_cloud_init_iso "$node_dir" "$index"

  # Build QEMU command
  local qemu_bin accel machine bios_args
  qemu_bin=$(_fleet_qemu_binary) || return 1
  accel=$(_fleet_qemu_accel) || return 1
  machine=$(_fleet_qemu_machine) || return 1
  bios_args=$(_fleet_qemu_bios_args 2>/dev/null) || bios_args=""

  local qemu_cmd=(
    "$qemu_bin"
    -accel "$accel"
    -M "$machine"
    -m "$FLEET_NODE_MEM"
    -smp "$FLEET_NODE_CPUS"
    -cpu host
    -drive "file=${node_dir}/disk.qcow2,format=qcow2"
    -drive "file=${node_dir}/cloud-init.iso,format=raw,if=virtio"
    -netdev "user,id=net0,hostfwd=tcp:0.0.0.0:${port}-:22"
    -device "virtio-net,netdev=net0"
    -display none
    -pidfile "${node_dir}/qemu.pid"
    -daemonize
    -serial "file:${node_dir}/console.log"
  )

  if [ -n "$bios_args" ]; then
    # shellcheck disable=SC2206
    qemu_cmd+=($bios_args)
  fi

  echo "  Starting VM ${hostname} (port ${port})..."
  if ! "${qemu_cmd[@]}" 2>"${node_dir}/qemu-error.log"; then
    _err "Failed to start QEMU VM"
    cat "${node_dir}/qemu-error.log" >&2
    rm -rf "$node_dir"
    return 1
  fi

  local pid
  pid=$(cat "${node_dir}/qemu.pid" 2>/dev/null || echo "")

  # Write meta file
  cat >"${node_dir}/meta" <<EOF
INDEX=${index}
PORT=${port}
PID=${pid}
HOSTNAME=${hostname}
STATUS=running
EOF

  # Wait for SSH
  echo "  Waiting for SSH on port ${port}..."
  local ssh_key
  ssh_key=$(_fleet_ssh_private_key_path)
  local attempts=0
  local max_attempts=60
  while [ "$attempts" -lt "$max_attempts" ]; do
    if ssh -p "$port" -i "$ssh_key" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=2 -o BatchMode=yes \
      ansible@127.0.0.1 'true' 2>/dev/null; then
      echo "  ✓ ${hostname} ready (SSH on port ${port})"
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 3
  done

  echo "  ⚠ SSH not ready after ${max_attempts} attempts — VM may still be booting"
  echo "  Check console log: ${node_dir}/console.log"
  return 0
}

fleet_node_delete() {
  local index="$1"
  local node_dir="${FLEET_DIR}/node-${index}"

  if [ ! -d "$node_dir" ]; then
    _err "Node ${index} does not exist"
    return 1
  fi

  local pid hostname
  pid=$(grep '^PID=' "${node_dir}/meta" 2>/dev/null | cut -d= -f2)
  hostname=$(grep '^HOSTNAME=' "${node_dir}/meta" 2>/dev/null | cut -d= -f2)

  # Kill QEMU process
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "  Stopping ${hostname:-node-${index}} (PID ${pid})..."
    kill "$pid" 2>/dev/null || true
    local wait=0
    while kill -0 "$pid" 2>/dev/null && [ "$wait" -lt 10 ]; do
      sleep 1
      wait=$((wait + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi

  rm -rf "$node_dir"
  echo "  ✓ Removed ${hostname:-node-${index}}"
}

_fleet_stop_vm() {
  local index="$1"
  local node_dir="${FLEET_DIR}/node-${index}"
  [ -d "$node_dir" ] || return 0

  local pid
  pid=$(grep '^PID=' "${node_dir}/meta" 2>/dev/null | cut -d= -f2)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    local wait=0
    while kill -0 "$pid" 2>/dev/null && [ "$wait" -lt 5 ]; do
      sleep 1
      wait=$((wait + 1))
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
}

fleet_list() {
  local found=false
  printf "  %-6s %-20s %-8s %-10s %s\n" "INDEX" "HOSTNAME" "PORT" "PID" "STATUS"
  printf "  %-6s %-20s %-8s %-10s %s\n" "-----" "--------" "----" "---" "------"

  for meta in "${FLEET_DIR}"/node-*/meta; do
    [ -f "$meta" ] || continue
    found=true

    local idx="" port="" pid="" hostname="" status=""
    idx=$(grep '^INDEX=' "$meta" | cut -d= -f2)
    port=$(grep '^PORT=' "$meta" | cut -d= -f2)
    pid=$(grep '^PID=' "$meta" | cut -d= -f2)
    hostname=$(grep '^HOSTNAME=' "$meta" | cut -d= -f2)

    # Check if actually running
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      status="running"
    else
      status="stopped"
    fi

    printf "  %-6s %-20s %-8s %-10s %s\n" "$idx" "$hostname" "$port" "$pid" "$status"
  done

  if [ "$found" = false ]; then
    echo "  No fleet nodes found"
    echo ""
    echo "  Create nodes: aap-demo fleet add <count> --image <path>"
  fi
}

fleet_create_all() {
  local count="$1"
  local image_path="$2"

  if [ -z "$count" ] || [ "$count" -lt 1 ] 2>/dev/null; then
    _err "Count must be a positive integer"
    return 1
  fi

  if [ -z "$image_path" ]; then
    _err "No image path specified"
    echo "  Use: --image <path-to-qcow2>"
    return 1
  fi

  _fleet_generate_ssh_key

  echo ""
  echo "Creating ${count} fleet node(s)..."

  local created=0
  for _ in $(seq 1 "$count"); do
    local index
    index=$(_fleet_next_index)
    if fleet_node_create "$image_path" "$index"; then
      created=$((created + 1))
    fi
  done

  echo ""
  if [ "$created" -eq "$count" ]; then
    echo "✓ Created ${created} fleet node(s)"
  else
    echo "⚠ Created ${created}/${count} fleet node(s)"
  fi
}

fleet_stop_all() {
  [ -d "$FLEET_DIR" ] || return 0

  local stopped=0
  for meta in "${FLEET_DIR}"/node-*/meta; do
    [ -f "$meta" ] || continue
    local idx
    idx=$(grep '^INDEX=' "$meta" | cut -d= -f2)
    _fleet_stop_vm "$idx"
    stopped=$((stopped + 1))
  done
  if [ "$stopped" -gt 0 ]; then
    echo "  ✓ Stopped ${stopped} fleet node(s)"
  fi
}

fleet_destroy_all() {
  [ -d "$FLEET_DIR" ] || return 0

  echo "Destroying all fleet nodes..."
  for meta in "${FLEET_DIR}"/node-*/meta; do
    [ -f "$meta" ] || continue
    local idx
    idx=$(grep '^INDEX=' "$meta" | cut -d= -f2)
    fleet_node_delete "$idx"
  done
  rm -rf "$FLEET_DIR"
  echo "✓ All fleet nodes destroyed"
}

fleet_remove_last() {
  local count="${1:-1}"
  local indices
  indices=$(_fleet_running_indices)

  if [ -z "$indices" ]; then
    echo "No fleet nodes to remove"
    return 0
  fi

  local to_remove
  to_remove=$(echo "$indices" | tail -n "$count")
  local removed=0

  for idx in $to_remove; do
    fleet_node_delete "$idx"
    removed=$((removed + 1))
  done

  echo "✓ Removed ${removed} fleet node(s)"
}

fleet_remove_by_name() {
  local name="$1"

  # Extract index from name (e.g., "aap-fleet-node-3" -> 3, or just "3" -> 3)
  local index
  index=$(echo "$name" | sed 's/^aap-fleet-node-//')
  if ! [[ "$index" =~ ^[0-9]+$ ]]; then
    _err "Invalid node name or index: $name"
    return 1
  fi

  fleet_node_delete "$index"
}

# Count of running nodes
fleet_count() {
  local count=0
  for meta in "${FLEET_DIR}"/node-*/meta; do
    [ -f "$meta" ] || continue
    local pid
    pid=$(grep '^PID=' "$meta" | cut -d= -f2)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Save image path to config for reuse
_fleet_save_image_config() {
  local image_path="$1"
  local config="${AAP_DEMO_CONFIG_FILE:-$HOME/.aap-demo/config}"
  mkdir -p "$(dirname "$config")"
  if [ -f "$config" ] && grep -q '^FLEET_IMAGE=' "$config"; then
    sed -i.bak "s|^FLEET_IMAGE=.*|FLEET_IMAGE=${image_path}|" "$config" && rm -f "${config}.bak"
  else
    echo "FLEET_IMAGE=${image_path}" >>"$config"
  fi
}
