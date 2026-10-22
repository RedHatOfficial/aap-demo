#!/usr/bin/env bash
# =============================================================================
# fleet.sh — QEMU VM lifecycle for AAP fleet nodes
# =============================================================================

# fleet.sh is also sourced directly by deploy.sh, so provide the shared error
# helper when it was not loaded through the main aap-demo script.
if ! command -v _err >/dev/null 2>&1; then
  _err() { printf '\033[0;31mERROR:\033[0m %s\n' "$*" >&2; }
fi

if [ -n "${_FLEET_LOADED:-}" ]; then return 0; fi
_FLEET_LOADED=1

FLEET_ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="${HOME}/.aap-demo/fleet"
FLEET_NODE_MEM="${FLEET_NODE_MEM:-1024}"
FLEET_NODE_CPUS="${FLEET_NODE_CPUS:-2}"
FLEET_NODE_PORT_BASE=2200
# Indices created by the current fleet_create_all invocation.
FLEET_CREATED_INDICES=()

# -----------------------------------------------------------------------------
# Migration from seed-nodes → fleet (one-time)
# -----------------------------------------------------------------------------

_fleet_migrate_from_seed_nodes() {
  local old_dir="${HOME}/.aap-demo/nodes"
  [ -d "$old_dir" ] || return 0
  # Already migrated if fleet dir has node subdirs
  if compgen -G "${FLEET_DIR}/node-*" >/dev/null 2>&1; then
    return 0
  fi

  echo "Migrating fleet data from ~/.aap-demo/nodes/ to ~/.aap-demo/fleet/..."
  mkdir -p "$FLEET_DIR"

  # Move shared files
  for f in base.qcow2 ssh_key ssh_key.pub host_gateway_ip; do
    [ -f "${old_dir}/${f}" ] && mv "${old_dir}/${f}" "${FLEET_DIR}/${f}"
  done

  # Move node directories and update hostnames in meta files
  for node_dir in "${old_dir}"/node-*; do
    [ -d "$node_dir" ] || continue
    local name
    name=$(basename "$node_dir")
    mv "$node_dir" "${FLEET_DIR}/${name}"
    # Update hostname in meta (aap-node-N → aap-fleet-node-N)
    if [ -f "${FLEET_DIR}/${name}/meta" ]; then
      sed -i.bak 's/^HOSTNAME=aap-node-/HOSTNAME=aap-fleet-node-/' "${FLEET_DIR}/${name}/meta"
      rm -f "${FLEET_DIR}/${name}/meta.bak"
    fi
  done

  # Migrate SEED_IMAGE → FLEET_IMAGE in config
  local config="${HOME}/.aap-demo/config"
  if [ -f "$config" ] && grep -q '^SEED_IMAGE=' "$config"; then
    if ! grep -q '^FLEET_IMAGE=' "$config"; then
      sed -i.bak 's/^SEED_IMAGE=/FLEET_IMAGE=/' "$config" && rm -f "${config}.bak"
    else
      sed -i.bak '/^SEED_IMAGE=/d' "$config" && rm -f "${config}.bak"
    fi
  fi

  rmdir "$old_dir" 2>/dev/null || true
  echo "  ✓ Migration complete"
}

_fleet_migrate_from_seed_nodes

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
  local bin="qemu-system-${arch}"
  if command -v "$bin" &>/dev/null; then
    echo "$bin"
  elif [ -x "/usr/libexec/qemu-kvm" ]; then
    # RHEL/CentOS ship qemu-kvm at this path rather than in $PATH
    echo "/usr/libexec/qemu-kvm"
  else
    echo "$bin"
  fi
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

fleet_install_prereqs() {
  case "$(uname -s)" in
    Darwin)
      if ! command -v brew >/dev/null 2>&1; then
        _err "Homebrew is required to install Fleet prerequisites on macOS"
        echo "  Install Homebrew: https://brew.sh/"
        return 1
      fi
      brew install qemu cdrtools
      ;;
    Linux)
      if ! command -v dnf >/dev/null 2>&1; then
        _err "dnf is required to install Fleet prerequisites automatically on Linux"
        echo "  Install qemu-kvm, qemu-img, and genisoimage with your distribution package manager"
        return 1
      fi
      sudo dnf install -y qemu-kvm qemu-img genisoimage
      ;;
    *)
      _err "Cannot install Fleet prerequisites automatically on $(uname -s)"
      return 1
      ;;
  esac
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
# Cloud image acquisition
#
# Enable can use a local QCOW2 or download one. CentOS Stream 9 GenericCloud is
# the default because it is cloud-init ready and published for both x86_64 and
# aarch64. The download is cached outside ~/.aap-demo/fleet so fleet destroy
# does not throw the image away. Published CentOS images are checked against
# the sibling CHECKSUM file; set FLEET_IMAGE_SHA256 to pin a different URL.
# -----------------------------------------------------------------------------

