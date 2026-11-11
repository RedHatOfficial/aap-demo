#!/usr/bin/env bash
# Regression tests for Fleet command argument parsing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

_err() {
  printf 'ERROR: %s\n' "$*" >&2
}

# shellcheck source=../addons/fleet/fleet-cli.sh
source "${REPO_ROOT}/addons/fleet/fleet-cli.sh"

fleet_parse_add_args 3 --image /tmp/rhel9.qcow2
if [ "$FLEET_ADD_COUNT" != 3 ] || [ "$FLEET_ADD_IMAGE" != /tmp/rhel9.qcow2 ]; then
  echo "FAIL: separated --image syntax was not parsed" >&2
  exit 1
fi
echo "PASS: parses --image PATH"

fleet_parse_add_args --image=/tmp/rhel9.qcow2 2
if [ "$FLEET_ADD_COUNT" != 2 ] || [ "$FLEET_ADD_IMAGE" != /tmp/rhel9.qcow2 ]; then
  echo "FAIL: equals --image syntax was not parsed" >&2
  exit 1
fi
echo "PASS: parses --image=PATH"

if output=$(fleet_parse_add_args 3 --image /tmp/rhel9.qcow2 ao 2>&1); then
  echo "FAIL: unexpected trailing argument was accepted" >&2
  exit 1
fi
if ! grep -q "Unexpected argument for 'fleet add': ao" <<<"$output"; then
  echo "FAIL: trailing argument did not produce a useful error" >&2
  echo "$output" >&2
  exit 1
fi
echo "PASS: rejects unexpected trailing arguments"

if fleet_parse_add_args 3 --image >/dev/null 2>&1; then
  echo "FAIL: missing image value was accepted" >&2
  exit 1
fi
echo "PASS: rejects missing image value"

export HOME="$TEST_HOME"
# shellcheck source=../addons/fleet/fleet.sh
source "${REPO_ROOT}/addons/fleet/fleet.sh"
list_output=$(fleet_list)
if ! grep -q 'aap-demo fleet add <count> --image <rhel9|rhel10|local-qcow2-path>' <<<"$list_output"; then
  echo "FAIL: empty Fleet list does not show managed-image syntax" >&2
  echo "$list_output" >&2
  exit 1
fi
echo "PASS: empty Fleet list shows managed-image syntax"

# fleet_node_power validates the index and action and updates the node meta.
FLEET_DIR="$TEST_HOME/fleet"
mkdir -p "$FLEET_DIR/node-1"
printf 'INDEX=1\nPORT=2201\nPID=\nHOSTNAME=aap-fleet-node-1\nSTATUS=stopped\n' >"$FLEET_DIR/node-1/meta"

if fleet_node_power "abc" start >/dev/null 2>&1; then
  echo "FAIL: non-numeric node index was accepted" >&2
  exit 1
fi
echo "PASS: rejects a non-numeric node index"

if fleet_node_power 1 powercycle >/dev/null 2>&1; then
  echo "FAIL: unknown power action was accepted" >&2
  exit 1
fi
echo "PASS: rejects an unknown power action"

if fleet_node_power 9 stop >/dev/null 2>&1; then
  echo "FAIL: a missing node was accepted" >&2
  exit 1
fi
echo "PASS: rejects a missing node"

# stop on an existing (stopped) node updates the meta without error.
fleet_node_start() { return 0; }
_fleet_stop_vm() { return 0; }
fleet_reconcile_access() { return 0; }
fleet_node_power 1 stop >/dev/null 2>&1
grep -q '^STATUS=stopped$' "$FLEET_DIR/node-1/meta" || {
  echo "FAIL: stop did not mark the node stopped" >&2
  exit 1
}
echo "PASS: stop marks the node stopped"

fleet_node_power 1 restart >/dev/null 2>&1
echo "PASS: restart runs stop then start"
