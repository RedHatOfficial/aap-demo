#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
source "$REPO_ROOT/includes/fleet-stack.sh"
source "$REPO_ROOT/includes/fleet-stack-remote.sh"
_err() { printf 'ERROR: %s\n' "$*" >&2; }

printf '127.0.0.1 localhost\n192.0.2.9 custom.example custom\n' >"$TEST_DIR/hosts"
fleet_stack_replace_block "$TEST_DIR/hosts" '192.0.2.1 one.example one'
fleet_stack_replace_block "$TEST_DIR/hosts" '192.0.2.2 two.example two'
grep -q '^127.0.0.1 localhost$' "$TEST_DIR/hosts"
grep -q '^192.0.2.9 custom.example custom$' "$TEST_DIR/hosts"
! grep -q 'one.example' "$TEST_DIR/hosts"
test "$(grep -c '^# BEGIN AAP-DEMO STACK$' "$TEST_DIR/hosts")" = 1
printf '# BEGIN AAP-DEMO STACK\nincomplete\n' >"$TEST_DIR/broken"
cp "$TEST_DIR/broken" "$TEST_DIR/before"
if fleet_stack_replace_block "$TEST_DIR/broken" new 2>/dev/null; then
  echo "FAIL: malformed managed block was accepted" >&2; exit 1
fi
cmp "$TEST_DIR/before" "$TEST_DIR/broken"
for bad in '999.0.0.1 bad.example bad' $'192.0.2.1 one.example one\n192.0.2.2 two.example one'; do
  if fleet_stack_validate_hosts <<<"$bad"; then
    echo "FAIL: invalid/ambiguous hosts accepted" >&2; exit 1
  fi
done

fleet_access_inventory() {
  printf '[{"index":1,"hostname":"aap-fleet-node-1","ssh_port":2201,"state":"running"},{"index":2,"hostname":"aap-fleet-node-2","ssh_port":2202,"state":"running"},{"index":3,"hostname":"aap-fleet-node-3","ssh_port":2203,"state":"stopped"}]'
}
ip() { printf '1.1.1.1 via 192.0.2.254 dev eth0 src 192.0.2.10\n'; }
kubectl() {
  case "$2" in
    nodes) printf '{"items":[{"metadata":{"name":"api.crc.testing"},"status":{"addresses":[{"type":"InternalIP","address":"192.168.127.2"}]}}]}' ;;
    routes) printf '{"items":[{"metadata":{"namespace":"aap-operator"},"spec":{"host":"aap.apps.127.0.0.1.nip.io"}}]}' ;;
    *) return 1 ;;
  esac
}
fleet_stack_ssh() {
  case "$2" in
    'sudo cat /home/admin/.ssh/id_ed25519.pub') cat >/dev/null; printf 'ssh-ed25519 AAAA admin-%s\n' "$1" ;;
    'sudo cat /etc/ssh/ssh_host_ed25519_key.pub') cat >/dev/null; printf 'ssh-ed25519 BBBB host-%s\n' "$1" ;;
    'sudo bash -s') cat >"$TEST_DIR/apply-$1"; bash -n "$TEST_DIR/apply-$1" ;;
    *) return 1 ;;
  esac
}
fleet_reconcile_stack
cmp "$TEST_DIR/apply-2201" "$TEST_DIR/apply-2202"
! test -f "$TEST_DIR/apply-2203"
# Inspect the generated payload without executing privileged machine changes.
eval "$(head -n 5 "$TEST_DIR/apply-2201" | tail -n 4)"
grep -q '192.0.2.10 aap-fleet-node-3.fleet.aap-demo.test aap-fleet-node-3' <<<"$stack_hosts"
grep -q '192.168.127.2 api.crc.testing api' <<<"$stack_hosts"
grep -q '192.0.2.10 aap.apps.127.0.0.1.nip.io aap' <<<"$stack_hosts"
grep -q 'Port 2202' <<<"$stack_config"
! grep -q 'Port 2203' <<<"$stack_config"
grep -q 'StrictHostKeyChecking yes' <<<"$stack_config"
test "$(wc -l <<<"$stack_keys")" -eq 2
grep -q 'aap-fleet-node-2.fleet.aap-demo.test ssh-ed25519 BBBB host-2202' <<<"$stack_known_hosts"
fleet_access_inventory() {
  printf '[{"index":1,"hostname":"aap-fleet-node-1","ssh_port":2201,"state":"running"}]'
}
fleet_reconcile_stack >/dev/null
eval "$(head -n 5 "$TEST_DIR/apply-2201" | tail -n 4)"
! grep -q 'aap-fleet-node-2' <<<"$stack_hosts$stack_config$stack_known_hosts"
test "$(wc -l <<<"$stack_keys")" -eq 1
kubectl() { return 1; }
rm "$TEST_DIR/apply-2201" "$TEST_DIR/apply-2202"
if fleet_reconcile_stack >/dev/null 2>&1; then
  echo "FAIL: cluster discovery failure was ignored" >&2; exit 1
fi
! test -f "$TEST_DIR/apply-2201"
kubectl() { printf '{"unexpected":"response"}'; }
if fleet_reconcile_stack >/dev/null 2>&1; then
  echo "FAIL: malformed discovery response was ignored" >&2; exit 1
fi
(
  export HOME="$TEST_DIR/home" AAP_DEMO_DIR="$TEST_DIR/state"
  source "$REPO_ROOT/addons/fleet/fleet.sh"
  _fleet_generate_ssh_key
  cp "$FLEET_DIR/ssh_key" "$TEST_DIR/original-key"
  rm "$FLEET_DIR/ssh_key.pub"
  _fleet_generate_ssh_key
  cmp "$TEST_DIR/original-key" "$FLEET_DIR/ssh_key"
  ssh-keygen -lf "$FLEET_DIR/ssh_key.pub" >/dev/null
  fleet_reconcile_running_access() { printf 'access\n' >>"$TEST_DIR/lifecycle"; }
  fleet_reconcile_stack() { printf 'stack\n' >>"$TEST_DIR/lifecycle"; }
  _fleet_check_ram() { :; }
  _fleet_next_index() { printf 1; }
  fleet_node_create() { :; }
  fleet_create_all 1 fixture >/dev/null
  test "$(cat "$TEST_DIR/lifecycle")" = $'access\nstack'
  : >"$TEST_DIR/lifecycle"
  mkdir -p "$FLEET_DIR/node-1"
  printf 'INDEX=1\n' >"$FLEET_DIR/node-1/meta"
  fleet_node_start() { :; }
  fleet_start_all >/dev/null
  test "$(cat "$TEST_DIR/lifecycle")" = $'access\nstack'
  : >"$TEST_DIR/lifecycle"
  fleet_node_delete() { :; }
  fleet_remove_by_name aap-fleet-node-1
  test "$(cat "$TEST_DIR/lifecycle")" = stack
)
echo "PASS: stack hosts and public keys reconcile idempotently, preserve local entries, and fail closed"
