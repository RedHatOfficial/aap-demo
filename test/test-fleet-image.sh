#!/usr/bin/env bash
# Fleet cloud image acquisition without network or QEMU.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FLEET_SH="${REPO_ROOT}/addons/fleet/fleet.sh"
DEPLOY_SH="${REPO_ROOT}/addons/fleet/deploy.sh"
README="${REPO_ROOT}/addons/fleet/README.md"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="${TEST_DIR}/home"
export FLEET_IMAGE_CACHE_DIR="${TEST_DIR}/cache"
mkdir -p "$HOME" "$FLEET_IMAGE_CACHE_DIR"

# shellcheck source=../addons/fleet/fleet.sh
source "$FLEET_SH"

failures=0
fail() {
  echo "✗ $1" >&2
  failures=$((failures + 1))
}

x86_name="CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
x86_url="https://cloud.centos.org/centos/9-stream/x86_64/images/${x86_name}"
IMAGE_BYTES="fleet-image-bytes"

hash_bytes() {
  local tmp sum
  tmp=$(mktemp)
  printf '%s' "$1" >"$tmp"
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum "$tmp")
  else
    sum=$(shasum -a 256 "$tmp")
  fi
  rm -f "$tmp"
  printf '%s\n' "$sum" | awk '{print $1}'
}

IMAGE_HASH=$(hash_bytes "$IMAGE_BYTES")

checksum_for() {
  local filename="$1"
  local hash="$2"
  printf '%s\n' "SHA256 (other.qcow2) = 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  printf 'SHA256 (%s) = %s\n' "$filename" "$hash"
}

_fleet_detect_arch() {
  printf '%s\n' x86_64
}

_fleet_validate_image() {
  if [ "${VALIDATE_SHOULD_FAIL:-false}" = true ]; then
    return 1
  fi
  return 0
}

_fleet_curl() {
  printf '%s\n' "$*" >>"$MOCK_CURL_LOG"
  local out="" url="" prev="" arg
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "-o" ]; then
      out="$arg"
    fi
    case "$arg" in
      http://* | https://*) url="$arg" ;;
    esac
    prev="$arg"
  done
  case "$url" in
    */CHECKSUM)
      if [ "${MOCK_CHECKSUM_FAIL:-false}" = true ]; then
        return 22
      fi
      printf '%s\n' "$MOCK_CHECKSUM_BODY"
      return 0
      ;;
  esac
  if [ -n "$out" ]; then
    if [ "${MOCK_DOWNLOAD_FAIL:-false}" = true ]; then
      printf 'partial' >"$out"
      return 22
    fi
    printf '%s' "$MOCK_IMAGE_BYTES" >"$out"
    return 0
  fi
  return 1
}

reset_env() {
  unset FLEET_IMAGE FLEET_IMAGE_URL FLEET_DOWNLOAD_IMAGE FLEET_IMAGE_SHA256 FLEET_PROMPT_DEVICE
  unset FLEET_ACQUIRED_IMAGE FLEET_PROMPT_RESULT FLEET_PROMPT_LINE
  QUIET=false
  MOCK_CHECKSUM_FAIL=false
  MOCK_DOWNLOAD_FAIL=false
  VALIDATE_SHOULD_FAIL=false
  MOCK_IMAGE_BYTES="$IMAGE_BYTES"
  MOCK_CHECKSUM_BODY=$(checksum_for "$x86_name" "$IMAGE_HASH")
  MOCK_CURL_LOG="${TEST_DIR}/curl.log"
  : >"$MOCK_CURL_LOG"
  rm -rf "$FLEET_IMAGE_CACHE_DIR"
  mkdir -p "$FLEET_IMAGE_CACHE_DIR"
  _FLEET_PROMPT_OPENED=
}

