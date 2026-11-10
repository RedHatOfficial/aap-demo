#!/usr/bin/env bash
# Storage prompt and `aap-demo storage` command.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-crc-storage.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

# shellcheck source=../includes/crc-storage.sh
source "${REPO_ROOT}/includes/crc-storage.sh"

if aap_demo_validate_crc_storage 120 70; then
  pass "120GB disk and 70GB PV pool is valid"
else
  fail "120GB disk and 70GB PV pool should be valid"
fi

if aap_demo_validate_crc_storage 70 70 2>/dev/null; then
  fail "PV size equal to disk size should be rejected"
else
  pass "PV size equal to disk size is rejected"
fi

if aap_demo_validate_crc_storage 0 1 2>/dev/null; then
  fail "zero disk size should be rejected"
else
  pass "zero disk size is rejected"
fi

if aap_demo_validate_crc_storage abc 10 2>/dev/null; then
  fail "non-numeric disk size should be rejected"
else
  pass "non-numeric disk size is rejected"
fi

if aap_demo_validate_crc_storage 31 15; then
  pass "31GB disk and 15GB PV pool is the OpenShift Local minimum"
else
  fail "31GB disk and 15GB PV pool should be valid"
fi

if aap_demo_validate_crc_storage 30 20 >"${TEST_DIR}/validate-30.out" 2>"${TEST_DIR}/validate-30.err"; then
  fail "30GB disk should be rejected"
fi
grep -q 'at least 31GB' "${TEST_DIR}/validate-30.err" || fail "30GB disk should name the OpenShift Local minimum: $(cat "${TEST_DIR}/validate-30.err")"
pass "30GB disk is rejected before it can be saved"

if aap_demo_validate_crc_storage 31 14 >"${TEST_DIR}/validate-14.out" 2>"${TEST_DIR}/validate-14.err"; then
  fail "14GB PV pool should be rejected"
fi
grep -q 'at least 15GB' "${TEST_DIR}/validate-14.err" || fail "14GB PV pool should name the OpenShift Local minimum: $(cat "${TEST_DIR}/validate-14.err")"
pass "14GB persistent-volume pool is rejected"

resolve_home="${TEST_DIR}/resolve-home"
mkdir -p "${resolve_home}/.aap-demo"
printf '%s\n' 'CRC_DISK=150' 'CRC_PV_SIZE=80' >"${resolve_home}/.aap-demo/config"
(
  unset CRC_DISK CRC_PV_SIZE VM_DISK_SIZE VM_PV_SIZE
  export HOME="$resolve_home"
  unset AAP_DEMO_CONFIG
  aap_demo_resolve_crc_storage
  [ "$CRC_DISK" = 150 ] && [ "$CRC_PV_SIZE" = 80 ]
) || fail "saved config should become the storage default"
pass "saved config becomes the storage default"

(
  unset VM_DISK_SIZE VM_PV_SIZE
  export HOME="$resolve_home"
  export CRC_DISK=180 CRC_PV_SIZE=100
  aap_demo_resolve_crc_storage
  [ "$CRC_DISK" = 180 ] && [ "$CRC_PV_SIZE" = 100 ]
) || fail "environment storage values should override saved config"
pass "environment storage values override saved config"

note="$(aap_demo_note_crc_storage_limits 100)"
printf '%s\n' "$note" | grep -q 'below the 120GB disk' || fail "smaller disks should warn about install space: ${note}"
if [ -n "$(aap_demo_note_crc_storage_limits 120)" ]; then
  fail "the 120GB default should not warn"
fi
pass "disks below 120GB warn about install space"

if ! grep -q 'aap_demo_prompt_crc_storage' "${REPO_ROOT}/includes/crc-create.sh"; then
  fail "create must prompt for CRC storage"
fi
if ! grep -q 'aap_demo_resolve_crc_storage' "${REPO_ROOT}/includes/crc-create.sh"; then
  fail "create must resolve saved CRC storage"
