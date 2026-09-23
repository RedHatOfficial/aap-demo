#!/usr/bin/env bash
# macOS persistent CRI-O storage tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

MOCK_HOME="${TEST_DIR}/home"
mkdir -p "$MOCK_HOME/.crc/machines/crc" "$MOCK_HOME/.aap-demo/bin"
export HOME="$MOCK_HOME"
export AAP_PERSISTENT_IMAGE_STORE=true
export AAP_IMAGE_STORE_SIZE_GB=1
export AAP_IMAGE_STORE_DISK="${TEST_DIR}/crio-images.raw"
export AAP_CRC_MACHINE_CONFIG="${MOCK_HOME}/.crc/machines/crc/config.json"

# Exercise the Darwin branch while running on any host.
uname() {
  echo Darwin
}
export -f uname

cat >"$AAP_CRC_MACHINE_CONFIG" <<'EOF'
{"Driver":{"VfkitPath":"/usr/local/crc/vfkit"}}
EOF

cat >"${TEST_DIR}/real-vfkit" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${MOCK_VFKIT_ARGS}"
EOF
chmod +x "${TEST_DIR}/real-vfkit"
export MOCK_VFKIT_ARGS="${TEST_DIR}/vfkit.args"

# Use the test vfkit path as the original binary in the mock machine config.
python3 - "$AAP_CRC_MACHINE_CONFIG" "${TEST_DIR}/real-vfkit" <<'PY'
import json
import sys

path, vfkit = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    config = json.load(stream)
config["Driver"]["VfkitPath"] = vfkit
with open(path, "w", encoding="utf-8") as stream:
    json.dump(config, stream)
PY

# The helper is expected to source infrastructure calls only when it needs to
# mount the guest filesystem; this test covers host-side preparation.
source "${REPO_ROOT}/includes/persistent-crio-store.sh"

persistent_crio_store_create_disk
[ -f "$AAP_IMAGE_STORE_DISK" ]
[ "$(stat -f '%z' "$AAP_IMAGE_STORE_DISK")" -eq 1073741824 ]
echo "✓ macOS creates a sparse raw persistent disk"

persistent_crio_store_prepare_before_crc_start
wrapper_path="${MOCK_HOME}/.aap-demo/bin/vfkit-persistent-storage"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Driver"]["VfkitPath"])' "$AAP_CRC_MACHINE_CONFIG")" = "$wrapper_path" ]
echo "✓ macOS configures CRC to launch through the vfkit wrapper"

"$wrapper_path" --memory 4096
grep -F -- "--device virtio-blk,path=${AAP_IMAGE_STORE_DISK}" "$MOCK_VFKIT_ARGS"
echo "✓ vfkit receives the raw persistent disk at launch"

persistent_crio_store_restore_vfkit
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Driver"]["VfkitPath"])' "$AAP_CRC_MACHINE_CONFIG")" = "${TEST_DIR}/real-vfkit" ]
echo "✓ macOS vfkit configuration can be restored"

cat >"${TEST_DIR}/crc.log" <<'EOF'
EOF
crc() {
  printf '%s\n' "$*" >>"${TEST_DIR}/crc.log"
}
infra_exec_cmd() {
  cat >/dev/null
}

persistent_crio_store_prepare_or_fallback
grep -qx 'stop' "${TEST_DIR}/crc.log"
grep -qx 'start' "${TEST_DIR}/crc.log"
echo "✓ macOS preparation relaunches CRC before mounting the persistent store"
persistent_crio_store_restore_vfkit

create_start_line=$(grep -n '^if ! crc start' "${REPO_ROOT}/includes/crc-create.sh" | head -1 | cut -d: -f1 || true)
prepare_start_line=$(grep -n 'persistent_crio_store_prepare_before_crc_start' "${REPO_ROOT}/includes/crc-create.sh" | head -1 | cut -d: -f1 || true)
prepare_after_line=$(grep -n 'persistent_crio_store_prepare_or_fallback' "${REPO_ROOT}/includes/crc-create.sh" | head -1 | cut -d: -f1 || true)
if [ -n "$prepare_start_line" ] && [ -n "$create_start_line" ] \
  && [ "$prepare_start_line" -lt "$create_start_line" ] \
  && [ -n "$prepare_after_line" ] && [ "$prepare_after_line" -gt "$create_start_line" ]; then
  echo "✓ CRC create prepares the macOS disk before start and mounts it afterward"
else
  echo "✗ CRC create must prepare the macOS disk before start and mount it afterward" >&2
  exit 1
fi
