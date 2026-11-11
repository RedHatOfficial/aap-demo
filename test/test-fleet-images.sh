#!/usr/bin/env bash
# Regression tests for entitled Fleet image download and caching.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "${TEST_DIR}/bin" "${TEST_DIR}/cache"
SOURCE_IMAGE="${TEST_DIR}/source.qcow2"
qemu-img create -q -f qcow2 "$SOURCE_IMAGE" 1M
SOURCE_SHA256=$(sha256sum "$SOURCE_IMAGE" | awk '{print $1}')
export SOURCE_IMAGE

cat >"${TEST_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
config=""
output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      config=$(cat)
      shift 2
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    --write-out | --proto | --max-redirs)
      shift 2
      ;;
    --*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
signed_url="https://access.cdn.redhat.com/test/${FLEET_RHEL9_FILENAME}?user=test&_auth_=signed"
if [ "$url" = "${FLEET_REDHAT_API_BASE}/images/${FLEET_RHEL9_SHA256}/download" ]; then
  if [[ "$config" != *"Authorization: Bearer test-access-token"* ]]; then
    echo "missing bearer token for RHSM API" >&2
    exit 1
  fi
  printf '{"body":{"href":"%s","filename":"%s"}}\n307\n%s' \
    "$signed_url" "$FLEET_RHEL9_FILENAME" "$signed_url"
  exit 0
fi
if [ "$url" != "$signed_url" ] || [ -n "$config" ]; then
  echo "unexpected signed download request" >&2
  exit 1
fi
cp "$SOURCE_IMAGE" "$output"
printf '200'
EOF
chmod +x "${TEST_DIR}/bin/curl"
export PATH="${TEST_DIR}/bin:${PATH}"

export FLEET_IMAGE_CACHE_DIR="${TEST_DIR}/cache"
export FLEET_RHEL9_FILENAME="test-rhel9.qcow2"
export FLEET_RHEL9_SHA256="$SOURCE_SHA256"
export FLEET_RHEL10_FILENAME="test-rhel10.qcow2"
export FLEET_RHEL10_SHA256="$SOURCE_SHA256"
export FLEET_REDHAT_API_BASE="https://api.access.redhat.com/management/v1"

_err() {
  printf 'ERROR: %s\n' "$*" >&2
}

fleet_redhat_access_token() {
  printf 'test-access-token'
}

fleet_redhat_store_project_metadata() {
  return 0
}

# shellcheck source=../addons/fleet/fleet-images.sh
source "${REPO_ROOT}/addons/fleet/fleet-images.sh"

fleet_resolve_image rhel9 >/dev/null
expected_path="${TEST_DIR}/cache/test-rhel9.qcow2"
if [ "$FLEET_RESOLVED_IMAGE" != "$expected_path" ] \
  || ! cmp -s "$SOURCE_IMAGE" "$expected_path"; then
  echo "FAIL: managed RHEL image was not downloaded and resolved" >&2
  exit 1
fi
echo "PASS: downloads and resolves managed RHEL image"

cat >"${TEST_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "cache should have prevented download" >&2
exit 1
EOF
chmod +x "${TEST_DIR}/bin/curl"
fleet_resolve_image rhel9 >/dev/null
if [ "$FLEET_RESOLVED_IMAGE" != "$expected_path" ]; then
  echo "FAIL: verified cached image was not reused" >&2
  exit 1
fi
echo "PASS: reuses verified cached image"

cat >"${TEST_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
config=""
output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      config=$(cat)
      shift 2
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    --write-out | --proto | --max-redirs)
      shift 2
      ;;
    --*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
signed_url="https://access.cdn.redhat.com/test/${FLEET_RHEL10_FILENAME}?user=test&_auth_=signed"
if [ "$url" = "${FLEET_REDHAT_API_BASE}/images/${FLEET_RHEL10_SHA256}/download" ]; then
  if [[ "$config" != *"Authorization: Bearer test-access-token"* ]]; then
    echo "missing bearer token for RHSM API" >&2
    exit 1
  fi
  printf '\n307\n%s' "$signed_url"
  exit 0
fi
if [ -n "$config" ]; then
  echo "signed download unexpectedly included authentication" >&2
  exit 1
fi
if [ "$url" != "$signed_url" ]; then
  echo "unexpected signed URL" >&2
  exit 1
fi
cp "$SOURCE_IMAGE" "$output"
printf '200'
EOF
chmod +x "${TEST_DIR}/bin/curl"
fleet_resolve_image rhel10 >/dev/null
expected_rhel10_path="${TEST_DIR}/cache/test-rhel10.qcow2"
if [ "$FLEET_RESOLVED_IMAGE" != "$expected_rhel10_path" ] \
  || ! cmp -s "$SOURCE_IMAGE" "$expected_rhel10_path"; then
  echo "FAIL: RHSM API URL did not download and resolve the image" >&2
  exit 1
fi
echo "PASS: resolves the signed URL automatically through the RHSM API"

fleet_resolve_image /tmp/custom.qcow2
if [ "$FLEET_RESOLVED_IMAGE" != /tmp/custom.qcow2 ]; then
  echo "FAIL: local image path was not preserved" >&2
  exit 1
fi
echo "PASS: preserves local image paths"

fleet_image_metadata rhel10
if [ "$FLEET_MANAGED_IMAGE_FILENAME" != "test-rhel10.qcow2" ] \
  || [ "$FLEET_MANAGED_IMAGE_SHA256" != "$SOURCE_SHA256" ]; then
  echo "FAIL: RHEL 10 image metadata is incorrect" >&2
  exit 1
fi
echo "PASS: exposes RHEL 10 image metadata"
