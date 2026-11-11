#!/usr/bin/env bash
# Regression tests for dependency-safe addon restoration after redeploy-all.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
RESTORE_LOG="${TEST_DIR}/restore.log"
SAVED_ADDONS=""

_err() {
  printf 'ERROR: %s\n' "$*" >&2
}

cmd_enable() {
  printf '%s FORCE=%s QUIET=%s\n' "$1" "${FORCE:-}" "${QUIET:-}" >>"$RESTORE_LOG"
}

_aap_demo_run_addon_wire() {
  printf 'wire strict=%s\n' "$1" >>"$RESTORE_LOG"
}

_addons_save() {
  SAVED_ADDONS="$1"
}

# shellcheck source=../includes/addon-restore.sh
source "${REPO_ROOT}/includes/addon-restore.sh"

saved="ao product-demo-windows apme-eap setup-pah ollama mcp-server"
expected="mcp-server ollama setup-pah product-demo-windows apme-eap ao"
actual=$(aap_demo_order_addons_for_restore "$saved")
if [ "$actual" != "$expected" ]; then
  echo "FAIL: unexpected restore order: $actual" >&2
  exit 1
fi
echo "PASS: dependencies restore before AO"

aap_demo_preserve_addon_selection "$saved"
if [ "$SAVED_ADDONS" != "ao,product-demo-windows,apme-eap,setup-pah,ollama,mcp-server" ]; then
  echo "FAIL: addon selection was not preserved" >&2
  exit 1
fi
echo "PASS: original addon selection is preserved"

CRC_MEMORY=16384
if aap_demo_validate_redeploy_addon_capacity "$saved" >/dev/null 2>&1; then
  echo "FAIL: undersized APME and AO cluster passed validation" >&2
  exit 1
fi
CRC_MEMORY=24576
if ! aap_demo_validate_redeploy_addon_capacity "$saved"; then
  echo "FAIL: 24 GiB cluster failed addon capacity validation" >&2
  exit 1
fi
echo "PASS: full addon set requires 24 GiB"

aap_demo_restore_addons "$saved" >/dev/null
cat >"${TEST_DIR}/expected.log" <<'EOF'
mcp-server FORCE=true QUIET=true
ollama FORCE=true QUIET=true
setup-pah FORCE=true QUIET=true
product-demo-windows FORCE=true QUIET=true
apme-eap FORCE=true QUIET=true
ao FORCE=true QUIET=true
wire strict=true
EOF
if ! cmp -s "${TEST_DIR}/expected.log" "$RESTORE_LOG"; then
  echo "FAIL: restore did not force addons and strict wiring" >&2
  diff -u "${TEST_DIR}/expected.log" "$RESTORE_LOG" >&2 || true
  exit 1
fi
echo "PASS: restore forces every addon and strict wiring"

: >"$RESTORE_LOG"
aap_demo_restore_addons "" >/dev/null
if [ -s "$RESTORE_LOG" ]; then
  echo "FAIL: empty addon configuration triggered restoration" >&2
  exit 1
fi
echo "PASS: empty addon configuration is a no-op"
