#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-infra-crc-status.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/crc" <<'MOCK_CRC'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "status" ] && [ "${2:-}" = "--output" ] && [ "${3:-}" = "json" ]; then
  echo 'chmod C:\Users\adler\.crc\sockets: Access is denied.' >&2
  exit 1
fi

if [ "${1:-}" = "status" ] && [ "$#" -eq 1 ]; then
  cat <<'STATUS'
CRC VM:                  Running
MicroShift:              Running (v4.22.0)
RAM Usage:               12.16GB of 16.76GB
STATUS
  exit 0
fi

echo "unexpected crc args: $*" >&2
exit 2
MOCK_CRC
chmod +x "$TEST_DIR/bin/crc"

export PATH="$TEST_DIR/bin:$PATH"

# shellcheck source=../includes/infra-crc.sh
. "$REPO_ROOT/includes/infra-crc.sh"

state="$(_infra_crc_get_state)"
if [ "$state" != "running" ]; then
  echo "Expected infra state running from plain crc status fallback, got '$state'" >&2
  exit 1
fi

echo "infra CRC status fallback test passed"
