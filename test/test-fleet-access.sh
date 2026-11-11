#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="$TEST_DIR/home"
export AAP_DEMO_DIR="$HOME/custom state"
export AAP_DEMO_VAULT_FILE="$HOME/.ansible/conf/env.yml"
export AAP_DEMO_VAULT_PASSWORD_FILE="$HOME/.ansible/conf/.vaultpass.txt"
mkdir -p "$AAP_DEMO_DIR/fleet/node-1" "$TEST_DIR/bin"
cat >"$AAP_DEMO_DIR/fleet/node-1/meta" <<EOF
INDEX=1
PORT=2201
HOSTNAME=aap-fleet-node-1
PID=$$
EOF
export TEST_SSH_SCRIPT="$TEST_DIR/remote-script"
export TEST_SSH_ARGS="$TEST_DIR/ssh-args"
cat >"$TEST_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_SSH_ARGS"
case "$*" in
  *'bash -s') cat >"$TEST_SSH_SCRIPT" ;;
  *) printf '10.0.2.15\n' ;;
esac
EOF
chmod +x "$TEST_DIR/bin/ssh"
export PATH="$TEST_DIR/bin:$PATH"
source "$REPO_ROOT/includes/fleet-access.sh"

fleet_reconcile_access 1 >"$TEST_DIR/output"
password=$(fleet_admin_password 1)
test -n "$password"
cp "$AAP_DEMO_VAULT_PASSWORD_FILE" "$TEST_DIR/shared-password"
fleet_reconcile_access 1 >>"$TEST_DIR/output"
test "$(fleet_admin_password 1)" = "$password"
cmp "$AAP_DEMO_VAULT_PASSWORD_FILE" "$TEST_DIR/shared-password"
grep -q 'PasswordAuthentication yes' "$TEST_SSH_SCRIPT"
grep -q 'sudo chpasswd -e' "$TEST_SSH_SCRIPT"
grep -Fq 'admin     ALL=(ALL)       ALL' "$TEST_SSH_SCRIPT"
if grep -q NOPASSWD "$TEST_SSH_SCRIPT"; then
  echo "FAIL: admin reconciliation enables passwordless sudo" >&2; exit 1
fi
grep -q 'sudo visudo -cf' "$TEST_SSH_SCRIPT"
grep -q 'sudo -u admin ssh-keygen' "$TEST_SSH_SCRIPT"
grep -q 'StrictHostKeyChecking=accept-new' "$TEST_SSH_ARGS"
if grep -Fq "$password" "$TEST_SSH_ARGS" "$TEST_SSH_SCRIPT" "$TEST_DIR/output"; then
  echo "FAIL: plaintext Fleet password leaked" >&2
  exit 1
fi
inventory=$(fleet_access_inventory omit)
jq -e '.[0] | .state == "running" and .username == "admin" and .password == null
  and .ssh_host == "127.0.0.1" and .ssh_port == 2201 and .guest_ip == "10.0.2.15"' <<<"$inventory" >/dev/null
test "$(fleet_access_inventory include | jq -r '.[0].password')" = "$password"
test "$(fleet_access_inventory redact | jq -r '.[0].password')" = '******'
SCRIPT_DIR="$REPO_ROOT"
SHOW_SECRETS=false
eval "$(sed -n '/^_show_fleet_status()/,/^}$/p' "$REPO_ROOT/includes/cmd-status.sh")"
_show_fleet_status >"$TEST_DIR/status"
if grep -Fq "$password" "$TEST_DIR/status"; then
  echo "FAIL: default Fleet status exposed a password" >&2; exit 1
fi
SHOW_SECRETS=true
_show_fleet_status >"$TEST_DIR/secret-status"
grep -Fq "$password" "$TEST_DIR/secret-status"
grep -q 'admin@127.0.0.1' "$TEST_DIR/secret-status"
grep -q 'Guest IP: 10.0.2.15' "$TEST_DIR/secret-status"
if fleet_reconcile_access '../2' >/dev/null 2>&1; then
  echo "FAIL: invalid node index was accepted" >&2
  exit 1
fi
sed 's/^PID=.*/PID=/' "$AAP_DEMO_DIR/fleet/node-1/meta" >"$TEST_DIR/stopped-meta"
mv "$TEST_DIR/stopped-meta" "$AAP_DEMO_DIR/fleet/node-1/meta"
fleet_reconcile_existing_inventory >"$TEST_DIR/stopped-output"
grep -q 'Fleet nodes are stopped' "$TEST_DIR/stopped-output"
fleet_reconcile_access() { printf '%s\n' "$1" >>"$TEST_DIR/reconciled"; }
fleet_reconcile_running_access
test ! -f "$TEST_DIR/reconciled"
mkdir -p "$AAP_DEMO_DIR/fleet/node-2"
printf 'INDEX=2\nPID=%s\n' "$$" >"$AAP_DEMO_DIR/fleet/node-2/meta"
fleet_reconcile_running_access
test "$(cat "$TEST_DIR/reconciled")" = 2
echo "PASS: Fleet admin access is Vault-backed, repeatable, and redacted by default"