fi
pass "create resolves and prompts for CRC storage"

run_prompt() {
  local mode="$1"
  PROMPT_MODE="$mode" REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import os
import pty
import select
import sys
import time

repo = os.environ["REPO_ROOT"]
mode = os.environ["PROMPT_MODE"]
answers = {
    "set": [b"150\n", b"90\n"],
    "default": [b"\n", b"\n"],
    "invalid": [b"nope\n", b"10\n"],
}[mode]
script = f"""
set -euo pipefail
source "{repo}/includes/crc-storage.sh"
CRC_DISK=120
CRC_PV_SIZE=70
aap_demo_prompt_crc_storage
printf 'RESULT %s %s\\n' "$CRC_DISK" "$CRC_PV_SIZE"
"""
pid, master = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", script])

captured = bytearray()
buf = b""
step = 0
deadline = time.time() + 15
status = None
while True:
    if time.time() > deadline:
        os.kill(pid, 9)
        sys.stderr.write("timed out waiting for the storage prompt\n")
        status = 1 << 8
        break
    readable, _, _ = select.select([master], [], [], 0.2)
    if master not in readable:
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited:
            break
        continue
    try:
        data = os.read(master, 1024)
    except OSError:
        _, status = os.waitpid(pid, 0)
        break
    if not data:
        _, status = os.waitpid(pid, 0)
        break
    captured.extend(data)
    buf += data
    if step < len(answers):
        needle = b"Disk in GB" if step == 0 else b"Persistent volume storage in GB"
        if needle in buf:
            os.write(master, answers[step])
            step += 1
            buf = b""

if status is None:
    _, status = os.waitpid(pid, 0)
os.close(master)
sys.stdout.buffer.write(captured)
exit_code = os.waitstatus_to_exitcode(status)
if exit_code != 0:
    sys.exit(exit_code)
PY
}

run_prompt set >"${TEST_DIR}/prompt-set.out" 2>"${TEST_DIR}/prompt-set.err" || fail "prompt failed: $(cat "${TEST_DIR}/prompt-set.out" "${TEST_DIR}/prompt-set.err")"
grep -q 'RESULT 150 90' "${TEST_DIR}/prompt-set.out" || fail "prompt should accept 150GB disk and 90GB PV pool: $(cat "${TEST_DIR}/prompt-set.out")"
pass "prompt accepts disk and persistent-volume answers"

run_prompt default >"${TEST_DIR}/prompt-default.out" 2>"${TEST_DIR}/prompt-default.err" || fail "default prompt failed: $(cat "${TEST_DIR}/prompt-default.out" "${TEST_DIR}/prompt-default.err")"
grep -q 'RESULT 120 70' "${TEST_DIR}/prompt-default.out" || fail "Enter should keep 120GB disk and 70GB PV pool: $(cat "${TEST_DIR}/prompt-default.out")"
pass "Enter keeps the current disk and persistent-volume size"

if run_prompt invalid >"${TEST_DIR}/prompt-invalid.out" 2>"${TEST_DIR}/prompt-invalid.err"; then
  fail "non-numeric disk answer should fail: $(cat "${TEST_DIR}/prompt-invalid.out" "${TEST_DIR}/prompt-invalid.err")"
fi
cat "${TEST_DIR}/prompt-invalid.out" "${TEST_DIR}/prompt-invalid.err" | grep -q "Invalid disk size: 'nope'" || fail "invalid disk answer should explain the failure: $(cat "${TEST_DIR}/prompt-invalid.out" "${TEST_DIR}/prompt-invalid.err")"
pass "prompt rejects a non-numeric disk size"

