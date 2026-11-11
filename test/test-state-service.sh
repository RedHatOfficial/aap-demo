#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export XDG_CONFIG_HOME="$TEST_DIR/desktop-config"
source "$REPO_ROOT/scripts/aap-demo-state.sh"
STATE_USER="$(id -un)"
STATE_UID="$(id -u)"
STATE_HOME="$TEST_DIR/home"
STATE_REPO="$REPO_ROOT"
STATE_ROOT="$TEST_DIR/states"
STATE_KEEP=1
DOMAIN_STATE="shut off"
FAIL_COPY=false
EXTRA_DISK=false
mkdir -p "$STATE_HOME/.crc/machines/crc" "$STATE_HOME/.aap-demo/fleet/node-1" "$STATE_HOME/.ansible/conf"
printf 'ADDONS=ao,fleet\n' >"$STATE_HOME/.aap-demo/config"
printf 'INDEX=1\nPID=99999999\n' >"$STATE_HOME/.aap-demo/fleet/node-1/meta"
printf 'private-key\n' >"$STATE_HOME/.crc/machines/crc/id_ed25519"
printf 'vault-data\n' >"$STATE_HOME/.ansible/conf/env.yml"
printf 'vault-password\n' >"$STATE_HOME/.ansible/conf/.vaultpass.txt"
qemu-img create -f qcow2 "$STATE_HOME/.crc/base.qcow2" 1M >/dev/null
qemu-img create -f qcow2 -F qcow2 -b "$STATE_HOME/.crc/base.qcow2" \
  "$STATE_HOME/.crc/machines/crc/crc.qcow2" >/dev/null
qemu-img create -f qcow2 "$STATE_HOME/.aap-demo/fleet/node-1/disk.qcow2" 1M >/dev/null
rsync_bin=$(command -v rsync)
rsync() {
  [ "$FAIL_COPY" != true ] || return 42
  "$rsync_bin" "$@"
}
virsh() {
  case "$*" in
    *domstate*) echo "$DOMAIN_STATE" ;;
    *dumpxml*)
      printf '<domain><name>crc</name><os/><devices><disk type="file" device="disk"><source file="%s/.crc/machines/crc/crc.qcow2"/></disk>' "$STATE_HOME"
      if [ "$EXTRA_DISK" = true ]; then
        printf '<disk type="file" device="disk"><source file="%s/.aap-demo/storage/images.raw"/></disk>' "$STATE_HOME"
      fi
      printf '</devices></domain>\n'
      ;;
    *define*) : ;;
    *) return 1 ;;
  esac
}
restorecon() { :; }

(
  state_cli() { return 1; }
  virsh() {
    case "$*" in
      *domstate*) cat "$TEST_DIR/crc-state" ;;
      *destroy*)
        echo "$SECONDS" >"$TEST_DIR/forced-at"
        [ "${DESTROY_FAIL:-false}" != true ] || return 1
        echo 'shut off' >"$TEST_DIR/crc-state"
        ;;
      *) return 1 ;;
    esac
  }
  sleep() {
    SECONDS=$((SECONDS + $1))
    if [ "${STOP_NATURALLY:-false}" = true ]; then echo 'shut off' >"$TEST_DIR/crc-state"; fi
  }
  echo running >"$TEST_DIR/crc-state"
  if state_stop_crc >"$TEST_DIR/force-output" 2>&1; then exit 1; fi
  test ! -f "$TEST_DIR/forced-at"
  STATE_FORCE_STOP=true STATE_STOP_TIMEOUT=3
  SECONDS=0
  state_stop_crc >"$TEST_DIR/force-output" 2>&1
  test "$(cat "$TEST_DIR/forced-at")" -ge 3
  test "$STATE_CRC_SHUTDOWN" = forced
  grep -q 'crash-consistent' "$TEST_DIR/force-output"
  state_stopped
  rm "$TEST_DIR/forced-at"
  echo running >"$TEST_DIR/crc-state"
  STOP_NATURALLY=true state_stop_crc >"$TEST_DIR/force-output" 2>&1
  test ! -f "$TEST_DIR/forced-at"
  echo paused >"$TEST_DIR/crc-state"
  if state_stop_crc >"$TEST_DIR/force-output" 2>&1; then exit 1; fi
  test ! -f "$TEST_DIR/forced-at"
  echo running >"$TEST_DIR/crc-state"
  if DESTROY_FAIL=true state_stop_crc >"$TEST_DIR/force-output" 2>&1; then exit 1; fi
  test "$(cat "$TEST_DIR/crc-state")" = running
)
echo "PASS: forced CRC stop requires opt-in, waits the timeout, avoids clean/unknown states and propagates failure"

