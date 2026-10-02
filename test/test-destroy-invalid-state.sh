#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-destroy-invalid-state.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/home/.aap-demo"

cat >"$TEST_DIR/bin/crc" <<'MOCK_CRC'
#!/usr/bin/env bash
set -euo pipefail

log="${AAP_DEMO_TEST_LOG:?}"
delete_count_file="${AAP_DEMO_TEST_DELETE_COUNT:?}"
status_count_file="${AAP_DEMO_TEST_STATUS_COUNT:?}"

printf 'crc %s\n' "$*" >>"$log"

case "$*" in
  "status")
    count=0
    [ -f "$status_count_file" ] && count="$(cat "$status_count_file")"
    count=$((count + 1))
    printf '%s' "$count" >"$status_count_file"
    if [ "$count" -eq 1 ]; then
      cat <<'STATUS'
CRC VM:                  Running
MicroShift:              Running (v4.22.0)
STATUS
    else
      cat <<'STATUS'
CRC VM:                  Stopped
MicroShift:              Stopped
STATUS
    fi
    exit 0
    ;;
  "delete -f")
    count=0
    [ -f "$delete_count_file" ] && count="$(cat "$delete_count_file")"
    count=$((count + 1))
    printf '%s' "$count" >"$delete_count_file"
    echo 'level=error msg="Cannot remove machine: Driver cannot remove machine: machine in invalid state for action"' >&2
    exit 1
    ;;
  "delete")
    echo 'level=error msg="Cannot remove machine: Driver cannot remove machine: machine in invalid state for action"' >&2
    exit 1
    ;;
  "cleanup")
    exit 0
    ;;
  "stop")
    exit 0
    ;;
  *)
    echo "unexpected crc args: $*" >&2
    exit 2
    ;;
esac
MOCK_CRC
chmod +x "$TEST_DIR/bin/crc"

cat >"$TEST_DIR/bin/podman" <<'MOCK_PODMAN'
#!/usr/bin/env bash
set -euo pipefail
printf 'podman %s\n' "$*" >>"${AAP_DEMO_TEST_LOG:?}"
exit 0
MOCK_PODMAN
chmod +x "$TEST_DIR/bin/podman"

export PATH="$TEST_DIR/bin:$PATH"
export HOME="$TEST_DIR/home"
export AAP_DEMO_CONFIG="$TEST_DIR/home/.aap-demo/config"
export AAP_PERSISTENT_IMAGE_STORE=false
export AAP_DEMO_TEST_LOG="$TEST_DIR/calls.log"
export AAP_DEMO_TEST_DELETE_COUNT="$TEST_DIR/delete-count"
export AAP_DEMO_TEST_STATUS_COUNT="$TEST_DIR/status-count"

output="$(QUIET=true "$REPO_ROOT/aap-demo.sh" destroy --skip-cache 2>&1)"
if ! grep -q 'CRC cluster deleted' <<<"$output"; then
  echo "Expected destroy to recover and delete the cluster. Output:" >&2
  echo "$output" >&2
  exit 1
fi

expected=$'crc status\ncrc stop\ncrc status\ncrc delete -f\ncrc stop\ncrc status\ncrc delete -f\ncrc delete\ncrc cleanup\npodman system connection remove aap-demo'
actual="$(cat "$AAP_DEMO_TEST_LOG")"
if [ "$actual" != "$expected" ]; then
  echo "Unexpected command order" >&2
  echo "Expected:" >&2
  printf '%s\n' "$expected" >&2
  echo "Actual:" >&2
  printf '%s\n' "$actual" >&2
  exit 1
fi

echo "destroy invalid-state retry test passed"