run_acquire() {
  local spec="${1-}"
  local result_file="${TEST_DIR}/acquire-result"
  local err_file="${TEST_DIR}/acquire-err"
  local out_file="${TEST_DIR}/acquire-out"
  rm -f "$result_file"
  (
    if fleet_acquire_image "$spec"; then
      printf '%s\n' "$FLEET_ACQUIRED_IMAGE" >"$result_file"
      exit 0
    fi
    printf '%s\n' "${FLEET_ACQUIRED_IMAGE:-}" >"$result_file"
    exit 1
  ) >"$out_file" 2>"$err_file"
  ACQUIRE_STATUS=$?
  ACQUIRE_PATH=""
  if [ -f "$result_file" ]; then
    ACQUIRE_PATH=$(cat "$result_file")
  fi
  ACQUIRE_ERR=$(cat "$err_file" 2>/dev/null || true)
}

expect_ok() {
  local label="$1"
  if [ "$ACQUIRE_STATUS" -ne 0 ]; then
    fail "${label} should succeed"
    printf '%s\n' "$ACQUIRE_ERR" >&2
  fi
}

expect_fail() {
  local label="$1"
  if [ "$ACQUIRE_STATUS" -eq 0 ]; then
    fail "${label} should fail"
  fi
}

log_has() {
  if ! grep -Fq -- "$1" "$MOCK_CURL_LOG"; then
    fail "$2"
  fi
}

log_lacks() {
  if grep -Fq -- "$1" "$MOCK_CURL_LOG"; then
    fail "$2"
  fi
}

if ! grep -Fq 'fleet_acquire_image' "$DEPLOY_SH"; then
  fail "deploy.sh must acquire an image during enable"
fi
if ! grep -Fq 'FLEET_DOWNLOAD_IMAGE' "$DEPLOY_SH" "$FLEET_SH" "${REPO_ROOT}/aap-demo.sh"; then
  fail "download switch must be documented in the fleet command"
fi
if ! grep -Fq 'https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2' "$FLEET_SH"; then
  fail "x86_64 CentOS Stream image URL missing"
fi
if ! grep -Fq 'https://cloud.centos.org/centos/9-stream/aarch64/images/CentOS-Stream-GenericCloud-9-latest.aarch64.qcow2' "$FLEET_SH"; then
  fail "aarch64 CentOS Stream image URL missing"
fi
if ! grep -Fq 'FLEET_DOWNLOAD_IMAGE=true' "$README"; then
  fail "readme must document non-interactive download"
fi
if ! grep -Fq '.aap-demo/cache/fleet' "$FLEET_SH" "$README"; then
  fail "image cache must live outside the fleet VM directory"
fi

default_url=$(_fleet_default_image_url)
if [ "$default_url" != "$x86_url" ]; then
  fail "default image URL should follow the stubbed architecture"
fi
_fleet_detect_arch() { printf '%s\n' aarch64; }
arm_url=$(_fleet_default_image_url)
if [ "$arm_url" != "https://cloud.centos.org/centos/9-stream/aarch64/images/CentOS-Stream-GenericCloud-9-latest.aarch64.qcow2" ]; then
  fail "aarch64 default image URL mismatch"
fi
_fleet_detect_arch() { printf '%s\n' x86_64; }

(
  unset FLEET_IMAGE_CACHE_DIR
  cache_dir=$(_fleet_image_cache_dir)
  if [ "$cache_dir" != "${HOME}/.aap-demo/cache/fleet" ]; then
    echo "✗ default cache directory is ${cache_dir}" >&2
    exit 1
  fi
) || fail "default cache directory should survive fleet destroy"

reset_env
local_image="${TEST_DIR}/images/local.qcow2"
mkdir -p "${TEST_DIR}/images"
printf 'local' >"$local_image"
run_acquire "$local_image"
expect_ok "local image"
if [ "$ACQUIRE_PATH" != "$local_image" ]; then
  fail "local image path was not kept"
fi
if [ -s "$MOCK_CURL_LOG" ]; then
  fail "local image should not be downloaded"
fi