(
  bash -c 'exec -a qemu-system-test sleep 30' &
  guest_pid=$!
  trap 'kill "$guest_pid" 2>/dev/null || true' EXIT
  printf 'INDEX=1\nPID=%s\n' "$guest_pid" >"$STATE_HOME/.aap-demo/fleet/node-1/meta"
  state_user() {
    [ "$1" = ssh ]
    [ "${!#}" = 'sudo -n systemd-run --on-active=2s /usr/bin/systemctl poweroff' ]
    kill "$guest_pid"
    wait "$guest_pid" 2>/dev/null || true
  }
  state_stop
  trap - EXIT
)
printf 'INDEX=1\nPID=99999999\n' >"$STATE_HOME/.aap-demo/fleet/node-1/meta"
echo "PASS: Fleet shutdown is scheduled before SSH exits and disks are checked only after QEMU stops"

state_save >"$TEST_DIR/output" 2>&1
latest=$(readlink -f "$STATE_ROOT/latest")
state_verify "$latest"
rm "$latest/COMPLETE"
if state_verify "$latest"; then
  echo "FAIL: snapshot without a completion marker was accepted" >&2
  exit 1
fi
touch "$latest/COMPLETE"
test "$(find "$STATE_ROOT" -maxdepth 1 -type d -name 'state-*' | wc -l)" -eq 1
test "$(jq -r '.user' "$latest/manifest.json")" = "$STATE_USER"
grep -q '^PID=$' "$latest/home/.aap-demo/fleet/node-1/meta"
test "$(qemu-img info --output=json "$latest/home/.crc/machines/crc/crc.qcow2" \
  | jq -r 'has("backing-filename")')" = false
echo "PASS: full cold backup contains keys, vault, CRC/Fleet disks and flattened backing chains"

STATE_CRC_SHUTDOWN=forced state_save >"$TEST_DIR/output" 2>&1
latest=$(readlink -f "$STATE_ROOT/latest")
test "$(jq -r '.crc_shutdown' "$latest/manifest.json")" = forced
state_restore >"$TEST_DIR/output" 2>&1
grep -q 'crash-consistent checkpoint' "$TEST_DIR/output"
echo "PASS: forced-shutdown checkpoints record provenance and warn during restore"

mkdir -p "$STATE_HOME/.aap-demo/storage"
qemu-img create -f raw "$STATE_HOME/.aap-demo/storage/images.raw" 1M >/dev/null
EXTRA_DISK=true state_save >"$TEST_DIR/output" 2>&1
latest=$(readlink -f "$STATE_ROOT/latest")
test "$(qemu-img info --output=json "$latest/home/.aap-demo/storage/images.raw" | jq -r '.format')" = raw
echo "PASS: additional raw image-store disks retain the format expected by libvirt"

printf 'changed\n' >"$STATE_HOME/.aap-demo/config"
printf 'new-file\n' >"$STATE_HOME/.aap-demo/newer"
state_restore >"$TEST_DIR/output" 2>&1
grep -q '^ADDONS=ao,fleet$' "$STATE_HOME/.aap-demo/config"
test ! -e "$STATE_HOME/.aap-demo/newer"
grep -q '^vault-password$' "$STATE_HOME/.ansible/conf/.vaultpass.txt"
test "$(stat -c '%U' "$STATE_HOME/.ansible/conf")" = "$STATE_USER"
test "$(stat -c '%a' "$STATE_HOME/.ansible/conf")" = 700
echo "PASS: restore replaces newer managed state and recovers supporting credentials"

