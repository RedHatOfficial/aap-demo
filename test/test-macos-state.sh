#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
export HOME="$TEST_DIR/home with spaces"
export AAP_DEMO_DIR="$HOME/.aap-demo" AAP_DEMO_CONFIG="$HOME/.aap-demo/config"
export AAP_DEMO_VAULT_FILE="$HOME/.ansible/conf/env.yml"
export AAP_DEMO_VAULT_PASSWORD_FILE="$HOME/.ansible/conf/.vaultpass.txt"
export AAP_DEMO_LOCK_DIR="$HOME/.aap-demo/operation.lock"
unset AAP_DEMO_LOCK_TOKEN AAP_DEMO_SERVICE_INTERNAL AAP_DEMO_DISABLE_LOCK
mkdir -p "$HOME/.crc/machines/crc" "$HOME/.aap-demo" "$HOME/.ansible/conf"
source "$REPO_ROOT/scripts/aap-demo-macos-state.sh"
mac_state_init
mkdir -p "$MAC_STATE_ROOT/states"
printf '1\n' >"$MAC_STATE_ROOT/retention"
printf 'Stopped\n' >"$TEST_DIR/status"
printf 'cold-disk\n' >"$HOME/.crc/machines/crc/crc.img"
printf 'ADDONS=mcp-server\n' >"$HOME/.aap-demo/config"
printf 'vault-data\n' >"$HOME/.ansible/conf/env.yml"
printf 'vault-password\n' >"$HOME/.ansible/conf/.vaultpass.txt"
jq -n --arg store "$HOME/.crc/machines" \
  '{DriverName:"vfkit",Driver:{ImageFormat:"raw",StorePath:$store}}' \
  >"$HOME/.crc/machines/crc/config.json"
crc() { jq -n --arg status "$(cat "$TEST_DIR/status")" '{crcStatus:$status}'; }
launchctl() { printf '%s\n' "$*" >>"$TEST_DIR/launchctl"; }
sysctl() { echo boot-one; }
mac_state_cli() {
  echo "$*" >>"$TEST_DIR/cli"
  case "$1" in
    stop) echo Stopped >"$TEST_DIR/status" ;;
    start) echo Running >"$TEST_DIR/status" ;;
    *) return 1 ;;
  esac
}

(
  attempts=0
  launchctl() { attempts=$((attempts + 1)); [ "$attempts" -ge 2 ]; }
  sleep() { SECONDS=$((SECONDS + 2)); }
  mac_state_wait_daemon
  test "$attempts" -eq 2
)
if (
  launchctl() { return 1; }
  sleep() { SECONDS=$((SECONDS + 120)); }
  mac_state_wait_daemon
) >/dev/null 2>&1; then
  echo "FAIL: missing CRC login daemon did not time out" >&2; exit 1
fi
echo "PASS: login waits for the CRC daemon and fails within a bounded timeout"

mac_state_layout
mac_state_save
latest=$(mac_state_latest)
mac_state_verify "$latest"
test "$(cat "$latest/payload/vault/env.yml")" = vault-data
test "$(cat "$latest/payload/vault/.vaultpass.txt")" = vault-password
echo "PASS: full cold checkpoint and credentials verify with paths containing spaces"

printf 'newer-disk\n' >"$HOME/.crc/machines/crc/crc.img"
printf 'stale\n' >"$HOME/.aap-demo/stale"
mac_state_restore
test "$(cat "$HOME/.crc/machines/crc/crc.img")" = cold-disk
test ! -e "$HOME/.aap-demo/stale"
grep -q 'start com.redhat.crc.daemon' "$TEST_DIR/launchctl"
echo "PASS: restore replaces newer state and refreshes CRC daemon"

for count in 1 2 3; do mac_state_save; done
test "$(find "$MAC_STATE_ROOT/states" -name COMPLETE | wc -l | tr -d ' ')" -eq 1
printf '3\n' >"$MAC_STATE_ROOT/retention"
for count in 1 2 3; do mac_state_save; done
test "$(find "$MAC_STATE_ROOT/states" -name COMPLETE | wc -l | tr -d ' ')" -eq 3
echo "PASS: default one-state retention and explicit three-state retention protect latest"

latest=$(mac_state_latest)
printf 'bad-data\n' >>"$latest/payload/crc/machines/crc/crc.img"
if mac_state_restore >/dev/null 2>&1; then
  echo "FAIL: corrupt checkpoint was accepted" >&2; exit 1
fi
test ! -f "$MAC_STATE_ROOT/restore-pending"
mac_state_save
old_latest=$(cat "$MAC_STATE_ROOT/latest")
if (mac_state_copy() { return 1; }; mac_state_save) >/dev/null 2>&1; then
  echo "FAIL: failed copy published a checkpoint" >&2; exit 1
fi
test "$(cat "$MAC_STATE_ROOT/latest")" = "$old_latest"
echo "PASS: checksum and copy failures preserve the completed recovery point"

echo Running >"$TEST_DIR/status"
if mac_state_save >/dev/null 2>&1; then
  echo "FAIL: running disks were copied" >&2; exit 1
fi
mac_state_checkpoint
test "$(cat "$TEST_DIR/status")" = Stopped
mac_state_start
test "$(cat "$TEST_DIR/status")" = Running
echo "PASS: checkpoint stops cleanly and start restores and resumes"

if (mac_state_save() { return 1; }; mac_state_checkpoint) >/dev/null 2>&1; then
  echo "FAIL: failed checkpoint was accepted" >&2; exit 1
fi
if mac_state_start >/dev/null 2>&1; then
  echo "FAIL: failed checkpoint allowed same-boot rollback" >&2; exit 1