reset_env
mkdir -p "${TEST_DIR}/my images"
spaced_image="${TEST_DIR}/my images/node.qcow2"
printf 'spaced' >"$spaced_image"
run_acquire "$spaced_image"
expect_ok "path with spaces"
if [ "$ACQUIRE_PATH" != "$spaced_image" ]; then
  fail "path with spaces was rewritten: ${ACQUIRE_PATH}"
fi

reset_env
(
  cd "$TEST_DIR" || exit 1
  printf 'relative' >relative.qcow2
  fleet_acquire_image "relative.qcow2" >"$TEST_DIR/rel-out" 2>"$TEST_DIR/rel-err"
  status=$?
  printf '%s\n' "$status" >"$TEST_DIR/rel-status"
  printf '%s\n' "$FLEET_ACQUIRED_IMAGE" >"$TEST_DIR/rel-path"
)
if [ "$(cat "$TEST_DIR/rel-status")" -ne 0 ] || [ "$(cat "$TEST_DIR/rel-path")" != "${TEST_DIR}/relative.qcow2" ]; then
  fail "relative image path should be canonicalized"
fi

reset_env
QUIET=true
run_acquire "${TEST_DIR}/missing.qcow2"
expect_fail "missing image"
if ! printf '%s\n' "$ACQUIRE_ERR" | grep -Fq 'FLEET_DOWNLOAD_IMAGE'; then
  fail "missing image should explain how to download one"
fi
log_lacks 'http' "missing image should not download"

reset_env
QUIET=true
printf '1\n' >"${TEST_DIR}/prompt"
FLEET_PROMPT_DEVICE="${TEST_DIR}/prompt"
run_acquire ""
expect_fail "quiet empty image"
log_lacks 'http' "quiet mode should not download from a prompt file"

reset_env
QUIET=true
FLEET_DOWNLOAD_IMAGE=true
run_acquire ""
expect_ok "explicit CentOS download"
if [ "$ACQUIRE_PATH" != "${FLEET_IMAGE_CACHE_DIR}/${x86_name}" ]; then
  fail "downloaded image was not cached at the expected path: ${ACQUIRE_PATH}"
fi
if [ "$(cat "$ACQUIRE_PATH")" != "$IMAGE_BYTES" ]; then
  fail "downloaded image contents mismatch"
fi
log_has "$x86_url" "CentOS download should request the default image"
log_has '/CHECKSUM' "CentOS download should verify the published checksum"

reset_env
QUIET=true
FLEET_DOWNLOAD_IMAGE=true
run_acquire ""
saved_image="$ACQUIRE_PATH"
: >"$MOCK_CURL_LOG"
unset FLEET_DOWNLOAD_IMAGE
run_acquire "$saved_image"
expect_ok "saved CentOS cache path"
log_has '/CHECKSUM' "saved CentOS image should be rechecked"
log_lacks ' -o ' "saved CentOS image should not be downloaded again"

reset_env
cached="${FLEET_IMAGE_CACHE_DIR}/${x86_name}"
printf '%s' "$IMAGE_BYTES" >"$cached"
QUIET=true
MOCK_CHECKSUM_FAIL=true
run_acquire "$cached"
expect_ok "saved CentOS image when checksum host is down"
log_lacks ' -o ' "checksum outage should not replace a saved CentOS image"

