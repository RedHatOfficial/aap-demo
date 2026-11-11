#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="$TEST_DIR"
source "$REPO_ROOT/addons/fleet/fleet-aap.sh"
printf 'fixture-private-key\n' >"$TEST_DIR/ssh_key"
_err() { printf 'ERROR: %s\n' "$*" >&2; }
_fleet_aap_api() {
  printf '%s %s\n' "$1" "$2" >>"$TEST_DIR/requests"
  case "$1 $2" in
    'GET /credentials/'*) printf '{"count":1,"results":[{"id":3}]}' ;;
    'GET /inventories/2/hosts/'*) printf '{"count":1,"results":[{"id":4}]}' ;;
    'PATCH /credentials/3/') printf '%s' "$3" >"$TEST_DIR/credential"; printf '{"id":3}' ;;
    'PATCH /hosts/4/') printf '%s' "$3" >"$TEST_DIR/host"; printf '{"id":4}' ;;
    'POST /inventories/2/ad_hoc_commands/') printf '{"id":29}' ;;
    'GET /ad_hoc_commands/29/') printf '{"status":"%s"}' "$PING_STATUS" ;;
    *) echo "Unexpected API call: $1 $2" >&2; return 1 ;;
  esac
}
test "$(_fleet_aap_create_credential 1 1 "$TEST_DIR/ssh_key")" = 3
jq -e '.inputs.username == "ansible" and .inputs.ssh_key_data == "fixture-private-key\n"' "$TEST_DIR/credential" >/dev/null
_fleet_aap_create_host 2 aap-fleet-node-1 192.0.2.12 2201 >/dev/null
jq -e '.inventory == 2 and (.variables | contains("ansible_host: 192.0.2.12"))
  and (.variables | contains("ansible_port: 2201"))
  and (.variables | contains("ansible_user: ansible"))' "$TEST_DIR/host" >/dev/null
grep -q 'GET /inventories/2/hosts/?name=aap-fleet-node-1' "$TEST_DIR/requests"
sleep() { :; }
PING_STATUS=failed
if _fleet_aap_run_ping 2 3 >/dev/null; then
  echo "FAIL: failed AAP ping was accepted" >&2; exit 1
fi
PING_STATUS=successful
_fleet_aap_run_ping 2 3 >/dev/null
echo "PASS: Fleet registration uses bootstrap automation credentials and rejects failed pings"