_fleet_is_url() {
  case "$1" in
    http://* | https://*) return 0 ;;
    *) return 1 ;;
  esac
}

_fleet_interactive() {
  if [ "${QUIET:-false}" = true ]; then
    return 1
  fi
  if [ -n "${FLEET_PROMPT_DEVICE:-}" ]; then
    return 0
  fi
  [ -t 0 ]
}

_fleet_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

_fleet_read_line() {
  local value

  if [ -n "${FLEET_PROMPT_DEVICE:-}" ]; then
    if [ -z "${_FLEET_PROMPT_OPENED:-}" ]; then
      exec 9<"${FLEET_PROMPT_DEVICE}" || return 1
      _FLEET_PROMPT_OPENED=1
    fi
    IFS= read -r value <&9 || return 1
  else
    IFS= read -r value || return 1
  fi
  value=${value%$'\r'}
  FLEET_PROMPT_LINE=$(_fleet_trim "$value")
}

_fleet_expand_user_path() {
  local path="$1"
  local rest
  rest="${path#\~/}"
  if [ "$path" = "~" ]; then
    printf '%s\n' "$HOME"
  elif [ "$rest" != "$path" ]; then
    printf '%s\n' "${HOME}/${rest}"
  else
    printf '%s\n' "$path"
  fi
}

