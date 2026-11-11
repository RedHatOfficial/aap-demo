#!/usr/bin/env bash
# Regression tests for Fleet registration failure handling.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR"
mkdir -p "${HOME}/.aap-demo/fleet/node-1"
cat >"${HOME}/.aap-demo/fleet/node-1/meta" <<EOF
HOSTNAME=aap-fleet-node-1
PORT=2201
PID=$$
EOF

_err() {
  printf 'ERROR: %s\n' "$*" >&2
}

get_ingress_ca_cert_path() {
  return 1
}

# shellcheck source=../addons/fleet/fleet-aap.sh
source "${REPO_ROOT}/addons/fleet/fleet-aap.sh"

_fleet_aap_ensure_subscription() {
  return 0
}

_fleet_aap_get_auth() {
  _FLEET_AAP_URL="https://aap.example.test"
  return 0
}

_fleet_aap_get_org_id() {
  printf '1'
}

_fleet_aap_get_credential_type_id() {
  printf '1'
}

_fleet_aap_get_host_gateway_ip() {
  printf '192.0.2.1'
}

_fleet_ssh_private_key_path() {
  printf '%s' "${TEST_DIR}/ssh_key"
}

_fleet_aap_create_credential() {
  printf '3'
}

_fleet_aap_create_inventory() {
  printf '2'
}

_fleet_aap_api() {
  printf '{"results":[]}'
}

_fleet_aap_create_host() {
  _err "Failed to create host '$2'"
  printf '{"detail":"License is missing."}\n' >&2
  return 1
}

ping_marker="${TEST_DIR}/ping-called"
_fleet_aap_run_ping() {
  touch "$ping_marker"
}

output=$(fleet_register_aap 2>&1)
status=$?
if [ "$status" -eq 0 ]; then
  echo "FAIL: registration succeeded after host creation failed" >&2
  exit 1
fi
if [ -e "$ping_marker" ]; then
  echo "FAIL: registration attempted ping after host creation failed" >&2
  exit 1
fi
if ! grep -q "One or more Fleet nodes could not be registered" <<<"$output" \
  || ! grep -q "aap-demo fleet register" <<<"$output" \
  || grep -q "Fleet nodes registered in AAP" <<<"$output"; then
  echo "FAIL: registration failure output is incorrect" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

echo "PASS: host creation failure stops Fleet registration"

deleted_hosts="${TEST_DIR}/deleted-hosts"
_fleet_aap_api() {
  local method="$1"
  local endpoint="$2"
  if [ "$method" = "GET" ]; then
    cat <<'EOF'
{"results":[
  {"id":11,"name":"aap-fleet-node-1"},
  {"id":44,"name":"aap-fleet-node-4"},
  {"id":99,"name":"user-managed-host"}
]}
EOF
  elif [ "$method" = "DELETE" ]; then
    printf '%s\n' "$endpoint" >>"$deleted_hosts"
  fi
}

output=$(_fleet_aap_remove_stale_hosts 2 2>&1)
if [ "$(cat "$deleted_hosts")" != "/hosts/44/" ]; then
  echo "FAIL: Fleet reconciliation deleted the wrong AAP hosts" >&2
  cat "$deleted_hosts" >&2
  exit 1
fi
if ! grep -q "Removed stale host 'aap-fleet-node-4'" <<<"$output"; then
  echo "FAIL: Fleet reconciliation did not report the stale host" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

echo "PASS: Fleet registration removes only stale managed hosts"