reset_env
QUIET=true
FLEET_DOWNLOAD_IMAGE=true
MOCK_CHECKSUM_BODY=$(checksum_for "$x86_name" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
run_acquire ""
expect_fail "checksum mismatch"
if [ -e "${FLEET_IMAGE_CACHE_DIR}/${x86_name}" ] || [ -e "${FLEET_IMAGE_CACHE_DIR}/${x86_name}.partial" ]; then
  fail "checksum mismatch should remove the downloaded image"
fi

reset_env
QUIET=true
FLEET_DOWNLOAD_IMAGE=true
MOCK_CHECKSUM_FAIL=true
run_acquire ""
expect_fail "checksum unavailable"
if [ -e "${FLEET_IMAGE_CACHE_DIR}/${x86_name}" ]; then
  fail "a new download without a checksum should not be kept"
fi

reset_env
cached="${FLEET_IMAGE_CACHE_DIR}/${x86_name}"
printf '%s' "$IMAGE_BYTES" >"$cached"
QUIET=true
MOCK_CHECKSUM_FAIL=true
run_acquire "$x86_url"
expect_ok "cached image when checksum host is down"
log_lacks ' -o ' "checksum outage should not replace a cached image"
if [ "$(cat "$cached")" != "$IMAGE_BYTES" ]; then
  fail "cached image was modified during a checksum outage"
fi

reset_env
cached="${FLEET_IMAGE_CACHE_DIR}/${x86_name}"
printf 'old-bytes' >"$cached"
QUIET=true
run_acquire "$x86_url"
expect_ok "replace stale cached image"
if [ "$(cat "$cached")" != "$IMAGE_BYTES" ]; then
  fail "stale cached image was not replaced"
fi
log_has ' -o ' "stale cached image should be downloaded again"

reset_env
QUIET=true
run_acquire "https://images.example.com/custom.qcow2"
expect_ok "custom URL"
if [ "$ACQUIRE_PATH" != "${FLEET_IMAGE_CACHE_DIR}/custom.qcow2" ]; then
  fail "custom URL cache path mismatch: ${ACQUIRE_PATH}"
fi
log_lacks '/CHECKSUM' "custom URL should not fetch a CentOS checksum"

reset_env
QUIET=true
FLEET_IMAGE_SHA256="$IMAGE_HASH"
run_acquire "https://images.example.com/pinned.qcow2"
expect_ok "pinned checksum"
log_lacks '/CHECKSUM' "pinned checksum should not fetch CHECKSUM"

reset_env
QUIET=true
FLEET_IMAGE_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
run_acquire "https://images.example.com/pinned.qcow2"
expect_fail "pinned checksum mismatch"
if [ -e "${FLEET_IMAGE_CACHE_DIR}/pinned.qcow2" ]; then
  fail "pinned checksum mismatch should remove the image"
fi

reset_env
QUIET=true
run_acquire "https://images.example.com/disk.qcow2?token=abc"
expect_ok "URL query string"
if [ "$ACQUIRE_PATH" != "${FLEET_IMAGE_CACHE_DIR}/disk.qcow2" ]; then
  fail "query string should not be part of the cache filename: ${ACQUIRE_PATH}"
fi

reset_env
QUIET=true
run_acquire "https://images.example.com/Disk.QCOW2"
expect_ok "uppercase qcow suffix"
if [ "$ACQUIRE_PATH" != "${FLEET_IMAGE_CACHE_DIR}/Disk.QCOW2" ]; then
  fail "uppercase suffix was rejected: ${ACQUIRE_PATH}"
fi

reset_env
QUIET=true
run_acquire "https://example.com/image.iso"
expect_fail "non-qcow URL"
log_lacks 'http' "non-qcow URL should not be downloaded"

reset_env
QUIET=true
MOCK_DOWNLOAD_FAIL=true
FLEET_DOWNLOAD_IMAGE=true
run_acquire ""
expect_fail "download failure"
if [ -e "${FLEET_IMAGE_CACHE_DIR}/${x86_name}" ] || [ -e "${FLEET_IMAGE_CACHE_DIR}/${x86_name}.partial" ]; then
  fail "failed download should not leave a partial image"
fi

reset_env
QUIET=true
FLEET_DOWNLOAD_IMAGE=true
VALIDATE_SHOULD_FAIL=true
run_acquire ""
expect_fail "invalid qcow"
if command -v qemu-img >/dev/null 2>&1; then
  if [ -e "${FLEET_IMAGE_CACHE_DIR}/${x86_name}" ]; then
    fail "invalid qcow should be removed when qemu-img can inspect it"
  fi
else
  if [ ! -f "${FLEET_IMAGE_CACHE_DIR}/${x86_name}" ]; then
    fail "invalid qcow should be kept when qemu-img is unavailable"
  fi
fi

reset_env
QUIET=true
FLEET_IMAGE_URL="$x86_url"
run_acquire ""
expect_ok "FLEET_IMAGE_URL"
log_has "$x86_url" "FLEET_IMAGE_URL should be downloaded"

reset_env
FLEET_IMAGE_URL="$x86_url"
run_acquire "$local_image"
expect_ok "explicit path beats URL"
if [ "$ACQUIRE_PATH" != "$local_image" ]; then
  fail "explicit path lost to FLEET_IMAGE_URL"
fi
log_lacks 'http' "explicit path should not download FLEET_IMAGE_URL"

reset_env
FLEET_IMAGE="$local_image"
run_acquire ""
expect_ok "FLEET_IMAGE"
if [ "$ACQUIRE_PATH" != "$local_image" ]; then
  fail "empty acquire should use FLEET_IMAGE"
fi

reset_env
printf '2\n~/images/node.qcow2\n' >"${TEST_DIR}/prompt"
mkdir -p "${HOME}/images"
tilde_image="${HOME}/images/node.qcow2"
printf 'tilde' >"$tilde_image"
FLEET_PROMPT_DEVICE="${TEST_DIR}/prompt"
run_acquire ""
expect_ok "tilde prompt"
if [ "$ACQUIRE_PATH" != "$tilde_image" ]; then
  fail "tilde path was not expanded: ${ACQUIRE_PATH}"
fi

reset_env
printf '1\n' >"${TEST_DIR}/prompt"
FLEET_PROMPT_DEVICE="${TEST_DIR}/prompt"
run_acquire ""
expect_ok "prompt downloads default image"
if [ "$ACQUIRE_PATH" != "${FLEET_IMAGE_CACHE_DIR}/${x86_name}" ]; then
  fail "choice 1 did not download the default image: ${ACQUIRE_PATH}"
fi

reset_env
printf '\n' >"${TEST_DIR}/prompt"
FLEET_PROMPT_DEVICE="${TEST_DIR}/prompt"
run_acquire ""
expect_ok "empty choice downloads default image"
log_has "$x86_url" "empty choice should download the default image"

reset_env
printf '3\nhttps://images.example.com/prompted.qcow2\n' >"${TEST_DIR}/prompt"
FLEET_PROMPT_DEVICE="${TEST_DIR}/prompt"
run_acquire ""
expect_ok "prompt custom URL"
if [ "$ACQUIRE_PATH" != "${FLEET_IMAGE_CACHE_DIR}/prompted.qcow2" ]; then
  fail "choice 3 did not download the entered URL: ${ACQUIRE_PATH}"
fi

reset_env
printf '9\n' >"${TEST_DIR}/prompt"
FLEET_PROMPT_DEVICE="${TEST_DIR}/prompt"
run_acquire ""
expect_fail "invalid choice"
log_lacks 'http' "invalid choice should not download"

reset_env
printf '1\n' >"${TEST_DIR}/prompt"
FLEET_PROMPT_DEVICE="${TEST_DIR}/prompt"
run_acquire "${TEST_DIR}/missing.qcow2"
expect_ok "missing configured image falls through to download"
if ! printf '%s\n' "$ACQUIRE_ERR" | grep -Fq 'QCOW2 image not found'; then
  fail "missing configured image should say the file is gone"
fi
log_has "$x86_url" "missing configured image should offer the default download"

reset_env
printf '2\n/not/used.qcow2\n' >"${TEST_DIR}/prompt"
FLEET_PROMPT_DEVICE="${TEST_DIR}/prompt"
FLEET_DOWNLOAD_IMAGE=true
run_acquire ""
expect_ok "download flag skips the prompt"
log_has "$x86_url" "download flag should select the default image"
log_lacks '/not/used.qcow2' "download flag should ignore the prompt path"

if [ "$failures" -gt 0 ]; then
  echo "FAIL: ${failures} fleet image assertion(s) failed" >&2
  exit 1
fi

echo "PASS: Fleet can download and reuse a QCOW2 while enabling"