mkdir -p "${TEST_DIR}/bin" "${TEST_DIR}/home/.aap-demo"
CRC_DISK_STATE="${TEST_DIR}/crc-disk-state"
: >"$CRC_DISK_STATE"
cat >"${TEST_DIR}/bin/crc" <<'MOCK_CRC'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${AAP_DEMO_TEST_CRC_LOG:?}"
state="${AAP_DEMO_TEST_CRC_DISK_STATE:?}"
value=""
case "$1 $2 $3" in
  "config get disk-size")
    if [ -s "$state" ]; then
      value="$(tr -d '[:space:]' <"$state")"
    fi
    if [ -n "$value" ]; then
      printf 'disk-size : %s\n' "$value"
    else
      printf "Configuration property 'disk-size' is not set. Default value '31' is used\n"
    fi
    exit 0
    ;;
  "config unset disk-size")
    : >"$state"
    exit 0
    ;;
  "config set disk-size")
    if [ "${4:-}" = "32" ]; then
      printf 'disk-size value 32 is invalid, must be greater than or equal to 31\n' >&2
      exit 1
    fi
    printf '%s\n' "$4" >"$state"
    exit 0
    ;;
esac
case "$*" in
  "config set persistent-volume-size 16")
    printf 'persistent-volume-size value 16 is invalid, must be greater than or equal to 15\n' >&2
    exit 1
    ;;
  "config set "*)
    exit 0
    ;;
  daemon)
    exit 0
    ;;
  "status --output json")
    printf '%s\n' '{"crcStatus":"Stopped","openshiftStatus":"Stopped"}'
    ;;
  *)
    printf 'unexpected crc args: %s\n' "$*" >&2
    exit 2
    ;;
esac
MOCK_CRC
chmod +x "${TEST_DIR}/bin/crc"

cli() {
  env -u CRC_DISK -u CRC_PV_SIZE -u VM_DISK_SIZE -u VM_PV_SIZE \
    HOME="${TEST_DIR}/home" \
    AAP_DEMO_CONFIG="${TEST_DIR}/home/.aap-demo/config" \
    AAP_DEMO_TEST_CRC_LOG="${TEST_DIR}/crc.log" \
    AAP_DEMO_TEST_CRC_DISK_STATE="$CRC_DISK_STATE" \
    PATH="${TEST_DIR}/bin:${PATH}" \
    QUIET=true \
    "${REPO_ROOT}/aap-demo.sh" "$@"
}

: >"${TEST_DIR}/crc.log"
cli storage 160 90 >/tmp/aap-demo-storage-set.out
grep -q '^CRC_DISK=160$' "${TEST_DIR}/home/.aap-demo/config" || fail "storage command did not save CRC_DISK"
grep -q '^CRC_PV_SIZE=90$' "${TEST_DIR}/home/.aap-demo/config" || fail "storage command did not save CRC_PV_SIZE"
grep -qx 'config set disk-size 160' "${TEST_DIR}/crc.log" || fail "storage command did not set crc disk-size"
grep -qx 'config set persistent-volume-size 90' "${TEST_DIR}/crc.log" || fail "storage command did not set crc persistent-volume-size"
pass "aap-demo storage saves disk and persistent-volume size"

show_output="$(cli storage)"
printf '%s\n' "$show_output" | grep -q 'Disk: 160 GB' || fail "storage show should print the saved disk: ${show_output}"
printf '%s\n' "$show_output" | grep -q 'Persistent volume storage: 90 GB' || fail "storage show should print the saved PV pool: ${show_output}"
pass "aap-demo storage shows the saved size"

cli storage 200 >/tmp/aap-demo-storage-disk-only.out
grep -q '^CRC_DISK=200$' "${TEST_DIR}/home/.aap-demo/config" || fail "disk-only storage command should update the disk"
grep -q '^CRC_PV_SIZE=90$' "${TEST_DIR}/home/.aap-demo/config" || fail "disk-only storage command should keep the PV pool"
pass "aap-demo storage DISK_GB keeps the current PV pool"

if cli storage 80 >/tmp/aap-demo-storage-too-small.out 2>&1; then
  fail "disk smaller than the current PV pool should be rejected"
fi
grep -q '^CRC_DISK=200$' "${TEST_DIR}/home/.aap-demo/config" || fail "rejected storage change should leave the saved disk unchanged"
pass "aap-demo storage rejects a disk that cannot hold the PV pool"