previous="$latest"
if FAIL_COPY=true state_save >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: failed backup was published" >&2
  exit 1
fi
test "$(readlink -f "$STATE_ROOT/latest")" = "$previous"
state_verify "$previous"
test "$(find "$STATE_ROOT" -name '.incomplete.*' | wc -l)" -eq 0
echo "PASS: failed backup leaves the last completed backup intact and cleans staging"

if DOMAIN_STATE=running state_save >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: backup read a running CRC disk" >&2
  exit 1
fi
test "$(readlink -f "$STATE_ROOT/latest")" = "$previous"
echo "PASS: live disks cannot be backed up"

STATE_KEEP=2
state_save >"$TEST_DIR/output" 2>&1
state_save >"$TEST_DIR/output" 2>&1
test "$(find "$STATE_ROOT" -maxdepth 1 -type d -name 'state-*' | wc -l)" -eq 2
test ! -d "$previous"
STATE_KEEP=1
state_save >"$TEST_DIR/output" 2>&1
test "$(find "$STATE_ROOT" -maxdepth 1 -type d -name 'state-*' | wc -l)" -eq 1
echo "PASS: retention keeps one completed state by default and supports a user-selected count"

latest=$(readlink -f "$STATE_ROOT/latest")
printf 'damaged\n' >>"$latest/home/.aap-demo/config"
printf 'current-safe\n' >"$STATE_HOME/.aap-demo/config"
if state_restore >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: corrupted backup was restored" >&2
  exit 1
fi
grep -q '^current-safe$' "$STATE_HOME/.aap-demo/config"
echo "PASS: checksum failure prevents overwriting current disks or configuration"

state_unit >"$TEST_DIR/aap-demo.service"
grep -q "After=.*user@${STATE_UID}.service.*libvirtd.service.*virtqemud.service" "$TEST_DIR/aap-demo.service"
grep -q '^ExecStop=/usr/local/libexec/aap-demo-state save$' "$TEST_DIR/aap-demo.service"
grep -q '^RemainAfterExit=yes$' "$TEST_DIR/aap-demo.service"
grep -q '^TimeoutStopSec=30min$' "$TEST_DIR/aap-demo.service"
if command -v systemd-analyze >/dev/null; then
  # Unit syntax can be verified without installing its privileged runner.
  sed -i -e 's#^ExecStart=.*#ExecStart=/usr/bin/true#' \
    -e 's#^ExecStop=.*#ExecStop=/usr/bin/true#' "$TEST_DIR/aap-demo.service"
  systemd-analyze verify "$TEST_DIR/aap-demo.service"
fi
echo "PASS: systemd ordering keeps user services and libvirt available for shutdown backup"

if output=$(QUIET=true "$REPO_ROOT/aap-demo.sh" service install --keep 0 2>&1); then
  echo "FAIL: invalid retention was accepted" >&2
  exit 1
fi
# Do not invoke sudo/systemd during CLI parsing tests.
source "$REPO_ROOT/includes/state-service.sh"
_err() { printf 'ERROR: %s\n' "$*" >&2; }
sudo() { printf 'sudo %s\n' "$*"; }
SCRIPT_DIR="$REPO_ROOT"
output=$(cmd_service install --force-stop --stop-timeout 45 --keep 2)
grep -q " $REPO_ROOT 2 true 45" <<<"$output"
for value in 0 -1 abc 86401 9999999999999999999999; do
  if cmd_service install --stop-timeout "$value" >"$TEST_DIR/output" 2>&1; then exit 1; fi
  grep -q 'Stop timeout' "$TEST_DIR/output"
