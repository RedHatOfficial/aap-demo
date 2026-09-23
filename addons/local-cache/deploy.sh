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
CACHE_FORMAT_VERSION=4
CACHE_REMOTE_ARCHIVE="/tmp/aap-demo-local-cache.oci"
CACHE_CATALOG_METADATA="catalog-digests"

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

# --- Cached operator catalog reference ---
if [ "$ACTION" = "catalog-ref" ]; then
  requested_version="${2:-}"
  metadata_file="${CACHE_DIR}/${CACHE_CATALOG_METADATA}"

  if [ -z "$requested_version" ] || [ ! -s "$metadata_file" ]; then
    exit 1
  fi

  _require_crc_ssh
  cached_catalog_ref=$(awk -F '\t' -v version="$requested_version" \
    '$1 == version {print $3; exit}' "$metadata_file")
  if [ -z "$cached_catalog_ref" ] \
    || ! _crc_exec sudo crictl inspecti "$cached_catalog_ref" &>/dev/null; then
    exit 1
  fi
  printf '%s\n' "$cached_catalog_ref"
  exit 0
fi

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
  printf "${_BOLD}Checking ${image_count} cached images in CRC VM...${_NC}\n"
  echo ""

  loaded=0
  skipped=0
  failed=0
  for tarball in "$CACHE_DIR"/*.tar; do
    [ -f "$tarball" ] || continue
    img_ref=$(cat "${tarball%.tar}.ref" 2>/dev/null || basename "$tarball" .tar)
    local_ref=$(cat "${tarball%.tar}.local-ref" 2>/dev/null || true)
    if [ -z "$local_ref" ]; then
      archive_digest=$(skopeo inspect --raw "oci-archive:${tarball}:aap-demo-cache" 2>/dev/null \
        | sha256sum | awk '{print $1}')
      if [ -n "$archive_digest" ] && [ "${#archive_digest}" -eq 64 ] && [[ "$img_ref" == *@* ]]; then
        local_ref="${img_ref%@*}@sha256:${archive_digest}"
        printf '%s\n' "$local_ref" >"${tarball%.tar}.local-ref"
      else
        printf "  %-72s %6s " "$img_ref" "$(du -h "$tarball" | awk '{print $1}')"
        printf "${_YELLOW}✗${_NC} (missing platform digest)\n"
        failed=$((failed + 1))
        continue
      fi
    fi
    file_size=$(du -h "$tarball" | awk '{print $1}')

    # Truncate long names for display
    display_name="$img_ref"
    if [ ${#display_name} -gt 70 ]; then
      display_name="...${display_name: -67}"
    fi

    # Skip images already present in CRI-O
    if _crc_exec sudo crictl inspecti "$local_ref" &>/dev/null; then
      printf "  %-72s %6s (present)\n" "$display_name" "$file_size"
      skipped=$((skipped + 1))
      continue
    fi

    printf "  %-72s %6s " "$display_name" "$file_size"

    # OCI archives retain signatures and manifest metadata that Docker archives
    # discard. Skopeo cannot read oci-archive from stdin, so stage the archive
    # on the VM, import it, and remove it. Preserve the digest so a mismatch is
    # an error, not a renamed tag.
    if _ssh "cat >'${CACHE_REMOTE_ARCHIVE}' && sudo skopeo copy --all --preserve-digests oci-archive:'${CACHE_REMOTE_ARCHIVE}':aap-demo-cache containers-storage:'${local_ref}'; status=\$?; rm -f '${CACHE_REMOTE_ARCHIVE}'; exit \$status" <"$tarball" &>/dev/null; then
      printf "${_GREEN}✓${_NC}\n"
      loaded=$((loaded + 1))
    else
      printf "${_YELLOW}✗${_NC}\n"
      failed=$((failed + 1))
    fi
  done

  echo ""
  echo "✓ Loaded ${loaded} images, ${skipped} already present (${failed} failed; digest references preserved)"
  if [ "$failed" -gt 0 ]; then
    echo "⚠ ${failed} cached image(s) could not be loaded" >&2
    if [ "${AAP_DEMO_LOCAL_CACHE_QUIET:-}" = "1" ]; then
      echo "  Continuing because cache loading is running as an optional deploy optimization" >&2
      exit 0
    fi
    exit 1
  fi
  exit 0
fi

# --- Validate ---
if [ "$ACTION" = "validate" ]; then
  if [ ! -d "$CACHE_DIR" ]; then
    echo "No image cache found for ${PRESET}"
    exit 1
  fi

  checked=0
  failed=0
  for tarball in "$CACHE_DIR"/*.tar; do
    [ -f "$tarball" ] || continue
    checked=$((checked + 1))
    ref_file="${tarball%.tar}.ref"
    expected_name=$(basename "$tarball" .tar)
    actual_name=$(md5sum "$ref_file" 2>/dev/null | awk '{print $1}')
    if [ ! -s "$ref_file" ] || [ "$expected_name" != "$actual_name" ] \
      || ! tar -tf "$tarball" 2>/dev/null | grep -qx 'oci-layout' \
      || [ ! -s "${tarball%.tar}.local-ref" ]; then
      echo "✗ Invalid cache entry: $(basename "$tarball" .tar)"
      failed=$((failed + 1))
    fi
  done

  if [ "$checked" -eq 0 ]; then
    echo "No cached image archives found for ${PRESET}"
    exit 1
  fi
  if [ "$failed" -gt 0 ]; then
    echo "✗ Cache validation failed: ${failed}/${checked} archive(s) invalid"
    exit 1
  fi
  echo "✓ Cache validation passed: ${checked} archive(s) valid"
  exit 0
fi

# --- Rewrite live workload references ---
if [ "$ACTION" = "rewrite" ]; then
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl is required to rewrite cached image references"
    exit 1
  fi

  mappings=0
  rewrites=0
  for local_ref_file in "$CACHE_DIR"/*.local-ref; do
    [ -f "$local_ref_file" ] || continue
    original_ref=$(cat "${local_ref_file%.local-ref}.ref" 2>/dev/null || true)
    local_ref=$(cat "$local_ref_file" 2>/dev/null || true)
    [ -n "$original_ref" ] && [ -n "$local_ref" ] || continue
    mappings=$((mappings + 1))

    while IFS=$'\t' read -r kind namespace name patch; do
      [ -n "$kind" ] || continue
      if kubectl patch "$kind" "$name" -n "$namespace" --type=json -p "$patch" >/dev/null 2>&1; then
        rewrites=$((rewrites + 1))
      fi
    done < <(kubectl get deployments,statefulsets,daemonsets,jobs,cronjobs -A -o json 2>/dev/null | jq -r \
      --arg old "$original_ref" --arg new "$local_ref" '
      .items[] |
      ([
        ((.spec.template.spec.containers // []) | to_entries[] |
          select(.value.image == $old) |
          {op:"replace", path:("/spec/template/spec/containers/" + (.key|tostring) + "/image"), value:$new}),
        ((.spec.template.spec.initContainers // []) | to_entries[] |
          select(.value.image == $old) |
          {op:"replace", path:("/spec/template/spec/initContainers/" + (.key|tostring) + "/image"), value:$new})
      ] | map(select(.op == "replace"))) as $patch |
      select(($patch | length) > 0) |
      [.kind, .metadata.namespace, .metadata.name, ($patch | tojson)] | @tsv')

    while IFS=$'\t' read -r namespace name patch; do
      [ -n "$name" ] || continue
      if kubectl patch catalogsource "$name" -n "$namespace" --type=json -p "$patch" >/dev/null 2>&1; then
        rewrites=$((rewrites + 1))
      fi
    done < <(kubectl get catalogsources -A -o json 2>/dev/null | jq -r \
      --arg old "$original_ref" --arg new "$local_ref" '
      .items[] | select(.spec.image == $old) |
      [.metadata.namespace, .metadata.name, ([{op:"replace",path:"/spec/image",value:$new}] | tojson)] | @tsv')
  done

  if [ "$mappings" -gt 0 ] && [ "$rewrites" -gt 0 ]; then
    echo "✓ Rewrote ${rewrites} workload/catalog image reference(s) to local platform digests"
  fi
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
  cache_format_version="$CACHE_FORMAT_VERSION"
  cache_format_marker="${CACHE_DIR}/.format-version"
  force_refresh=0
  if [ "$(cat "$cache_format_marker" 2>/dev/null || true)" != "$cache_format_version" ]; then
    force_refresh=1
    echo "  Cache format changed; refreshing OCI archives with local platform digests"
  fi

  # Get all Red Hat / registry.k8s.io images from CRI-O. Keep the raw image
  # list so we can map the current operator catalog tag to its exact digest.
  image_json=$(_ssh "sudo crictl images -o json" 2>/dev/null || true)
  all_images=$(printf '%s\n' "$image_json" | python3 -c "
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

  catalog_versions=$(printf '%s\n' "$image_json" | python3 -c "
import re, sys, json
data = json.loads(sys.stdin.read())
seen = set()
for img in data.get('images', []):
    digests = img.get('repoDigests', [])
    for tag in img.get('repoTags', []):
        match = re.match(r'^(registry\\.redhat\\.io/redhat/redhat-operator-index):v([0-9]+\\.[0-9]+)$', tag)
        if not match:
            continue
        repository, version = match.groups()
        for digest in digests:
            if digest.startswith(repository + '@'):
                key = (version, digest)
                if key not in seen:
                    seen.add(key)
                    print(f'{version}\\t{digest}')
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
  pruned=0
  current_cache_names=$(mktemp)
  catalog_metadata_tmp=$(mktemp)
  while IFS=' ' read -r img_size img_ref; do
    [ -z "$img_ref" ] && continue

    catalog_version=$(printf '%s\n' "$catalog_versions" \
      | awk -F '\t' -v ref="$img_ref" '$2 == ref {print $1; exit}')

    # Safe filename
    safe_name=$(echo "$img_ref" | md5sum | awk '{print $1}')
    echo "$safe_name" >>"$current_cache_names"
    tarball="${CACHE_DIR}/${safe_name}.tar"
    ref_file="${CACHE_DIR}/${safe_name}.ref"

    # Truncate long names for display
    display_name="$img_ref"
    if [ ${#display_name} -gt 60 ]; then
      display_name="...${display_name: -57}"
    fi

    # Skip only if the cached tarball is structurally valid. Older versions
    # captured Skopeo progress output in the tar stream, so a ref file alone
    # is not enough to trust an existing cache entry.
    if [ "$force_refresh" -eq 0 ] && [ -f "$tarball" ] && [ -f "$ref_file" ] \
      && tar -tf "$tarball" 2>/dev/null | grep -qx 'oci-layout'; then
      file_size=$(du -h "$tarball" | awk '{print $1}')
      printf "  %-62s %6s (cached)\n" "$display_name" "$file_size"
      if [ -n "$catalog_version" ] && [ -s "${tarball%.tar}.local-ref" ]; then
        printf '%s\t%s\t%s\n' "$catalog_version" "$img_ref" \
          "$(cat "${tarball%.tar}.local-ref")" >>"$catalog_metadata_tmp"
      fi
      skipped=$((skipped + 1))
      continue
    fi

    printf "  %-62s " "$display_name"

    if [ "$force_refresh" -eq 1 ]; then
      rm -f "$tarball" "$ref_file" "${tarball%.tar}.local-ref"
    fi

    # Export from CRI-O to an OCI archive on the VM, then stream that archive
    # to the host. OCI archives retain signatures and manifest metadata.
    # Use -n to prevent SSH from consuming the while-read stdin
    if _ssh -n "sudo rm -f '${CACHE_REMOTE_ARCHIVE}' && sudo skopeo copy --all --quiet containers-storage:'${img_ref}' oci-archive:'${CACHE_REMOTE_ARCHIVE}':aap-demo-cache && sudo cat '${CACHE_REMOTE_ARCHIVE}' && sudo rm -f '${CACHE_REMOTE_ARCHIVE}'" >"$tarball" 2>/dev/null; then
      manifest_digest=$(skopeo inspect --raw "oci-archive:${tarball}:aap-demo-cache" 2>/dev/null | sha256sum | awk '{print $1}')
      if [ -n "$manifest_digest" ] && [ "${#manifest_digest}" -eq 64 ] && [[ "$img_ref" == *@* ]]; then
        echo "$img_ref" >"$ref_file"
        printf '%s@sha256:%s\n' "${img_ref%@*}" "$manifest_digest" >"${tarball%.tar}.local-ref"
        if [ -n "$catalog_version" ]; then
          printf '%s\t%s\t%s\n' "$catalog_version" "$img_ref" \
            "$(cat "${tarball%.tar}.local-ref")" >>"$catalog_metadata_tmp"
        fi
        file_size=$(du -h "$tarball" | awk '{print $1}')
        printf "${_GREEN}%6s${_NC}\n" "$file_size"
        saved=$((saved + 1))
      else
        rm -f "$tarball" "$ref_file" "${tarball%.tar}.local-ref"
        printf "${_YELLOW}%6s${_NC}\n" "digest"
        failed=$((failed + 1))
      fi
    else
      rm -f "$tarball" "$ref_file" "${tarball%.tar}.local-ref"
      printf "${_YELLOW}%6s${_NC}\n" "skip"
      failed=$((failed + 1))
    fi
  done <<<"$all_images"

  if [ -s "$catalog_metadata_tmp" ]; then
    sort -u "$catalog_metadata_tmp" >"${CACHE_DIR}/${CACHE_CATALOG_METADATA}.tmp"
    mv "${CACHE_DIR}/${CACHE_CATALOG_METADATA}.tmp" "${CACHE_DIR}/${CACHE_CATALOG_METADATA}"
  else
    rm -f "${CACHE_DIR}/${CACHE_CATALOG_METADATA}"
  fi
  rm -f "$catalog_metadata_tmp"

  # Remove corrupt or stale entries that are not part of the current image
  # set. Keeping them would make a later load report failures even though
  # those images are not needed for this deployment.
  for cached_tarball in "$CACHE_DIR"/*.tar; do
    [ -f "$cached_tarball" ] || continue
    cached_name=$(basename "$cached_tarball" .tar)
    if ! grep -Fqx "$cached_name" "$current_cache_names" \
      || ! tar -tf "$cached_tarball" 2>/dev/null | grep -qx 'oci-layout' \
      || [ ! -s "${cached_tarball%.tar}.local-ref" ]; then
      rm -f "$cached_tarball" "${cached_tarball%.tar}.ref" "${cached_tarball%.tar}.local-ref"
      pruned=$((pruned + 1))
    fi
  done
  rm -f "$current_cache_names"

  if [ "$failed" -eq 0 ]; then
    printf '%s\n' "$cache_format_version" >"$cache_format_marker"
  fi

  echo ""
  total_size=$(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')
  echo "✓ Saved ${saved} images, ${skipped} already cached, ${failed} skipped, ${pruned} corrupt entries removed (${total_size} total)"
  echo ""
  echo "To load after a fresh create:"
  echo "  aap-demo enable local-cache load"
  exit 0
fi

echo "Usage: aap-demo enable local-cache [save|load|clear|validate]"
exit 1