if cli storage 90 90 >/tmp/aap-demo-storage-equal.out 2>&1; then
  fail "equal disk and PV sizes should be rejected"
fi
pass "aap-demo storage rejects a PV pool as large as the disk"

if cli storage 30 20 >/tmp/aap-demo-storage-below-crc-minimum.out 2>&1; then
  fail "storage below the OpenShift Local minimum should be rejected"
fi
grep -q 'at least 31GB' /tmp/aap-demo-storage-below-crc-minimum.out || fail "storage 30 20 should name the disk minimum: $(cat /tmp/aap-demo-storage-below-crc-minimum.out)"
grep -q '^CRC_DISK=200$' "${TEST_DIR}/home/.aap-demo/config" || fail "rejected 30GB disk should leave the saved disk unchanged"
grep -q '^CRC_PV_SIZE=90$' "${TEST_DIR}/home/.aap-demo/config" || fail "rejected 30GB disk should leave the saved PV pool unchanged"
if grep -qx 'config set disk-size 30' "${TEST_DIR}/crc.log"; then
  fail "storage 30 20 should fail before crc config set"
fi
pass "aap-demo storage 30 20 does not save a disk OpenShift Local rejects"

if cli storage 32 16 >/tmp/aap-demo-storage-crc-reject.out 2>&1; then
  fail "crc must be able to reject a disk that passes local checks"
fi
grep -q 'saved size was not changed' /tmp/aap-demo-storage-crc-reject.out || fail "crc rejection should say the saved size was not changed: $(cat /tmp/aap-demo-storage-crc-reject.out)"
grep -q '^CRC_DISK=200$' "${TEST_DIR}/home/.aap-demo/config" || fail "a crc disk rejection should leave the saved disk unchanged"
grep -q '^CRC_PV_SIZE=90$' "${TEST_DIR}/home/.aap-demo/config" || fail "a crc disk rejection should leave the saved PV pool unchanged"
grep -qx 'config set disk-size 32' "${TEST_DIR}/crc.log" || fail "crc should see the rejected disk size"
if grep -qx 'config set persistent-volume-size 16' "${TEST_DIR}/crc.log"; then
  fail "persistent-volume size should not be sent after disk-size is rejected"
fi
pass "aap-demo storage keeps the saved size when crc rejects the disk"

if cli storage 40 16 >/tmp/aap-demo-storage-crc-reject-pv.out 2>&1; then
  fail "crc must be able to reject a persistent-volume size that passes local checks"
fi
grep -q 'saved size was not changed' /tmp/aap-demo-storage-crc-reject-pv.out || fail "pv rejection should say the saved size was not changed: $(cat /tmp/aap-demo-storage-crc-reject-pv.out)"
grep -q '^CRC_DISK=200$' "${TEST_DIR}/home/.aap-demo/config" || fail "a crc PV rejection should leave the saved disk unchanged"
grep -q '^CRC_PV_SIZE=90$' "${TEST_DIR}/home/.aap-demo/config" || fail "a crc PV rejection should leave the saved PV pool unchanged"
grep -qx 'config set disk-size 40' "${TEST_DIR}/crc.log" || fail "crc should receive the requested disk before the PV rejection"
grep -qx 'config set persistent-volume-size 16' "${TEST_DIR}/crc.log" || fail "crc should receive the rejected PV size"
grep -qx 'config set disk-size 200' "${TEST_DIR}/crc.log" || fail "a rejected PV size should restore the previous crc disk size"
[ "$(tr -d '[:space:]' <"$CRC_DISK_STATE")" = "200" ] || fail "a rejected PV size should leave crc disk-size at the previous value"
pass "aap-demo storage restores the previous disk when crc rejects the PV pool"

