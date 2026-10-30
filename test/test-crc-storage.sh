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
cat >"${TEST_DIR}/bin/crc" <<'MOCK_CRC'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${AAP_DEMO_TEST_CRC_LOG:?}"
case "$1" in
  config) exit 0 ;;
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

mkdir -p "${TEST_DIR}/home/.crc/machines/crc"
existing_output="$(cli storage)"
printf '%s\n' "$existing_output" | grep -q 'aap-demo destroy && aap-demo create' || fail "existing cluster should explain that the disk changes on recreate: ${existing_output}"
pass "existing cluster keeps its disk until recreate"

help_output="$(cli help)"
printf '%s\n' "$help_output" | grep -q 'storage \[DISK_GB\] \[PV_GB\]' || fail "help should document aap-demo storage"
pass "help documents aap-demo storage"

echo "CRC storage command tests passed"