done
if cmd_service install --stop-timeout >"$TEST_DIR/output" 2>&1; then exit 1; fi
grep -q 'Missing value' "$TEST_DIR/output"
STATE_FORCE_STOP=true STATE_STOP_TIMEOUT=45 state_config_write "$TEST_DIR/service.conf"
grep -q '^STATE_FORCE_STOP=true$' "$TEST_DIR/service.conf"
grep -q '^STATE_STOP_TIMEOUT=45$' "$TEST_DIR/service.conf"
echo "PASS: Linux forced-stop flags validate before sudo and persist in root service configuration"
output=$(cmd_service retention 3)
grep -q 'aap-demo-state retention 3' <<<"$output"
for action in start restart stop; do
  output=$(aap_demo_service_lifecycle "$action")
  if [ "$action" = stop ]; then
    grep -q 'systemctl stop aap-demo.service' <<<"$output"
  else
    grep -q 'systemctl restart aap-demo.service' <<<"$output"
  fi
done
systemctl() { return 1; }
output=$(cmd_service backup)
grep -q 'aap-demo-state save' <<<"$output"
grep -q 'systemctl start aap-demo.service' <<<"$output"
output=$(QUIET=true "$REPO_ROOT/aap-demo.sh" service invalid-action 2>&1) && exit 1
grep -q 'Usage: aap-demo service' <<<"$output"
echo "PASS: nested service actions and start/restart/stop route through systemd"

(
  LOG="$TEST_DIR/activate-log"
  systemctl() {
    echo "$*" >>"$LOG"
    [ "$1" != "${FAIL_ACTION:-}" ]
  }
  state_activate
  test "$(cat "$LOG")" = "$(printf 'daemon-reload\nrestart aap-demo.service\nenable aap-demo.service\n')"
  : >"$LOG"
  if FAIL_ACTION=restart state_activate >"$TEST_DIR/activate-output" 2>&1; then
    echo "FAIL: a failed recovery installation was enabled" >&2
    exit 1
  fi
  test "$(cat "$LOG")" = "$(printf 'daemon-reload\nrestart aap-demo.service\ndisable aap-demo.service\n')"
  grep -q 'Recovery validation failed' "$TEST_DIR/activate-output"
  : >"$LOG"
  if FAIL_ACTION=daemon-reload state_activate; then exit 1; fi
  test "$(cat "$LOG")" = daemon-reload
  : >"$LOG"
  if FAIL_ACTION=enable state_activate; then exit 1; fi
  test "$(cat "$LOG")" = "$(printf 'daemon-reload\nrestart aap-demo.service\nenable aap-demo.service\n')"
)
echo "PASS: reinstall restarts and validates recovery before enabling boot startup; failures propagate"

