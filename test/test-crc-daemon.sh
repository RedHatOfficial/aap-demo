#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/proc"

cat >"$TEST_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CRC_DAEMON_TEST_LOG"
case "$*" in
  "--user cat crc-http.socket crc-vsock.socket") exit 0 ;;
  "--user show crc-daemon.service --property MainPID --value")
    printf '0\n'
    ;;
  "--user restart crc-http.socket crc-vsock.socket")
    : >"$CRC_DAEMON_READY_MARKER"
    ;;
esac
EOF
chmod +x "$TEST_DIR/bin/systemctl"

export PATH="$TEST_DIR/bin:$PATH"
export CRC_DAEMON_TEST_LOG="$TEST_DIR/systemctl.log"
export CRC_DAEMON_READY_MARKER="$TEST_DIR/ready"
export AAP_DEMO_PROC_ROOT="$TEST_DIR/proc"
export AAP_DEMO_CONFIGURE_COREDNS_ONLY=1
export _INFRA_API_LOADED=""
unset SCRIPT_DIR

# shellcheck source=../includes/crc-create.sh
source "$REPO_ROOT/includes/crc-create.sh"

_crc_daemon_api_ready() {
  [ -f "$CRC_DAEMON_READY_MARKER" ]
}

_crc_daemon_ensure

grep -Fq -- '--user daemon-reload' "$CRC_DAEMON_TEST_LOG"
grep -Fq -- '--user reset-failed crc-daemon.service crc-http.socket crc-vsock.socket' \
  "$CRC_DAEMON_TEST_LOG"
grep -Fq -- '--user restart crc-http.socket crc-vsock.socket' "$CRC_DAEMON_TEST_LOG"

if grep -Fq -- '! [ -S ~/.crc/crc-http.sock ]' "$REPO_ROOT/includes/crc-create.sh"; then
  echo "FAIL: obsolete CRC socket readiness check remains" >&2
  exit 1
fi
if grep -Fq -- 'crc daemon &>/dev/null &' "$REPO_ROOT/includes/crc-create.sh"; then
  echo "FAIL: unmanaged CRC daemon launch remains" >&2
  exit 1
fi

echo "PASS: CRC daemon readiness uses systemd sockets without duplicate daemons"
