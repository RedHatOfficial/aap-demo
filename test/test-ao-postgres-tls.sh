#!/usr/bin/env bash
# Regression tests for AO PostgreSQL certificate and CA rotation (ADR-043).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAILED=0

pass() { echo "✓ $1"; }
fail() {
  echo "✗ $1"
  FAILED=1
}

# ── tls-reload sidecar ──────────────────────────────────────────────────────
# Pull the script out of the ConfigMap so the test runs what the pod runs.
awk '
  /^  tls-reload\.sh: \|$/ { on = 1; next }
  on && /^  [^ ]/ { exit }
  on { sub(/^    /, ""); print }
' "$REPO_ROOT/addons/ao/manifests/postgres.yaml" >"$TMP_DIR/tls-reload.sh"
if grep -q 'pg_reload_conf' "$TMP_DIR/tls-reload.sh"; then
  pass "tls-reload.sh is in postgres.yaml"
else
  fail "tls-reload.sh was not found in postgres.yaml"
fi

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/src" "$TMP_DIR/dst"
cat >"$TMP_DIR/bin/psql" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >>"$PSQL_LOG"
[ -z "${PSQL_FAIL:-}" ]
MOCK
chmod +x "$TMP_DIR/bin/psql"

run_reload() {
  PATH="$TMP_DIR/bin:$PATH" PSQL_LOG="$TMP_DIR/psql.log" \
    TLS_SOURCE_DIR="$TMP_DIR/src" TLS_TARGET_DIR="$TMP_DIR/dst" \
    TLS_RELOAD_INTERVAL=0 TLS_RELOAD_ONCE=1 bash "$TMP_DIR/tls-reload.sh"
}

printf 'cert-1\n' >"$TMP_DIR/src/tls.crt"
printf 'key-1\n' >"$TMP_DIR/src/tls.key"
cp "$TMP_DIR/src/tls.crt" "$TMP_DIR/src/tls.key" "$TMP_DIR/dst/"
: >"$TMP_DIR/psql.log"
run_reload >/dev/null
if [ ! -s "$TMP_DIR/psql.log" ]; then
  pass "an unchanged certificate does not reload PostgreSQL"
else
  fail "an unchanged certificate reloaded PostgreSQL"
fi

printf 'cert-2\n' >"$TMP_DIR/src/tls.crt"
printf 'key-2\n' >"$TMP_DIR/src/tls.key"
output=$(run_reload)
if [ "$(<"$TMP_DIR/dst/tls.crt")" = "cert-2" ] && [ "$(<"$TMP_DIR/dst/tls.key")" = "key-2" ]; then
  pass "a renewed certificate and key are copied into place"
else
  fail "the renewed certificate was not copied"
fi
if [ "$(ls -l "$TMP_DIR/dst/tls.key" | cut -c1-10)" = "-rw-------" ]; then
  pass "the copied key is mode 0600"
else
  fail "the copied key is not mode 0600"
fi
if grep -q 'pg_reload_conf' "$TMP_DIR/psql.log" && grep -q '127.0.0.1' "$TMP_DIR/psql.log" \
  && [[ "$output" == *"Reloaded PostgreSQL"* ]]; then
  pass "a renewed certificate reloads PostgreSQL over loopback"
else
  fail "a renewed certificate did not reload PostgreSQL"
fi
leftovers=("$TMP_DIR"/dst/.*.new)
if [ ! -e "${leftovers[0]}" ]; then
  pass "no temporary files are left behind"
else
  fail "temporary files were left in the target directory"
fi

# ── CA Secret sync ──────────────────────────────────────────────────────────
BUNDLE_CA=""
STORED_CA=""
RESTARTED=()
# kubectl create runs on the left of a pipe, in a subshell, so it records here.
APPLIED_FILE="$TMP_DIR/applied"
applied() { cat "$APPLIED_FILE" 2>/dev/null; }

kubectl() {
  case "$*" in
    "get configmap orchestrator-postgres-ca-bundle"*) printf '%s' "$BUNDLE_CA" ;;
    "get secret orchestrator-postgres-ca"*)
      [ -n "$STORED_CA" ] || return 1
      printf '%s' "$STORED_CA" | base64
      ;;
    "create secret generic orchestrator-postgres-ca"*)
      local arg
      for arg in "$@"; do
        case "$arg" in --from-literal=ca.crt=*) printf '%s' "${arg#--from-literal=ca.crt=}" >"$APPLIED_FILE" ;; esac
      done
      echo "manifest"
      ;;
    "apply -f -") cat >/dev/null ;;
    "get deployment"*)
      printf '%s\n' \
        deployment.apps/automation-orchestrator-backend \
        deployment.apps/automation-orchestrator-temporal \
        deployment.apps/automation-orchestrator-operator-controller-manager \
        deployment.apps/unrelated
      ;;
    "rollout restart"*) RESTARTED+=("$3") ;;
    *) return 1 ;;
  esac
}

# shellcheck source=../addons/ao/lib/postgres-tls.sh
source "$REPO_ROOT/addons/ao/lib/postgres-tls.sh"

sync_rc() {
  local rc=0
  ao_postgres_ca_sync automation-orchestrator || rc=$?
  echo "$rc"
}

BUNDLE_CA="" STORED_CA=""
rm -f "$APPLIED_FILE"
[ "$(sync_rc)" = 2 ] && pass "no published CA returns 2" || fail "no published CA did not return 2"

BUNDLE_CA="ca-1" STORED_CA=""
rm -f "$APPLIED_FILE"
rc=$(sync_rc)
if [ "$rc" = 0 ] && [ "$(applied)" = "ca-1" ]; then
  pass "a missing CA Secret is written"
else
  fail "a missing CA Secret was not written (rc=$rc)"
fi

BUNDLE_CA="ca-1" STORED_CA="ca-1"
rm -f "$APPLIED_FILE"
rc=$(sync_rc)
if [ "$rc" = 1 ] && [ -z "$(applied)" ]; then
  pass "a matching CA Secret is left alone"
else
  fail "a matching CA Secret was rewritten (rc=$rc)"
fi

BUNDLE_CA="ca-2" STORED_CA="ca-1"
rm -f "$APPLIED_FILE"
rc=$(sync_rc)
if [ "$rc" = 0 ] && [ "$(applied)" = "ca-2" ]; then
  pass "a rotated CA is copied into the Secret"
else
  fail "a rotated CA was not copied (rc=$rc)"
fi

RESTARTED=()
ao_restart_postgres_clients automation-orchestrator
if [ "${RESTARTED[*]}" = "deployment.apps/automation-orchestrator-backend deployment.apps/automation-orchestrator-temporal" ]; then
  pass "AO's workloads restart and the operator does not"
else
  fail "unexpected restarts: ${RESTARTED[*]}"
fi

exit "$FAILED"
