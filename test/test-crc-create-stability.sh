#!/usr/bin/env bash
# Regression test for CRC/vfkit rebooting during the create flow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

MOCK_BIN="${TEST_DIR}/bin"
mkdir -p "$MOCK_BIN"

cat >"${MOCK_BIN}/crc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count_file="${CRC_STATUS_COUNT_FILE}"
count=0
if [ -f "$count_file" ]; then
  count=$(cat "$count_file")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"

if [ "$1" = "status" ]; then
  if [ "${CRC_RECOVERY_MODE:-false}" = "true" ] && [ ! -f "${CRC_RECOVERY_MARKER_FILE}" ]; then
    printf '%s\n' '{"crcStatus":"Stopped","openshiftStatus":"Stopped"}'
  elif [ "$count" -eq 1 ]; then
    printf '%s\n' '{"crcStatus":"Stopped","openshiftStatus":"Stopped"}'
  else
    printf '%s\n' '{"crcStatus":"Running","openshiftStatus":"Unreachable"}'
  fi
  exit 0
fi

if [ "$1" = "start" ]; then
  : >"${CRC_RECOVERY_MARKER_FILE}"
  exit 0
fi

echo "unexpected crc command: $*" >&2
exit 1
EOF
chmod +x "${MOCK_BIN}/crc"

cat >"${MOCK_BIN}/kubectl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${MOCK_BIN}/kubectl"

export PATH="${MOCK_BIN}:$PATH"
export CRC_STATUS_COUNT_FILE="${TEST_DIR}/status-count"
export CRC_RECOVERY_MARKER_FILE="${TEST_DIR}/recovered"
export AAP_DEMO_CONFIGURE_COREDNS_ONLY=1
export AAP_DEMO_CRC_STABILITY_SLEEP=0
export _INFRA_API_LOADED=""
unset SCRIPT_DIR

# shellcheck source=../includes/crc-create.sh
source "${REPO_ROOT}/includes/crc-create.sh"

_wait_for_crc_stable 2

[ "$(cat "$CRC_STATUS_COUNT_FILE")" -ge 3 ]
echo "✓ CRC stability wait ignores a stopped first sample"

rm -f "$CRC_STATUS_COUNT_FILE" "$CRC_RECOVERY_MARKER_FILE"
export CRC_RECOVERY_MODE=true
export AAP_DEMO_CRC_STABILITY_ATTEMPTS=3
_ensure_crc_stable_after_create
[ -f "$CRC_RECOVERY_MARKER_FILE" ]
echo "✓ CRC stability recovery restarts an unhealthy VM once"
