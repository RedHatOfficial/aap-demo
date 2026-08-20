#!/usr/bin/env bash
# Local cache — save/load AAP container images to skip registry pulls
#
# Usage:
#   aap-demo enable local-cache          # save images from running cluster
#   aap-demo enable local-cache load     # load cached images into cluster
#   aap-demo enable local-cache clear    # delete cache
#   aap-demo disable local-cache         # alias for clear
#
# Images are saved per CRC preset (aap-demo uses microshift). Cache lives at
# ~/.aap-demo/local-cache/<preset>/

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION="${1:-save}"
CACHE_BASE="${HOME}/.aap-demo/local-cache"

_BOLD='\033[1m'
_GREEN='\033[0;32m'
_YELLOW='\033[0;33m'
_NC='\033[0m'

# shellcheck source=includes/infra-crc.sh
source "${SCRIPT_DIR}/includes/infra-crc.sh"

PRESET="$(_detect_crc_preset)"
CACHE_DIR="${CACHE_BASE}/${PRESET}"

_require_crc_ssh() {
  if [ -z "$CRC_SSH_KEY" ]; then
    if [ "${AAP_DEMO_LOCAL_CACHE_QUIET:-}" = "1" ]; then
      echo "  ⚠ SSH not available — skipping image cache load" >&2
      exit 0
    fi
    echo "ERROR: CRC SSH key not found — is the cluster running?"
    exit 1
  fi
}

_ssh() {
  ssh -p "$CRC_SSH_PORT" "${CRC_SSH_OPTS[@]}" core@127.0.0.1 "$@"
}

# Real Python (skip the Windows Store alias that prints "Python was not found")
_python_cmd() {
  local cmd
  for cmd in python3 python; do
    if command -v "$cmd" >/dev/null 2>&1 && "$cmd" -c 'import json' >/dev/null 2>&1; then
      echo "$cmd"
      return 0
    fi
  done
  return 1
}

# Parse crictl images JSON on stdin → "size digest" lines for Red Hat / k8s.io images.
# Windows jq.exe / python print CRLF; strip CR so skopeo refs stay valid.
_parse_crictl_images() {
  local parsed
  if command -v jq >/dev/null 2>&1; then
    parsed=$(jq -r '
      [.images[]?
       | .size as $s
       | (.repoDigests // [])[]
       | select(contains("registry.redhat.io") or contains("registry.k8s.io"))
       | {size: ($s // 0), digest: .}]
      | unique_by(.digest)[]
      | "\(.size) \(.digest)"
    ') || return $?
  else
    local py
    if py=$(_python_cmd); then
      parsed=$("$py" -c "
import sys, json
data = json.loads(sys.stdin.read() or '{}')
seen = set()
registries = ['registry.redhat.io', 'registry.k8s.io']
for img in data.get('images', []):
    for digest in img.get('repoDigests') or []:
        if any(r in digest for r in registries) and digest not in seen:
            seen.add(digest)
            size = img.get('size', '0')
            print(f'{size} {digest}')
") || return $?
    else
      echo "ERROR: jq or Python 3 is required to parse the CRC image list." >&2
      echo "  Windows Store python3 is not a real interpreter — install jq instead:" >&2
      echo "    winget install jqlang.jq" >&2
      echo "  macOS: brew install jq" >&2
      echo "  Linux: install jq or python3" >&2
      return 1
    fi
  fi
  printf '%s' "$parsed" | tr -d '\r'
}

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
    if [ "${AAP_DEMO_LOCAL_CACHE_QUIET:-}" = "1" ]; then
      exit 0
    fi
    echo "No cached images found for ${PRESET}"
    echo "  Run 'aap-demo enable local-cache' first to save images"
    exit 1
  fi

  _require_crc_ssh

  image_count=$(ls "$CACHE_DIR"/*.tar 2>/dev/null | wc -l | tr -d ' ')
  printf "${_BOLD}Loading ${image_count} cached images into CRC VM...${_NC}\n"
  echo ""

  loaded=0
  skipped=0
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

    # Skip images already present in CRI-O
    if _crc_exec sudo crictl inspecti "$img_ref" &>/dev/null; then
      printf "  %-72s %6s (present)\n" "$display_name" "$file_size"
      skipped=$((skipped + 1))
      continue
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
  echo "✓ Loaded ${loaded} images, ${skipped} already present (${failed} failed)"
  exit 0
fi

# --- Save (default) ---
if [ "$ACTION" = "save" ] || [ "$ACTION" = "deploy" ]; then
  _require_crc_ssh
  printf "${_BOLD}Saving AAP container images from CRC VM...${_NC}\n"
  echo "  Preset: ${PRESET}"
  echo "  Cache:  ${CACHE_DIR}"
  echo ""

  mkdir -p "$CACHE_DIR"

  # Get all Red Hat / registry.k8s.io images from CRI-O
  images_json=$(_ssh "sudo crictl images -o json") || {
    echo "ERROR: Failed to list images from CRC VM (SSH or crictl failed)"
    echo "  Is the cluster running? Try: aap-demo status"
    exit 1
  }

  if ! all_images=$(printf '%s' "$images_json" | _parse_crictl_images); then
    exit 1
  fi

  if [ -z "$all_images" ]; then
    echo "No registry.redhat.io / registry.k8s.io images found in CRC VM"
    echo "  Deploy AAP first: aap-demo deploy"
    echo "  Then re-run: aap-demo enable local-cache"
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
    img_ref="${img_ref%$'\r'}"
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
