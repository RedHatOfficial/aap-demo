#!/usr/bin/env bash
# macOS persistent CRI-O storage fallback tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

MOCK_HOME="${TEST_DIR}/home"
mkdir -p "$MOCK_HOME/.crc/machines/crc"
export HOME="$MOCK_HOME"
export AAP_PERSISTENT_IMAGE_STORE=true
export AAP_PERSISTENT_IMAGE_STORE_OS=Darwin
export AAP_IMAGE_STORE_SIZE_GB=1
export AAP_IMAGE_STORE_DISK="${TEST_DIR}/crio-images.raw"
export AAP_CRC_MACHINE_CONFIG="${MOCK_HOME}/.crc/machines/crc/config.json"

cat >"$AAP_CRC_MACHINE_CONFIG" <<'EOF'
{"Driver":{"VfkitPath":"/usr/local/crc/vfkit"}}
EOF

source "${REPO_ROOT}/includes/persistent-crio-store.sh"

crc() {
  printf '%s\n' "$*" >>"${TEST_DIR}/crc.log"
  return 1
}

infra_exec_cmd() {
  echo "infra_exec_cmd must not be called on macOS" >&2
  return 1
}

output="$(persistent_crio_store_prepare_or_fallback 2>&1)"
printf '%s\n' "$output" | grep -F 'unavailable on macOS/vfkit'

[ ! -e "$AAP_IMAGE_STORE_DISK" ]
[ ! -e "${MOCK_HOME}/.aap-demo/bin/vfkit-persistent-storage" ]
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Driver"]["VfkitPath"])' "$AAP_CRC_MACHINE_CONFIG")" = /usr/local/crc/vfkit ]
[ ! -e "${TEST_DIR}/crc.log" ]
echo "✓ macOS uses the OCI cache fallback without changing CRC/vfkit"

status_output="$(persistent_crio_store_status)"
printf '%s\n' "$status_output" | grep -F 'unavailable on macOS/vfkit'
echo "✓ macOS status reports persistent CRI-O storage as unavailable"

if grep -q 'persistent_crio_store_prepare_before_crc_start' "${REPO_ROOT}/includes/crc-create.sh"; then
  echo "✗ CRC create must not alter vfkit configuration for macOS" >&2
  exit 1
fi
echo "✓ CRC create does not inject an unsupported macOS vfkit wrapper"