# CentOS "latest" images keep the same cache filename when upstream changes.
# Re-check those files against the published checksum instead of trusting the
# saved path forever.
_fleet_default_url_for_cached_image() {
  local path="$1"
  local cache_dir base
  cache_dir=$(_fleet_image_cache_dir)
  cache_dir=$(cd "$cache_dir" 2>/dev/null && pwd) || return 1
  case "$path" in
    "$cache_dir"/*) ;;
    *) return 1 ;;
  esac
  base=$(basename "$path")
  case "$base" in
    CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2)
      printf '%s\n' "https://cloud.centos.org/centos/9-stream/x86_64/images/${base}"
      ;;
    CentOS-Stream-GenericCloud-9-latest.aarch64.qcow2)
      printf '%s\n' "https://cloud.centos.org/centos/9-stream/aarch64/images/${base}"
      ;;
    *)
      return 1
      ;;
  esac
}

_fleet_canonicalize_path() {
  local path="$1"
  local dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

_fleet_image_cache_dir() {
  printf '%s\n' "${FLEET_IMAGE_CACHE_DIR:-${HOME}/.aap-demo/cache/fleet}"
}

_fleet_default_image_url() {
  local arch
  arch=$(_fleet_detect_arch) || return 1
  case "$arch" in
    aarch64)
      printf '%s\n' "https://cloud.centos.org/centos/9-stream/aarch64/images/CentOS-Stream-GenericCloud-9-latest.aarch64.qcow2"
      ;;
    x86_64)
      printf '%s\n' "https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
      ;;
    *)
      return 1
      ;;
  esac
}

_fleet_image_usage() {
  cat <<'EOF' >&2
  Set FLEET_IMAGE to a local .qcow2 path or an http(s) URL.
  Set FLEET_IMAGE_URL to download a specific image.
  Set FLEET_DOWNLOAD_IMAGE=true to download CentOS Stream 9 GenericCloud.
  Re-run without QUIET=true in a terminal to choose an image.
EOF
}

_fleet_url_filename() {
  local url="$1"
  local path name
  path="${url%%\?*}"
  path="${path%%#*}"
  name=$(basename "$path")
  case "$name" in
    '' | . | .. | *[[:space:]]*)
      _err "Cloud image URL has no usable filename: ${url}"
      return 1
      ;;
  esac
  printf '%s\n' "$name"
}

_fleet_is_qcow_name() {
  local name="$1"
  local lower
  lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *.qcow2) return 0 ;;
    *) return 1 ;;
  esac
}

_fleet_curl() {
  curl "$@"
}

_fleet_sha256() {
  local file="$1"
  local sum
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum "$file") || return 1
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 "$file") || return 1
  else
    _err "sha256sum or shasum is required to verify a downloaded Fleet image"
    return 1
  fi
  printf '%s\n' "$sum" | awk '{print $1}'
}

_fleet_checksum_for_file() {
  local filename="$1"
  local checksums="$2"
  local line
  line=$(printf '%s\n' "$checksums" | grep -F -m 1 -- "SHA256 (${filename}) = " || true)
  if [ -z "$line" ]; then
    return 1
  fi
  printf '%s\n' "${line##*= }"
}

# Returns 0 when the file matches, 1 on mismatch, and 2 when the published
# checksum cannot be fetched. The third argument "quiet" suppresses messages.
_fleet_verify_downloaded_image() {
  local file="$1"
  local url="$2"
  local quiet="${3:-}"
  local actual expected checksums checksum_url filename

  if [ -z "${FLEET_IMAGE_SHA256:-}" ]; then
    case "$url" in
      https://cloud.centos.org/* | http://cloud.centos.org/*) ;;
      *) return 0 ;;
    esac
  fi

  actual=$(_fleet_sha256 "$file") || return 1
  actual=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')

  if [ -n "${FLEET_IMAGE_SHA256:-}" ]; then
    expected=$(printf '%s' "$FLEET_IMAGE_SHA256" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  else

    checksum_url="${url%/*}/CHECKSUM"
    filename=$(_fleet_url_filename "$url") || return 1
    if [ "$quiet" != quiet ]; then
      echo "  Verifying ${filename}"
    fi
    if ! checksums=$(_fleet_curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 "$checksum_url"); then
      if [ "$quiet" != quiet ]; then
        _err "Could not download checksum file: ${checksum_url}"
      fi
      return 2
    fi
    if ! expected=$(_fleet_checksum_for_file "$filename" "$checksums"); then
      if [ "$quiet" != quiet ]; then
        _err "No SHA256 entry for ${filename}"
      fi
      return 1
    fi
    expected=$(printf '%s' "$expected" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  fi

  if ! printf '%s\n' "$expected" | grep -Eq '^[0-9a-f]{64}$'; then
    if [ "$quiet" != quiet ]; then
      _err "Cloud image checksum is not a SHA256 digest"
    fi
    return 1
  fi
  if [ "$actual" != "$expected" ]; then
    if [ "$quiet" != quiet ]; then
      _err "Cloud image checksum does not match"
      echo "  Expected: ${expected}" >&2
      echo "  Actual:   ${actual}" >&2
    fi
    return 1
  fi
  if [ "$quiet" != quiet ]; then
    echo "  ✓ Checksum verified"
  fi
  return 0
}

fleet_download_image() {
  local url="$1"
  local cache_dir name dest partial cache_status
  local curl_args=()

  if ! _fleet_is_url "$url"; then
    _err "Cloud image URL must start with http:// or https://: ${url}"
    return 1
  fi
  name=$(_fleet_url_filename "$url") || return 1
  if ! _fleet_is_qcow_name "$name"; then
    _err "Cloud image URL must point to a .qcow2 file: ${url}"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    _err "curl is required to download a Fleet cloud image"
    echo "  Install curl and retry." >&2
    return 1
  fi

  cache_dir=$(_fleet_image_cache_dir)
  mkdir -p "$cache_dir" || return 1
  dest="${cache_dir}/${name}"
  partial="${dest}.partial"

  if [ -f "$dest" ]; then
    cache_status=1
    if _fleet_validate_image "$dest"; then
      cache_status=0
      _fleet_verify_downloaded_image "$dest" "$url" quiet || cache_status=$?
    fi
    if [ "$cache_status" -eq 0 ]; then
      echo "  Using cached QCOW2: ${dest}"
      FLEET_ACQUIRED_IMAGE="$dest"
      return 0
    fi
    if [ "$cache_status" -eq 2 ]; then
      echo "  Checksum could not be downloaded; using cached QCOW2: ${dest}"
      FLEET_ACQUIRED_IMAGE="$dest"
      return 0
    fi
    echo "  Replacing cached QCOW2 that failed verification..."
    rm -f "$dest"
  fi

  echo "  Downloading QCOW2 cloud image..."
  echo "  ${url}"
  echo "  Destination: ${dest}"

  curl_args=(-fL --retry 3 --retry-delay 2 --connect-timeout 20)
  if [ "${QUIET:-false}" = true ] || [ ! -t 1 ]; then
    curl_args+=(-sS)
  else
    curl_args+=(--progress-bar)
  fi

  rm -f "$partial"
  if ! _fleet_curl "${curl_args[@]}" -o "$partial" "$url"; then
    rm -f "$partial"
    _err "Failed to download cloud image: ${url}"
    return 1
  fi
  mv -f "$partial" "$dest" || return 1

  if ! _fleet_verify_downloaded_image "$dest" "$url"; then
    rm -f "$dest"
    return 1
  fi
  if ! _fleet_validate_image "$dest"; then
    if ! command -v qemu-img >/dev/null 2>&1; then
      _err "qemu-img is required to verify the downloaded cloud image"
      echo "  The downloaded file was kept at ${dest}" >&2
    else
      rm -f "$dest"
      _err "Downloaded file is not a valid QCOW2 image"
    fi
    return 1
  fi

  echo "  ✓ Cloud image ready: ${dest}"
  FLEET_ACQUIRED_IMAGE="$dest"
  return 0
}

_fleet_prompt_for_image() {
  local arch url choice path custom
  arch=$(_fleet_detect_arch) || return 1
  url=$(_fleet_default_image_url) || return 1

  cat <<EOF

Fleet needs a QCOW2 cloud image.

  1) Download CentOS Stream 9 GenericCloud (${arch})
     ${url}
     The image is larger than 1 GB and is cached for reuse.
  2) Use a local QCOW2 file
  3) Download a QCOW2 from a URL
EOF

  printf '  Choice [1]: ' >&2
  if ! _fleet_read_line; then
    _err "Could not read Fleet image choice"
    return 1
  fi
  choice="${FLEET_PROMPT_LINE:-1}"
  if [ -z "$choice" ]; then
    choice=1
  fi

  case "$choice" in
    1)
      FLEET_PROMPT_RESULT="$url"
      ;;
    2)
      printf '  Path to QCOW2 cloud image: ' >&2
      if ! _fleet_read_line; then
        _err "Could not read QCOW2 image path"
        return 1
      fi
      path="${FLEET_PROMPT_LINE:-}"
      if [ -z "$path" ]; then
        _err "A QCOW2 image path is required"
        return 1
      fi
      if ! _fleet_is_url "$path"; then
        path=$(_fleet_expand_user_path "$path")
      fi
      FLEET_PROMPT_RESULT="$path"
      ;;
    3)
      printf '  QCOW2 URL: ' >&2
      if ! _fleet_read_line; then
        _err "Could not read QCOW2 URL"
        return 1
      fi
      custom="${FLEET_PROMPT_LINE:-}"
      if [ -z "$custom" ]; then
        _err "A QCOW2 URL is required"
        return 1
      fi
      if ! _fleet_is_url "$custom"; then
        _err "A QCOW2 URL must start with http:// or https://"
        return 1
      fi
      FLEET_PROMPT_RESULT="$custom"
      ;;
    *)
      _err "Unknown image choice: ${choice}"
      return 1
      ;;
  esac
  return 0
}

# Resolve a local QCOW2 or download one. Prints progress to stdout and stores
# the local path in FLEET_ACQUIRED_IMAGE. An empty argument uses FLEET_IMAGE,
# then FLEET_IMAGE_URL, then FLEET_DOWNLOAD_IMAGE=true, then an interactive choice.
fleet_acquire_image() {
  local spec="${1-}"
  local cached_url
  FLEET_ACQUIRED_IMAGE=""

  if [ -z "$spec" ]; then
    spec="${FLEET_IMAGE:-}"
  fi
  if [ -n "$spec" ]; then
    spec=$(_fleet_trim "$spec")
  fi

  if [ -n "$spec" ] && ! _fleet_is_url "$spec"; then
    spec=$(_fleet_expand_user_path "$spec")
    if [ ! -f "$spec" ]; then
      _err "QCOW2 image not found: ${spec}"
      if ! _fleet_interactive; then
        _fleet_image_usage
        return 1
      fi
      echo "  That file is missing. Choose how to get an image." >&2
      spec=""
    fi
  fi

  if [ -z "$spec" ] && [ -n "${FLEET_IMAGE_URL:-}" ]; then
    spec=$(_fleet_trim "$FLEET_IMAGE_URL")
  fi
  if [ -z "$spec" ] && [ "${FLEET_DOWNLOAD_IMAGE:-}" = true ]; then
    spec=$(_fleet_default_image_url) || return 1
  fi
  if [ -z "$spec" ]; then
    if _fleet_interactive; then
      _fleet_prompt_for_image || return 1
      spec="${FLEET_PROMPT_RESULT:-}"
    else
      _err "A QCOW2 cloud image is required"
      _fleet_image_usage
      return 1
    fi
  fi
  if [ -z "$spec" ]; then
    _err "A QCOW2 cloud image is required"
    return 1
  fi

  if _fleet_is_url "$spec"; then
    fleet_download_image "$spec" || return 1
    return 0
  fi

  if [ ! -f "$spec" ]; then
    _err "QCOW2 image not found: ${spec}"
    return 1
  fi
  spec=$(_fleet_canonicalize_path "$spec") || {
    _err "Could not resolve Fleet image path: ${spec}"
    return 1
  }
  if cached_url=$(_fleet_default_url_for_cached_image "$spec"); then
    fleet_download_image "$cached_url" || return 1
    return 0
  fi
  FLEET_ACQUIRED_IMAGE="$spec"
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
    "${FLEET_ADDON_DIR}/cloud-init/user-data.template" >"${ci_dir}/user-data"

  sed -e "s|__INSTANCE_ID__|${hostname}|g" \
    -e "s|__HOSTNAME__|${hostname}|g" \
    "${FLEET_ADDON_DIR}/cloud-init/meta-data.template" >"${ci_dir}/meta-data"

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

_fleet_get_available_ram_mb() {
  if [[ "$OSTYPE" == darwin* ]]; then
    local page_size free_pages
    page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
    free_pages=$(vm_stat 2>/dev/null | awk '/Pages free:/{gsub(/\./, ""); print $3}')
    local inactive_pages
    inactive_pages=$(vm_stat 2>/dev/null | awk '/Pages inactive:/{gsub(/\./, ""); print $3}')
    echo $(((${free_pages:-0} + ${inactive_pages:-0}) * page_size / 1024 / 1024))
  else
    free -m 2>/dev/null | awk '/Mem:/{print $7}'
  fi
}

_fleet_check_ram() {
  local requested="$1"
  local existing
  existing=$(fleet_count 2>/dev/null || echo 0)
  local total_after=$((existing + requested))
  local ram_needed=$((total_after * FLEET_NODE_MEM))

  local available
  available=$(_fleet_get_available_ram_mb)
  if [ -z "$available" ] || [ "$available" -eq 0 ] 2>/dev/null; then
    return 0
  fi

  if [ "$ram_needed" -gt "$available" ]; then
    _err "Not enough memory for ${requested} node(s)"
    echo ""
    echo "  Each node uses ${FLEET_NODE_MEM} MB RAM"
    [ "$existing" -gt 0 ] && echo "  Already running: ${existing} node(s) (${existing} × ${FLEET_NODE_MEM} MB)"
    echo "  Total needed:    ${total_after} × ${FLEET_NODE_MEM} MB = ${ram_needed} MB"
    echo "  Available:       ${available} MB"
    echo ""
    echo "  Options:"
    echo "    • Request fewer nodes"
    echo "    • Reduce per-node memory: FLEET_NODE_MEM=512 aap-demo fleet add ${requested}"
    echo "    • Remove existing nodes first: aap-demo fleet destroy"
    return 1
  fi

  local ram_after_pct=$((ram_needed * 100 / available))
  if [ "$ram_after_pct" -gt 80 ]; then
    printf "  \033[1;33mWARNING: Fleet nodes will use %d MB of %d MB available RAM (%d%%)\033[0m\n" "$ram_needed" "$available" "$ram_after_pct"
    echo "  Reduce with: FLEET_NODE_MEM=512"
    echo ""
  fi

  return 0
}

fleet_create_all() {
  local count="$1"
  local image_path="$2"

  FLEET_CREATED_INDICES=()

  if [ -z "$count" ] || [ "$count" -lt 1 ] 2>/dev/null; then
    _err "Count must be a positive integer"
    return 1
  fi

  if [ -z "$image_path" ]; then
    _err "No image path specified"
    echo "  Use: --image <path-to-qcow2>"
    return 1
  fi

  # Check available RAM before creating nodes
  _fleet_check_ram "$count" || return 1

  _fleet_generate_ssh_key

  echo ""
  echo "Creating ${count} fleet node(s)..."

  local created=0
  for _ in $(seq 1 "$count"); do
    local index
    index=$(_fleet_next_index)
    if fleet_node_create "$image_path" "$index"; then
      created=$((created + 1))
      FLEET_CREATED_INDICES+=("$index")
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
