#!/usr/bin/env bash
# Local cache — save/load AAP container images to skip registry pulls
#
# Usage:
#   aap-demo enable local-cache          # save images from running cluster
#   aap-demo enable local-cache load     # load cached images into cluster
#   aap-demo enable local-cache clear    # delete cache
#   aap-demo disable local-cache         # alias for clear
#
# Images are saved per-preset (openshift vs microshift) since the image
# sets differ. Cache lives at ~/.aap-demo/local-cache/<preset>/

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION="${1:-save}"
CACHE_BASE="${HOME}/.aap-demo/local-cache"

_BOLD='\033[1m'
_GREEN='\033[0;32m'
_YELLOW='\033[0;33m'
_NC='\033[0m'

CRC_SSH_PORT=2222
_detect_crc_ssh_key() {
  local base="${HOME}/.crc/machines/crc"
  if [ -f "${base}/id_ed25519" ]; then
    echo "${base}/id_ed25519"
  elif [ -f "${base}/id_ecdsa" ]; then
    echo "${base}/id_ecdsa"
  else return 1; fi
}

CRC_SSH_KEY="$(_detect_crc_ssh_key 2>/dev/null)" || true
if [ -z "$CRC_SSH_KEY" ]; then
  echo "ERROR: CRC SSH key not found — is the cluster running?"
  exit 1
fi

_ssh() {
  ssh -p "$CRC_SSH_PORT" \
    -i "$CRC_SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    core@127.0.0.1 "$@"
}

# Detect preset
PRESET_RAW=$(crc config get preset 2>&1)
if echo "$PRESET_RAW" | grep -q "not set"; then
  PRESET=$(echo "$PRESET_RAW" | grep -oE "openshift|microshift" | tail -1)
  [ -z "$PRESET" ] && PRESET="openshift"
else
  PRESET=$(echo "$PRESET_RAW" | awk '{print $NF}')
fi
CACHE_DIR="${CACHE_BASE}/${PRESET}"