(
  LOG="$TEST_DIR/boot-log"
  state_stop() { echo stop >>"$LOG"; }
  state_save() { echo save >>"$LOG"; }
  state_restore() { echo restore >>"$LOG"; }
  # Default: VM is stopped, so the daemon restart runs. The status probe is
  # consumed from the log; reply "Stopped" without logging it as a user action.
  state_user() {
    if [ "$1" = crc ] && [ "$2" = status ]; then
      printf 'CRC VM:                  Stopped\n'
      return 0
    fi
    echo "user $*" >>"$LOG"
  }
  state_cli() { echo "cli $*" >>"$LOG"; }
  printf 'latest-live-configuration\n' >"$STATE_HOME/.aap-demo/config"
  printf 'latest-live-vault\n' >"$STATE_HOME/.ansible/conf/env.yml"
  state_boot
  expected=$(printf 'user systemctl --user restart crc-daemon.service\ncli start\ncli dashboard --no-open\n')
  test "$(cat "$LOG")" = "$expected"
  # When the VM is already running, the daemon restart is skipped so the vsock
  # SSH forward is not dropped.
  state_user() {
    if [ "$1" = crc ] && [ "$2" = status ]; then
      printf 'CRC VM:                  Running\n'
      return 0
    fi
    echo "user $*" >>"$LOG"
  }
  : >"$LOG"
  state_boot
  test "$(cat "$LOG")" = "$(printf 'cli start\ncli dashboard --no-open\n')"
  state_user() {
    if [ "$1" = crc ] && [ "$2" = status ]; then
      printf 'CRC VM:                  Stopped\n'
      return 0
    fi
    echo "user $*" >>"$LOG"
  }
  : >"$LOG"
  grep -qx 'latest-live-configuration' "$STATE_HOME/.aap-demo/config"
  grep -qx 'latest-live-vault' "$STATE_HOME/.ansible/conf/env.yml"
  : >"$LOG"
  STATE_ROOT="$TEST_DIR/no-backup"
  state_boot
  test "$(cat "$LOG")" = "$expected"
  : >"$LOG"
  state_shutdown
  test "$(cat "$LOG")" = "$(printf 'stop\nsave\n')"
  mkdir -p "$STATE_ROOT"
  ln -s missing-state "$STATE_ROOT/latest"
  : >"$LOG"
  state_boot
  test "$(cat "$LOG")" = "$expected"
  state_save() { echo save >>"$LOG"; return 1; }
  : >"$LOG"
  if state_shutdown; then
    echo "FAIL: shutdown ignored checkpoint failure" >&2
    exit 1
  fi
  test -f "$STATE_ROOT/.shutdown-pending"
  : >"$LOG"
  state_boot >"$TEST_DIR/pending-output" 2>&1
  test "$(cat "$LOG")" = "$expected"
  test ! -e "$STATE_ROOT/.shutdown-pending"
  grep -q 'last shutdown backup did not complete' "$TEST_DIR/pending-output"
  grep -qx 'latest-live-configuration' "$STATE_HOME/.aap-demo/config"
  printf 'previous-host-boot\n' >"$STATE_ROOT/.shutdown-pending"
  : >"$LOG"
  state_boot >"$TEST_DIR/pending-output" 2>&1
  test "$(cat "$LOG")" = "$expected"
  test ! -e "$STATE_ROOT/.shutdown-pending"
  state_cli() { echo "cli $*" >>"$LOG"; [ "$1" != start ]; }
  : >"$LOG"
  if state_boot; then echo "FAIL: CRC startup failure was ignored" >&2; exit 1; fi
  test "$(cat "$LOG")" = "$(printf 'user systemctl --user restart crc-daemon.service\ncli start\n')"
  state_cli() { echo "cli $*" >>"$LOG"; [ "$1" != dashboard ]; }
  : >"$LOG"
  if state_boot; then echo "FAIL: dashboard startup failure was ignored" >&2; exit 1; fi
  test "$(cat "$LOG")" = "$expected"
  state_user() {
    if [ "$1" = crc ] && [ "$2" = status ]; then
      printf 'CRC VM:                  Stopped\n'
      return 0
    fi
    echo "user $*" >>"$LOG"
    return 1
  }
  : >"$LOG"
  if state_boot; then echo "FAIL: CRC daemon failure was ignored" >&2; exit 1; fi
  test "$(cat "$LOG")" = "user systemctl --user restart crc-daemon.service"
)
echo "PASS: boot preserves latest live state without copying old checkpoints; shutdown saves only stopped state"
echo "PASS: incomplete or stale backups cannot cause automatic rollback; startup failures propagate"

(
  AAP_DEMO_LOCK_DIR="$TEST_DIR/service-operation.lock"
  source "$REPO_ROOT/includes/operation-lock.sh"
  mkdir "$AAP_DEMO_LOCK_DIR"
  printf 'pid=%s\ncommand=service-save\n' "$$" >"$AAP_DEMO_LOCK_DIR/owner"
  kill() { return 1; }
  if aap_demo_acquire_operation_lock redeploy >"$TEST_DIR/lock-output" 2>&1; then
    echo "FAIL: service lock was treated as stale when kill -0 lacked permission" >&2
    exit 1
  fi
  grep -q 'Another aap-demo operation' "$TEST_DIR/lock-output"
)
echo "PASS: a root-owned service PID blocks concurrent user mutations"