rollback_storage() {
  local label="$1"
  local seeded_disk="${2:-}"
  local seeded_config="${3:-}"
  local home="${TEST_DIR}/rollback-${label}"
  local state="${TEST_DIR}/rollback-${label}.disk"
  local log="${TEST_DIR}/rollback-${label}.log"
  mkdir -p "$home"
  if [ -n "$seeded_config" ]; then
    mkdir -p "${home}/.aap-demo"
    printf '%s\n' "$seeded_config" >"${home}/.aap-demo/config"
  fi
  if [ -n "$seeded_disk" ]; then
    printf '%s\n' "$seeded_disk" >"$state"
  else
    : >"$state"
  fi
  : >"$log"
  set +e
  env -u CRC_DISK -u CRC_PV_SIZE -u VM_DISK_SIZE -u VM_PV_SIZE \
    HOME="$home" \
    AAP_DEMO_CONFIG="${home}/.aap-demo/config" \
    AAP_DEMO_TEST_CRC_LOG="$log" \
    AAP_DEMO_TEST_CRC_DISK_STATE="$state" \
    PATH="${TEST_DIR}/bin:${PATH}" \
    QUIET=true \
    "${REPO_ROOT}/aap-demo.sh" storage 40 16 \
    >"${TEST_DIR}/rollback-${label}.out" 2>"${TEST_DIR}/rollback-${label}.err"
  local status=$?
  set -e
  return "$status"
}

if rollback_storage fresh-unset; then
  fail "a fresh config should still fail when crc rejects the PV size: $(cat "${TEST_DIR}/rollback-fresh-unset.out" "${TEST_DIR}/rollback-fresh-unset.err")"
fi
grep -q 'saved size was not changed' "${TEST_DIR}/rollback-fresh-unset.err" || fail "fresh config PV rejection should say the saved size was not changed: $(cat "${TEST_DIR}/rollback-fresh-unset.err")"
grep -qx 'config unset disk-size' "${TEST_DIR}/rollback-fresh-unset.log" || fail "an unset CRC disk should be unset again after a PV rejection: $(cat "${TEST_DIR}/rollback-fresh-unset.log")"
if [ -s "${TEST_DIR}/rollback-fresh-unset.disk" ]; then
  fail "an unset CRC disk was left configured: $(cat "${TEST_DIR}/rollback-fresh-unset.disk")"
fi
if [ -f "${TEST_DIR}/rollback-fresh-unset/.aap-demo/config" ] && grep -q '^CRC_DISK=' "${TEST_DIR}/rollback-fresh-unset/.aap-demo/config"; then
  fail "a fresh config should not save the rejected size: $(cat "${TEST_DIR}/rollback-fresh-unset/.aap-demo/config")"
fi
pass "aap-demo storage unsets a new disk when crc rejects the PV pool on a fresh config"

if rollback_storage fresh-crc 120; then
  fail "a fresh aap-demo config should still fail when crc rejects the PV size: $(cat "${TEST_DIR}/rollback-fresh-crc.out" "${TEST_DIR}/rollback-fresh-crc.err")"
fi
grep -q 'saved size was not changed' "${TEST_DIR}/rollback-fresh-crc.err" || fail "CRC-backed disk should be described as unchanged: $(cat "${TEST_DIR}/rollback-fresh-crc.err")"
grep -qx 'config set disk-size 120' "${TEST_DIR}/rollback-fresh-crc.log" || fail "the CRC disk setting should be restored when aap-demo has no saved disk: $(cat "${TEST_DIR}/rollback-fresh-crc.log")"
[ "$(tr -d '[:space:]' <"${TEST_DIR}/rollback-fresh-crc.disk")" = "120" ] || fail "CRC disk-size should be back to 120: $(cat "${TEST_DIR}/rollback-fresh-crc.disk")"
if [ -f "${TEST_DIR}/rollback-fresh-crc/.aap-demo/config" ] && grep -q '^CRC_DISK=' "${TEST_DIR}/rollback-fresh-crc/.aap-demo/config"; then
  fail "a fresh config should not save the rejected size: $(cat "${TEST_DIR}/rollback-fresh-crc/.aap-demo/config")"