fi
mac_state_checkpoint
if (mac_state_copy() { return 1; }; mac_state_restore) >/dev/null 2>&1; then
  echo "FAIL: failed restore was accepted" >&2; exit 1
fi
test -f "$MAC_STATE_ROOT/restore-pending"
if mac_state_checkpoint >/dev/null 2>&1; then
  echo "FAIL: interrupted restore could overwrite completed checkpoint" >&2; exit 1
fi
mac_state_start
test ! -e "$MAC_STATE_ROOT/restore-pending"
echo "PASS: failed checkpoints and interrupted restores cannot replace newer data silently"

mac_state_plist >"$TEST_DIR/recovery.plist"
if [ "$(uname -s)" = Darwin ]; then
  plutil -lint "$TEST_DIR/recovery.plist"
elif command -v xmllint >/dev/null; then
  xmllint --nonet --noout "$TEST_DIR/recovery.plist"
fi
grep -q '<key>RunAtLoad</key><true/>' "$TEST_DIR/recovery.plist"
grep -q 'login</string>' "$TEST_DIR/recovery.plist"
echo "PASS: login LaunchAgent XML and argument shape"

if (crc() { echo '{"crcStatus":"Unknown"}'; }; mac_state_stopped) >/dev/null 2>&1; then
  echo "FAIL: unknown CRC status allowed disk access" >&2; exit 1
fi
jq '.DriverName = "hyperkit"' "$HOME/.crc/machines/crc/config.json" >"$TEST_DIR/config.json"
mv "$TEST_DIR/config.json" "$HOME/.crc/machines/crc/config.json"
if mac_state_layout >/dev/null 2>&1; then
  echo "FAIL: unsupported hypervisor layout accepted" >&2; exit 1
fi
echo "PASS: unknown VM state and unsupported macOS drivers fail explicitly"

jq '.DriverName = "vfkit"' "$HOME/.crc/machines/crc/config.json" >"$TEST_DIR/config.json"
mv "$TEST_DIR/config.json" "$HOME/.crc/machines/crc/config.json"
uname() {
  if [ "${1:-}" = -s ]; then echo Darwin; else command uname "$@"; fi
}
plutil() { test -s "$2"; }
if mac_state_main install --keep 0 >/dev/null 2>&1; then
  echo "FAIL: zero retention was accepted" >&2; exit 1
fi
trap '_aap_demo_release_operation_lock; rm -rf -- "$TEST_DIR"' EXIT
mac_state_main install --keep 2
test -f "$MAC_STATE_ROOT/enabled"
test -f "$MAC_STATE_PLIST"
test "$(cat "$MAC_STATE_ROOT/retention")" = 2
test "$(cat "$TEST_DIR/status")" = Running
if mac_state_main install >/dev/null 2>&1; then
  echo "FAIL: active installation was replaced" >&2; exit 1
fi
mac_state_main stop
test "$(cat "$TEST_DIR/status")" = Stopped
mac_state_main start
test "$(cat "$TEST_DIR/status")" = Running
mac_state_main retention 3
test "$(cat "$MAC_STATE_ROOT/retention")" = 3
mac_state_main disable
test ! -f "$MAC_STATE_ROOT/enabled"
test ! -f "$MAC_STATE_PLIST"
test -d "$MAC_STATE_ROOT/states"
test "$(cat "$TEST_DIR/status")" = Stopped
echo "PASS: native service install, retention, lifecycle, disable and baseline validation"

source "$REPO_ROOT/includes/state-service.sh"
SCRIPT_DIR="$REPO_ROOT"
touch "$MAC_STATE_ROOT/enabled"
aap_demo_service_managed
if AAP_DEMO_SERVICE_INTERNAL=1 aap_demo_service_managed; then
  echo "FAIL: internal CLI would recurse into recovery" >&2; exit 1
fi
bash() { printf '%s\n' "$*"; }
for action in start restart stop; do
  output=$(aap_demo_service_lifecycle "$action")
  test "$output" = "$REPO_ROOT/scripts/aap-demo-macos-state.sh $action"
done
output=$(cmd_service install --keep 4)
test "$output" = "$REPO_ROOT/scripts/aap-demo-macos-state.sh install --keep 4"
echo "PASS: Bash CLI detects native recovery and routes service/lifecycle arguments without recursion"

if command -v qemu-img >/dev/null 2>&1; then
  mkdir -p "$HOME/.aap-demo/fleet/node-1"
  qemu-img create -q -f qcow2 "$TEST_DIR/fleet-base.qcow2" 1M
  qemu-img create -q -f qcow2 -F qcow2 -b "$TEST_DIR/fleet-base.qcow2" \
    "$HOME/.aap-demo/fleet/node-1/disk.qcow2"
  printf 'INDEX=1\nPID=0\nSTATUS=stopped\n' >"$HOME/.aap-demo/fleet/node-1/meta"
  mac_state_save
  latest=$(mac_state_latest)
  disk="$latest/payload/demo/fleet/node-1/disk.qcow2"
  qemu-img info --output=json "$disk" | jq -e '.["backing-filename"] == null' >/dev/null
  qemu-img compare -q "$HOME/.aap-demo/fleet/node-1/disk.qcow2" "$disk"
  grep -q '^PID=$' "$latest/payload/demo/fleet/node-1/meta"
  echo "PASS: macOS Fleet checkpoint flattens real QCOW2 backing chains and clears stale PIDs"
else
  echo "SKIP: optional real Fleet image test requires qemu-img (covered by Linux CI)"
fi
