#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
FLEET_ACCESS_DIR="$REPO_ROOT/includes"
FLEET_CDN_USERNAME_KEY=user
FLEET_CDN_PASSWORD_KEY=password
source "$REPO_ROOT/includes/fleet-rhc.sh"
_err() { printf 'ERROR: %s\n' "$*" >&2; }
fleet_access_inventory() {
  printf '[{"index":1,"ssh_port":2201,"state":"running"},{"index":2,"ssh_port":2202,"state":"stopped"},{"index":3,"ssh_port":2203,"state":"running"}]'
}
aap_demo_vault_get() {
  case "$1" in user) printf 'fixture-user' ;; password) printf 'fixture-secret' ;; esac
}
fleet_stack_ssh() {
  [[ "$2" == 'sudo python3 -c '* ]]
  [[ "$2" != *fixture-user* && "$2" != *fixture-secret* ]]
  python3 -c 'import json,sys; c=json.load(sys.stdin); assert c=={"username":"fixture-user","password":"fixture-secret"}'
  printf '%s\n' "$1" >>"$TEST_DIR/ports"
  [ "$1" != "${FAIL_PORT:-}" ]
}
fleet_rhc_connect >"$TEST_DIR/output"
test "$(cat "$TEST_DIR/ports")" = $'2201\n2203'
! grep -q 'fixture-secret\|fixture-user' "$TEST_DIR/output"
FAIL_PORT=2201
if fleet_rhc_connect >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: node enrollment failure ignored"; exit 1
fi
! grep -q 'All running Fleet nodes' "$TEST_DIR/output"
if fleet_rhc_connect unexpected >/dev/null 2>&1; then
  echo "FAIL: unsupported registration arguments accepted"; exit 1
fi
echo "PASS: manual RHC enrollment uses stdin credentials, skips stopped nodes, and propagates failure"