fi
pass "aap-demo storage restores the CRC disk when aap-demo has no saved size"

if rollback_storage crc-not-config 120 $'CRC_DISK=200\nCRC_PV_SIZE=90'; then
  fail "crc PV rejection should fail even when the saved size differs: $(cat "${TEST_DIR}/rollback-crc-not-config.out" "${TEST_DIR}/rollback-crc-not-config.err")"
fi
grep -qx 'config set disk-size 120' "${TEST_DIR}/rollback-crc-not-config.log" || fail "rollback should use the CRC disk, not the aap-demo config: $(cat "${TEST_DIR}/rollback-crc-not-config.log")"
if grep -qx 'config set disk-size 200' "${TEST_DIR}/rollback-crc-not-config.log"; then
  fail "rollback restored the aap-demo config disk instead of the CRC disk"
fi
grep -q '^CRC_DISK=200$' "${TEST_DIR}/rollback-crc-not-config/.aap-demo/config" || fail "the saved disk should stay unchanged"
if grep -q '^CRC_DISK=40$' "${TEST_DIR}/rollback-crc-not-config/.aap-demo/config"; then
  fail "the rejected disk was saved"
fi
pass "aap-demo storage rolls CRC back to its own disk size"

mkdir -p "${TEST_DIR}/home/.crc/machines/crc"
existing_output="$(cli storage)"
printf '%s\n' "$existing_output" | grep -q 'aap-demo destroy && aap-demo create' || fail "existing cluster should explain that the disk changes on recreate: ${existing_output}"
pass "existing cluster keeps its disk until recreate"

help_output="$(cli help)"
printf '%s\n' "$help_output" | grep -q 'storage \[DISK_GB\] \[PV_GB\]' || fail "help should document aap-demo storage"
printf '%s\n' "$help_output" | grep -q 'at least 31GB' || fail "help should document the OpenShift Local disk minimum"
pass "help documents aap-demo storage"

run_rejected_create() {
  local label="$1"
  local disk="${2:-}"
  local pv="${3:-}"
  local seeded_config="$4"
  local home="${TEST_DIR}/create-${label}"
  mkdir -p "${home}/.aap-demo" "${home}/.crc"
  printf '%s\n' "$seeded_config" >"${home}/.aap-demo/config"
  : >"${TEST_DIR}/crc.log"
  set +e
  if [ -n "$disk" ]; then
    env -u VM_DISK_SIZE -u VM_PV_SIZE \
      HOME="$home" \
      AAP_DEMO_CONFIG="${home}/.aap-demo/config" \
      AAP_DEMO_TEST_CRC_LOG="${TEST_DIR}/crc.log" \
      AAP_DEMO_TEST_CRC_DISK_STATE="$CRC_DISK_STATE" \
      PATH="${TEST_DIR}/bin:${PATH}" \
      QUIET=true \
      CRC_CPUS=8 \
      CRC_MEMORY=16384 \
      CRC_DISK="$disk" \
      CRC_PV_SIZE="$pv" \
      SCRIPT_DIR="$REPO_ROOT" \
      "${REPO_ROOT}/includes/crc-create.sh" \
      >"${TEST_DIR}/create-${label}.out" 2>"${TEST_DIR}/create-${label}.err"
  else
    env -u CRC_DISK -u CRC_PV_SIZE -u VM_DISK_SIZE -u VM_PV_SIZE \
      HOME="$home" \
      AAP_DEMO_CONFIG="${home}/.aap-demo/config" \
      AAP_DEMO_TEST_CRC_LOG="${TEST_DIR}/crc.log" \
      AAP_DEMO_TEST_CRC_DISK_STATE="$CRC_DISK_STATE" \
      PATH="${TEST_DIR}/bin:${PATH}" \
      QUIET=true \
      CRC_CPUS=8 \
      CRC_MEMORY=16384 \
      SCRIPT_DIR="$REPO_ROOT" \
      "${REPO_ROOT}/includes/crc-create.sh" \
      >"${TEST_DIR}/create-${label}.out" 2>"${TEST_DIR}/create-${label}.err"
  fi
  local status=$?
  set -e
  return "$status"
}

