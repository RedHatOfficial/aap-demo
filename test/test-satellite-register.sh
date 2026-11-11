#!/usr/bin/env bash
# Regression tests for the Satellite VM registration stage in
# satellite-lab/build-and-configure.sh.
#
# The kickstart %post cannot register with RHSM reliably (no TTY to debug auth
# failures; a bad credential hangs the install silently), so registration runs
# post-boot over SSH. These tests pin the fallback order:
#   existing registration -> existing cert access -> activation key ->
#   username/password -> host entitlement certs (the 00a-fetch-rhel-iso.sh
#   CDN cert-auth pattern).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_SCRIPT="${REPO_ROOT}/satellite-lab/build-and-configure.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- Extract the functions under test ---------------------------------------
# build-and-configure.sh runs main() at the bottom; source only the stage
# functions by evaluating everything up to (but not including) the next stage.
functions=$(sed -n '/^# Register the VM with RHSM over SSH/,/^_stage_installer() {/p' "$BUILD_SCRIPT" | sed '$d')
printf '%s\n' "$functions" | grep -q '_stage_register()' \
  || fail "_stage_register is defined"
printf '%s\n' "$functions" | grep -q '_stage_repos()' \
  || fail "_stage_repos is defined"
printf '%s\n' "$functions" | grep -q '_stage_register_host_certs()' \
  || fail "_stage_register_host_certs is defined"

# --- Mock harness -------------------------------------------------------------
LOG="$TEST_DIR/calls.log"
: >"$LOG"

SAT_SSH_LOG="$LOG"
SAT_SCP_LOG="$LOG"

# shellcheck disable=SC2317
_err() { printf 'ERROR: %s\n' "$*" >>"$LOG"; }
# shellcheck disable=SC2317
_log() { printf '%s\n' "$*" >>"$LOG"; }

SAT_IP=192.0.2.10
VIRSH=true

# Vault values the tests control.
VAULT_RHSM_USER=""
VAULT_RHSM_PASS=""
VAULT_RHSM_ORG=""
VAULT_RHSM_AK=""
# shellcheck disable=SC2317
_vault_val() {
  case "$1" in
    RHSM_USERNAME) printf '%s' "$VAULT_RHSM_USER" ;;
    RHSM_PASSWORD) printf '%s' "$VAULT_RHSM_PASS" ;;
    RHSM_ORG_ID) printf '%s' "$VAULT_RHSM_ORG" ;;
    RHSM_ACTIVATION_KEY) printf '%s' "$VAULT_RHSM_AK" ;;
  esac
}

# Behavior toggles for the ssh mock (exported for the mock script).
export SSH_REGISTERED=false
export SSH_SAT_VISIBLE=false
export SSH_REGISTER_OK=false

mkdir -p "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/sat-ssh-mock" <<'MOCK'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >>"$SAT_SSH_LOG"
remote="$*"
case "$remote" in
  "subscription-manager identity >/dev/null 2>&1")
    [ "$SSH_REGISTERED" = true ] ;;
  "dnf list satellite >/dev/null 2>&1")
    [ "$SSH_SAT_VISIBLE" = true ] ;;
  subscription-manager\ register*)
    [ "$SSH_REGISTER_OK" = true ] ;;
  subscription-manager\ repos*)
    [ "$SSH_REGISTER_OK" = true ] || [ "$SSH_SAT_VISIBLE" = true ] || [ "$SSH_REGISTERED" = true ] ;;
  *"dnf clean all"*"dnf list satellite"*)
    [ "$SSH_SAT_VISIBLE" = true ] || [ "$SSH_REGISTERED" = true ] || [ "$SSH_REGISTER_OK" = true ] ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/sat-ssh-mock"

cat >"$TEST_DIR/bin/sat-scp-mock" <<'MOCK'
#!/usr/bin/env bash
printf 'scp %s\n' "$*" >>"$SAT_SCP_LOG"
MOCK
chmod +x "$TEST_DIR/bin/sat-scp-mock"

SAT_SSH="$TEST_DIR/bin/sat-ssh-mock"
SAT_SCP="$TEST_DIR/bin/sat-scp-mock"
export SAT_SSH_LOG="$LOG" SAT_SCP_LOG="$LOG"

eval "$functions"

# --- Test 1: already registered short-circuits -------------------------------
: >"$LOG"
SSH_REGISTERED=true
_stage_register
grep -q "already registered" "$LOG" || fail "registered VM short-circuits"
if grep -q "subscription-manager register" "$LOG"; then
  fail "registered VM must not re-register"
fi
echo "PASS: already-registered VM skips registration"

# --- Test 2: existing cert access short-circuits ------------------------------
: >"$LOG"
SSH_REGISTERED=false
SSH_SAT_VISIBLE=true
_stage_register
grep -q "entitlement certs present" "$LOG" || fail "cert-accessible VM short-circuits"
if grep -q "subscription-manager register" "$LOG"; then
  fail "VM with working cert access must not re-register"
fi
echo "PASS: VM with Satellite package access skips registration"

# --- Test 3: activation key is preferred --------------------------------------
: >"$LOG"
SSH_SAT_VISIBLE=false
SSH_REGISTER_OK=true
VAULT_RHSM_USER="user@example.com"
VAULT_RHSM_PASS="secret"
VAULT_RHSM_ORG="123456"
VAULT_RHSM_AK="my-ak"
_stage_register
grep -q "activationkey='my-ak'" "$LOG" || fail "activation key is used when set"
if grep -q "username='user@example.com'" "$LOG"; then
  fail "username/password must not be used when an activation key is set"
fi
echo "PASS: activation key is preferred over username/password"

# --- Test 4: username/password falls back to host certs on failure ------------
: >"$LOG"
SSH_REGISTER_OK=false
VAULT_RHSM_AK=""
VAULT_RHSM_ORG=""
# The fallback's repo-enable step fails in this mock (no real certs), which is
# fine — we only assert the fallback was attempted.
_stage_register || true
grep -q "username='user@example.com'" "$LOG" \
  || fail "username/password is attempted when no activation key"
grep -q "host entitlement" "$LOG" \
  || fail "failed username/password registration falls back to host certs"
echo "PASS: failed username/password registration falls back to host certs"

# --- Test 5: no credentials at all goes straight to host certs -----------------
: >"$LOG"
VAULT_RHSM_USER=""
VAULT_RHSM_PASS=""
_stage_register || true
if grep -q "subscription-manager register" "$LOG"; then
  fail "registration is skipped when no credentials exist"
fi
grep -q "host entitlement" "$LOG" || fail "host cert fallback runs without credentials"
echo "PASS: host cert fallback runs when no Vault credentials exist"

# --- Test 6: host cert stage fails clearly without certs -----------------------
: >"$LOG"
# Point the cert glob at an empty directory.
mkdir -p "$TEST_DIR/empty-pki"
eval "$(printf '%s\n' "$functions" | sed 's|/etc/pki/entitlement|'"$TEST_DIR"'/empty-pki|g')"
if _stage_register_host_certs 2>/dev/null; then
  fail "host cert stage fails when no entitlement certs exist"
fi
grep -q "no host entitlement cert" "$LOG" \
  || fail "missing host certs produce an actionable error"
echo "PASS: missing host entitlement certs fail with guidance"

echo "All Satellite registration stage tests passed"
