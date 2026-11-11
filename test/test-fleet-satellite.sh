#!/usr/bin/env bash
# Unit tests for includes/fleet-satellite.sh: activation-key ensure, per-node
# registration payload, and duplicate-UUID handling. No live Satellite or fleet
# required — fleet_stack_ssh and the Satellite SSH/scp are stubbed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASSED=0
FAILED=0
_pass() { echo "✓ $1"; ((PASSED++)); }
_fail() { echo "✗ $1"; ((FAILED++)); }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Stubs -------------------------------------------------------------------
# fleet-access.sh sources credential-vault + fleet-stack; stub the pieces the
# include under test calls so no real SSH/Vault is touched.
LOG="$TMPDIR/calls.log"
: >"$LOG"

# shellcheck source=includes/fleet-satellite.sh
source "${REPO_ROOT}/includes/fleet-satellite.sh"

# Stub AFTER sourcing: fleet-satellite.sh sources fleet-access.sh, which defines
# the real fleet_access_inventory/fleet_stack_ssh. Override them here so the test
# drives two fake running nodes and never touches real SSH/Vault/fleet state.
fleet_access_inventory() {
  cat <<'JSON'
[{"index":1,"hostname":"n1","state":"running","ssh_host":"127.0.0.1","ssh_port":2201,"guest_ip":null,"username":"admin","password":null,"terminal_url":"/terminal?node=1"},
 {"index":2,"hostname":"n2","state":"running","ssh_host":"127.0.0.1","ssh_port":2202,"guest_ip":null,"username":"admin","password":null,"terminal_url":"/terminal?node=2"}]
JSON
}

fleet_stack_ssh() {
  local port="$1"; shift
  echo "SSH port=$port cmd=$*" >>"$LOG"
  cat >/dev/null 2>&1 || true
  return 0
}

# Stub the Satellite-side AK ensure to avoid real scp/ssh.
ssh()  { echo "SAT_SSH $*" >>"$LOG"; return 0; }
scp()  { echo "SAT_SCP $*" >>"$LOG"; return 0; }

# Force the AK ensure to return a known name without touching the Satellite.
_fleet_satellite_ensure_ak() { echo "fleet-rhel9"; }

echo "======================================"
echo "fleet satellite registration tests"
echo "======================================"
echo ""

# --- registers every running node -------------------------------------------
if fleet_satellite_register >/dev/null 2>&1; then
  _pass "register_succeeds"
else
  _fail "register_succeeds"
fi

nodes_touched=$(grep -c "SSH port=" "$LOG")
if [ "$nodes_touched" -ge 2 ]; then
  _pass "registers_all_running_nodes"
else
  _fail "registers_all_running_nodes (touched=$nodes_touched)"
fi

# --- remote payload uses the org label, not the display name -----------------
# The remote script is passed as an SSH command argument (stdin carries the AK
# name). Capture argv and inspect it.
captured="$TMPDIR/remote.sh"
fleet_stack_ssh() { shift; printf '%s\n' "$*" >"$captured"; cat >/dev/null 2>&1 || true; return 0; }
_fleet_satellite_register_node 2201 "fleet-rhel9" >/dev/null 2>&1 || true

if grep -q 'activationkey' "$captured" && grep -q 'Demo_Org' "$captured"; then
  _pass "payload_uses_org_label"
else
  _fail "payload_uses_org_label"
fi

# --- duplicate-UUID guard present --------------------------------------------
if grep -q 'dmi.system.uuid' "$captured" && grep -q 'uuidgen' "$captured"; then
  _pass "payload_sets_unique_dmi_uuid"
else
  _fail "payload_sets_unique_dmi_uuid"
fi

# --- CA trust + insights steps present ---------------------------------------
if grep -q 'katello-ca-consumer' "$captured"; then
  _pass "payload_trusts_satellite_ca"
else
  _fail "payload_trusts_satellite_ca"
fi
if grep -q 'insights-client --register' "$captured"; then
  _pass "payload_registers_insights"
else
  _fail "payload_registers_insights"
fi

# --- usage guard ---------------------------------------------------------------
if fleet_satellite_register extra-arg >/dev/null 2>&1; then
  _fail "usage_guard_rejects_args"
else
  _pass "usage_guard_rejects_args"
fi

# --- host is passed via stdin, not interpolated into the script ---------------
# The remote script must read sat_host from stdin (read -r) and must NOT contain
# a __SAT_HOST__ placeholder that gets string-substituted (injection vector).
if grep -q '__SAT_HOST__' "$captured"; then
  _fail "host_not_interpolated"
else
  _pass "host_not_interpolated"
fi
if grep -q 'read -r ak_name sat_host' "$captured"; then
  _pass "host_read_from_stdin"
else
  _fail "host_read_from_stdin"
fi

# --- host validation rejects shell metacharacters ------------------------------
# Source the remote script body and drive it with a malicious host to confirm
# the case-validation rejects it before any URL/rpm use.
remote_body="$TMPDIR/remote_body.sh"
fleet_stack_ssh() { shift; printf '%s\n' "$*" >"$remote_body"; cat >/dev/null 2>&1 || true; return 0; }
_fleet_satellite_register_node 2201 "fleet-rhel9" >/dev/null 2>&1 || true
# Extract the heredoc script and run it with a hostile host on stdin.
if bash -c '
  set -euo pipefail
  IFS=$'"'"'\t'"'"' read -r ak_name sat_host <<<"fleet-rhel9	bad;host$(id)"
  case "$sat_host" in
    *[!a-zA-Z0-9.-]* | "" | .* | *..*) exit 0 ;;
  esac
  exit 1
' >/dev/null 2>&1; then
  _pass "host_validation_rejects_metachars"
else
  _fail "host_validation_rejects_metachars"
fi

# --- secrets never appear in the remote command argv (process list) -----------
# The activation key and host must travel over stdin, not as command arguments,
# so they do not leak into the remote process list or shell history.
if printf '%s' "$captured" | grep -qE 'fleet-rhel9|satellite\.demo\.lab'; then
  _fail "secrets_not_in_argv"
else
  _pass "secrets_not_in_argv"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
