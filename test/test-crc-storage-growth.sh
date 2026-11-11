#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="${TEST_DIR}/home"
AAP_DEMO_DIR="$HOME/.aap-demo"
AAP_DEMO_CONFIG="${AAP_DEMO_DIR}/config"
METADATA="$HOME/.crc/machines/crc/config.json"
LOG="${TEST_DIR}/commands"
SCENARIO=ready
TOTAL=100000000
USED=90000000
GIB=1073741824
mkdir -p "$(dirname "$METADATA")" "$AAP_DEMO_DIR"

source "$REPO_ROOT/includes/crc-storage.sh"

_err() { echo "ERROR: $*" >&2; }
reset_fixture() {
  SCENARIO=ready
  TOTAL=100000000
  USED=90000000
  printf '{"Driver":{"DiskCapacity":%s}}\n' "$((220 * GIB))" >"$METADATA"
  printf 'ADDONS=ao,mcp-server\nCRC_DISK=220\nCRC_MEMORY=24576\n' >"$AAP_DEMO_CONFIG"
  rm -f "$AAP_DEMO_DIR/storage-growth.pending" "${TEST_DIR}/grown"
  : >"$LOG"
}
infra_exec_cmd() {
  echo "guest $*" >>"$LOG"
  test "$SCENARIO" != ssh-failure || return 1
  if [ "$SCENARIO" = invalid-df ]; then
    echo invalid
    return 0
  fi
  local size="$TOTAL"
  [ ! -f "${TEST_DIR}/grown" ] || size=$((TOTAL + 44 * 1048576))
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf '/dev/root %s %s %s 90%% /var\n' "$size" "$USED" "$((size - USED))"
}
df() {
  local free=1000000000
  [ "$SCENARIO" != host-full ] || free=1
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf '/dev/host 2000000000 1000 %s 1%% /home\n' "$free"
}
crc() {
  echo "crc $*" >>"$LOG"
  case "$1" in
    config) test "$SCENARIO" != config-failure ;;
    stop) test "$SCENARIO" != stop-failure ;;
    *) return 1 ;;
  esac
}
_start_crc_cluster() {
  echo "start ${CRC_DISK}" >>"$LOG"
  if [ "$SCENARIO" != no-disk-growth ]; then
    printf '{"Driver":{"DiskCapacity":%s}}\n' "$((CRC_DISK * GIB))" >"$METADATA"
  fi
  test "$SCENARIO" != start-failure || return 1
  if [ "$SCENARIO" != no-filesystem-growth ]; then
    touch "${TEST_DIR}/grown"
  fi
}
setup_kubeconfig() { echo kubeconfig >>"$LOG"; }

reset_fixture
USED=89999999
aap_demo_start_storage >"$TEST_DIR/output" 2>&1
if grep -q '^crc ' "$LOG"; then
  echo "FAIL: usage below 90% triggered a resize" >&2
  exit 1
fi
echo "PASS: 89.999999% usage leaves the disk and configuration unchanged"

reset_fixture
aap_demo_start_storage >"$TEST_DIR/output" 2>&1
grep -q 'crc config set disk-size 264' "$LOG"
grep -q '^crc stop$' "$LOG"
grep -q '^start 264$' "$LOG"
grep -q '^CRC_DISK=264$' "$AAP_DEMO_CONFIG"
grep -q '^CRC_MEMORY=24576$' "$AAP_DEMO_CONFIG"
grep -q '^ADDONS=ao,mcp-server$' "$AAP_DEMO_CONFIG"
test ! -e "$AAP_DEMO_DIR/storage-growth.pending"
echo "PASS: exactly 90% grows the actual 220 GiB disk to 264 GiB and preserves other settings"

: >"$LOG"
aap_demo_start_storage >"$TEST_DIR/output" 2>&1
if grep -q '^crc ' "$LOG"; then
  echo "FAIL: a second start repeated the completed resize" >&2
  exit 1
fi
echo "PASS: completed growth is idempotent"

reset_fixture
printf '{"Driver":{"DiskCapacity":%s}}\n' "$((221 * GIB))" >"$METADATA"
aap_demo_start_storage >"$TEST_DIR/output" 2>&1
grep -q 'crc config set disk-size 266' "$LOG"
echo "PASS: 20% growth is rounded upward to whole GiB using actual capacity, not a stale preference"

for scenario in ssh-failure invalid-df host-full config-failure stop-failure \
  start-failure no-filesystem-growth no-disk-growth; do
  reset_fixture
  if SCENARIO="$scenario" aap_demo_start_storage >"$TEST_DIR/output" 2>&1; then
    echo "FAIL: $scenario reported successful storage recovery" >&2
    exit 1
  fi
  if [ "$scenario" = stop-failure ] && grep -q '^start ' "$LOG"; then
    echo "FAIL: failed graceful shutdown was ignored" >&2
    exit 1
  fi
done
echo "PASS: capacity, host space, configuration, shutdown, startup and filesystem failures propagate"

reset_fixture
if SCENARIO=start-failure aap_demo_start_storage >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: partial start failure was ignored" >&2
  exit 1
fi
test -f "$AAP_DEMO_DIR/storage-growth.pending"
: >"$LOG"
aap_demo_start_storage >"$TEST_DIR/output" 2>&1
grep -q 'crc config set disk-size 264' "$LOG"
test ! -e "$AAP_DEMO_DIR/storage-growth.pending"
echo "PASS: interrupted growth retries the same target instead of growing another 20%"

reset_fixture
printf 'garbage\n' >"$AAP_DEMO_DIR/storage-growth.pending"
if aap_demo_start_storage >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: corrupt resize state was accepted" >&2
  exit 1
fi
grep -q 'Invalid pending CRC storage resize' "$TEST_DIR/output"
echo "PASS: corrupt pending resize state is rejected explicitly"
