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

# ── tls-reload.sh (liveness probe) ──────────────────────────────────────────
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
    bash "$TMP_DIR/tls-reload.sh"
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
output=$(PSQL_FAIL=1 run_reload)
if [ -e "$TMP_DIR/dst/.reload-pending" ] && [ -z "$output" ]; then
  pass "a failed reload stays pending"
else
  fail "a failed reload was not kept pending"
fi
: >"$TMP_DIR/psql.log"
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
if grep -q 'pg_reload_conf' "$TMP_DIR/psql.log" && ! grep -q -- '-h' "$TMP_DIR/psql.log" \
  && [[ "$output" == *"Reloaded PostgreSQL"* ]] && [ ! -e "$TMP_DIR/dst/.reload-pending" ]; then
  pass "the pending reload runs over the local socket on the next probe"
else
  fail "the pending reload did not run over the local socket"
fi
leftovers=("$TMP_DIR"/dst/.*.new)
if [ ! -e "${leftovers[0]}" ]; then
  pass "no temporary files are left behind"
else
  fail "temporary files were left in the target directory"
fi

# ── pg_hba.conf ─────────────────────────────────────────────────────────────
hba=$(awk '
  /^  pg_hba\.conf: \|$/ { on = 1; next }
  on && /^  [^ ]/ { exit }
  on { print }
' "$REPO_ROOT/addons/ao/manifests/postgres.yaml")
if ! grep -E '^ *host +' <<<"$hba" | grep -q trust; then
  pass "no TCP connection is trusted, loopback included"
else
  fail "pg_hba.conf trusts a TCP connection"
fi
if grep -qE '^ *hostnossl +all +all +all +reject' <<<"$hba"; then
  pass "plain TCP is rejected"
else
  fail "plain TCP is not rejected"
fi

# ── CA Secret sync ──────────────────────────────────────────────────────────
BUNDLE_CA=""
STORED_CA=""
LIST_FAIL=""
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
      [ -z "${LIST_FAIL:-}" ] || return 1
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

RESTARTED=()
LIST_FAIL=1
if ! ao_restart_postgres_clients automation-orchestrator && [ "${#RESTARTED[@]}" -eq 0 ]; then
  pass "a failed deployment list is reported, not treated as nothing to restart"
else
  fail "a failed deployment list was treated as success"
fi
LIST_FAIL=""

# ── --force storage reset ───────────────────────────────────────────────────
# PRESENT lists what `kubectl get` still finds; GET_ERROR makes `get` fail.
PRESENT=""
GET_ERROR=""
CALLS_FILE="$TMP_DIR/reset-calls"
kubectl() {
  echo "$*" >>"$CALLS_FILE"
  case "$*" in
    "delete statefulset"*) [ -z "${DELETE_FAIL:-}" ] ;;
    "wait --for=delete pod/"*) [ -z "${DELETE_FAIL:-}" ] ;;
    "get "*)
      [ -z "$GET_ERROR" ] || return 1
      case " $PRESENT " in *" $2 "*) echo "$2" ;; esac
      ;;
    "delete pvc"*) PRESENT="${PRESENT//pvc\/data-orchestrator-postgres-0/}" ;;
    "wait --for=delete pvc/"*) [ -z "${PVC_STUCK:-}" ] ;;
    *) return 1 ;;
  esac
}

# shellcheck source=../addons/ao/lib/postgres-reset.sh
source "$REPO_ROOT/addons/ao/lib/postgres-reset.sh"

reset_case() {
  : >"$CALLS_FILE"
  local rc=0
  ao_postgres_reset_storage automation-orchestrator 2>/dev/null || rc=$?
  echo "$rc"
}

PRESENT="pvc/data-orchestrator-postgres-0"
rc=$(reset_case)
if [ "$rc" = 0 ] && grep -q '^delete pvc data-orchestrator-postgres-0' "$CALLS_FILE"; then
  pass "--force deletes the PVC once the StatefulSet and pod are gone"
else
  fail "--force did not delete the PVC after a clean delete (rc=$rc)"
fi

PRESENT="pod/orchestrator-postgres-0 pvc/data-orchestrator-postgres-0"
rc=$(DELETE_FAIL=1 reset_case)
if [ "$rc" = 1 ] && ! grep -q '^delete pvc' "$CALLS_FILE"; then
  pass "--force stops while the old pod is still running"
else
  fail "--force went on with the old pod present (rc=$rc)"
fi

PRESENT="statefulset/orchestrator-postgres pvc/data-orchestrator-postgres-0"
rc=$(DELETE_FAIL=1 reset_case)
if [ "$rc" = 1 ] && ! grep -q '^delete pvc' "$CALLS_FILE"; then
  pass "--force stops while the old StatefulSet is still present"
else
  fail "--force went on with the old StatefulSet present (rc=$rc)"
fi

PRESENT="pvc/data-orchestrator-postgres-0"
rc=$(GET_ERROR=1 reset_case)
if [ "$rc" = 1 ] && ! grep -q '^delete pvc' "$CALLS_FILE"; then
  pass "--force stops when it cannot check what is left"
else
  fail "--force went on without confirming the pod was gone (rc=$rc)"
fi

PRESENT="pvc/data-orchestrator-postgres-0"
rc=$(PVC_STUCK=1 reset_case)
if [ "$rc" = 1 ]; then
  pass "--force stops when the PVC does not finish deleting"
else
  fail "--force went on with the PVC still deleting (rc=$rc)"
fi

exit "$FAILED"