if run_rejected_create below-min 30 20 $'CRC_DISK=120\nCRC_PV_SIZE=70'; then
  fail "create should stop when CRC_DISK is below the OpenShift Local minimum: $(cat "${TEST_DIR}/create-below-min.out" "${TEST_DIR}/create-below-min.err")"
fi
grep -q 'at least 31GB' "${TEST_DIR}/create-below-min.err" || fail "create should name the disk minimum: $(cat "${TEST_DIR}/create-below-min.err")"
grep -q '^CRC_DISK=120$' "${TEST_DIR}/create-below-min/.aap-demo/config" || fail "create should not replace a saved disk with a rejected size"
if grep -q '^CRC_DISK=30$' "${TEST_DIR}/create-below-min/.aap-demo/config"; then
  fail "create saved CRC_DISK=30 after OpenShift Local would reject it"
fi
if grep -q 'Resources:' "${TEST_DIR}/create-below-min.out"; then
  fail "create should not report resources after rejecting the disk"
fi
if grep -q 'crc start' "${TEST_DIR}/crc.log" || grep -q 'config set disk-size 30' "${TEST_DIR}/crc.log"; then
  fail "create should not start or send a 30GB disk: $(cat "${TEST_DIR}/crc.log")"
fi
pass "create stops before start when CRC_DISK is below 31GB"

if run_rejected_create crc-reject 32 16 $'CRC_DISK=120\nCRC_PV_SIZE=70'; then
  fail "create should stop when crc rejects the disk: $(cat "${TEST_DIR}/create-crc-reject.out" "${TEST_DIR}/create-crc-reject.err")"
fi
grep -q 'saved size was not changed' "${TEST_DIR}/create-crc-reject.err" || fail "create should report the crc rejection: $(cat "${TEST_DIR}/create-crc-reject.err")"
grep -q '^CRC_DISK=120$' "${TEST_DIR}/create-crc-reject/.aap-demo/config" || fail "create should keep the saved disk when crc rejects the new size"
if grep -q '^CRC_DISK=32$' "${TEST_DIR}/create-crc-reject/.aap-demo/config"; then
  fail "create saved CRC_DISK=32 after crc rejected it"
fi
if grep -q 'Resources:' "${TEST_DIR}/create-crc-reject.out"; then
  fail "create should not report resources after crc rejects the disk"
fi
grep -qx 'config set disk-size 32' "${TEST_DIR}/crc.log" || fail "create should send the rejected disk size to crc"
if grep -q 'crc start' "${TEST_DIR}/crc.log"; then
  fail "create should not start after crc rejects the disk"
fi
pass "create stops before start when crc rejects the disk"

if run_rejected_create saved-below '' '' $'CRC_DISK=30\nCRC_PV_SIZE=20'; then
  fail "create should stop when the saved size is below the OpenShift Local minimum: $(cat "${TEST_DIR}/create-saved-below.out" "${TEST_DIR}/create-saved-below.err")"
fi
grep -q 'at least 31GB' "${TEST_DIR}/create-saved-below.err" || fail "saved 30GB disk should fail validation: $(cat "${TEST_DIR}/create-saved-below.err")"
grep -q '^CRC_DISK=30$' "${TEST_DIR}/create-saved-below/.aap-demo/config" || fail "create should leave the previously saved disk in place"
if grep -q 'Resources:' "${TEST_DIR}/create-saved-below.out" || grep -q 'config set disk-size 30' "${TEST_DIR}/crc.log" || grep -q 'crc start' "${TEST_DIR}/crc.log"; then
  fail "create should not apply or start a saved disk OpenShift Local rejects: $(cat "${TEST_DIR}/crc.log")"
fi
pass "create does not start from a saved disk OpenShift Local rejects"

echo "CRC storage command tests passed"