# --- Clear ---
if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ] || [ "$ACTION" = "clear" ]; then
  if [ -d "$CACHE_DIR" ]; then
    local_size=$(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')
    rm -rf "$CACHE_DIR"
    echo "✓ Cleared image cache for ${PRESET} (${local_size})"
  else
    echo "No image cache found for ${PRESET}"
  fi
  exit 0
fi

# --- Load ---
if [ "$ACTION" = "load" ]; then
  if [ ! -d "$CACHE_DIR" ] || [ -z "$(ls "$CACHE_DIR"/*.tar 2>/dev/null)" ]; then
    echo "No cached images found for ${PRESET}"
    echo "  Run 'aap-demo enable local-cache' first to save images"
    exit 1
  fi

  image_count=$(ls "$CACHE_DIR"/*.tar 2>/dev/null | wc -l | tr -d ' ')
  printf "${_BOLD}Loading ${image_count} cached images into CRC VM...${_NC}\n"
  echo ""

  loaded=0
  failed=0
  for tarball in "$CACHE_DIR"/*.tar; do
    [ -f "$tarball" ] || continue
    img_ref=$(cat "${tarball%.tar}.ref" 2>/dev/null || basename "$tarball" .tar)
    file_size=$(du -h "$tarball" | awk '{print $1}')

    # Truncate long names for display
    display_name="$img_ref"
    if [ ${#display_name} -gt 70 ]; then
      display_name="...${display_name: -67}"
    fi

    printf "  %-72s %6s " "$display_name" "$file_size"

    # Stream tarball into CRI-O via skopeo on the VM
    if _ssh "sudo skopeo copy docker-archive:/dev/stdin containers-storage:'${img_ref}'" <"$tarball" &>/dev/null; then
      printf "${_GREEN}✓${_NC}\n"
      loaded=$((loaded + 1))
    else
      printf "${_YELLOW}✗${_NC}\n"
      failed=$((failed + 1))
    fi
  done

  echo ""
  echo "✓ Loaded ${loaded} images (${failed} failed)"
  exit 0
fi

# --- Save (default) ---
if [ "$ACTION" = "save" ] || [ "$ACTION" = "deploy" ]; then
  printf "${_BOLD}Saving AAP container images from CRC VM...${_NC}\n"
  echo "  Preset: ${PRESET}"
  echo "  Cache:  ${CACHE_DIR}"
  echo ""

  mkdir -p "$CACHE_DIR"

  # Get all Red Hat / registry.k8s.io images from CRI-O
  all_images=$(_ssh "sudo crictl images -o json" 2>/dev/null | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
seen = set()
registries = ['registry.redhat.io', 'registry.k8s.io']
for img in data.get('images', []):
    for digest in img.get('repoDigests', []):
        if any(r in digest for r in registries):
            if digest not in seen:
                seen.add(digest)
                # size in bytes
                size = img.get('size', '0')
                print(f'{size} {digest}')
" 2>/dev/null || true)

  if [ -z "$all_images" ]; then
    echo "No images found in CRC VM"
    exit 1
  fi

  total=$(echo "$all_images" | wc -l | tr -d ' ')
  total_bytes=$(echo "$all_images" | awk '{sum+=$1} END {print sum+0}')
  total_gb=$(((total_bytes + 1073741823) / 1073741824))
  echo "Found ${total} images to cache (~${total_gb}GB uncompressed on disk)"
  if [ "$total_gb" -gt 40 ] && [ -t 0 ]; then
    printf "  ${_YELLOW}Warning:${_NC} cache may exceed README estimate (~30GB). Continue? [y/N]: "
    read -r _cache_confirm </dev/tty || _cache_confirm=""
    case "${_cache_confirm:-n}" in
      [yY]*) ;;
      *)
        echo "Aborted."
        exit 0
        ;;
    esac
  fi
  echo ""

  saved=0
  skipped=0
  failed=0
  while IFS=' ' read -r img_size img_ref; do
    [ -z "$img_ref" ] && continue

    # Safe filename
    safe_name=$(echo "$img_ref" | md5sum | awk '{print $1}')
    tarball="${CACHE_DIR}/${safe_name}.tar"
    ref_file="${CACHE_DIR}/${safe_name}.ref"

    # Truncate long names for display
    display_name="$img_ref"
    if [ ${#display_name} -gt 60 ]; then
      display_name="...${display_name: -57}"
    fi

    # Skip if already cached
    if [ -f "$tarball" ] && [ -f "$ref_file" ]; then
      file_size=$(du -h "$tarball" | awk '{print $1}')
      printf "  %-62s %6s (cached)\n" "$display_name" "$file_size"
      skipped=$((skipped + 1))
      continue
    fi

    printf "  %-62s " "$display_name"

    # Export from CRI-O via skopeo, stream to local file
    # Use -n to prevent SSH from consuming the while-read stdin
    if _ssh -n "sudo skopeo copy --remove-signatures containers-storage:'${img_ref}' docker-archive:/dev/stdout" >"$tarball" 2>/dev/null; then
      echo "$img_ref" >"$ref_file"
      file_size=$(du -h "$tarball" | awk '{print $1}')
      printf "${_GREEN}%6s${_NC}\n" "$file_size"
      saved=$((saved + 1))
    else
      rm -f "$tarball" "$ref_file"
      printf "${_YELLOW}%6s${_NC}\n" "skip"
      failed=$((failed + 1))
    fi
  done <<<"$all_images"

  echo ""
  total_size=$(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')
  echo "✓ Saved ${saved} images, ${skipped} already cached, ${failed} skipped (${total_size} total)"
  echo ""
  echo "To load after a fresh create:"
  echo "  aap-demo enable local-cache load"
  exit 0
fi

echo "Usage: aap-demo enable local-cache [save|load|clear]"
exit 1
