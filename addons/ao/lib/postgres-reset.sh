# shellcheck shell=bash
# Empties AO's PostgreSQL for `enable ao --force` (ADR-043).

# Deletes the StatefulSet, its pod and its PVC. Returns 1 without touching the
# PVC while the old StatefulSet or pod still exists, and returns 1 if the PVC
# does not finish deleting.
ao_postgres_reset_storage() {
  local ns="$1"
  kubectl delete statefulset orchestrator-postgres -n "$ns" \
    --ignore-not-found --wait=true 2>/dev/null || true
  kubectl wait --for=delete pod/orchestrator-postgres-0 -n "$ns" \
    --timeout=180s 2>/dev/null || true
  # Check what is left rather than the exit codes above: `kubectl wait` on a
  # pod that is already gone fails on some kubectl versions.
  local left
  for left in statefulset/orchestrator-postgres pod/orchestrator-postgres-0; do
    if ! ao_postgres_resource_absent "$ns" "$left"; then
      echo "ERROR: $left is still present or could not be checked; refusing to delete its PVC." >&2
      return 1
    fi
  done
  if ao_postgres_resource_absent "$ns" pvc/data-orchestrator-postgres-0; then
    return 0
  fi
  kubectl delete pvc data-orchestrator-postgres-0 -n "$ns" --wait=false \
    2>/dev/null || true
  if ! kubectl wait --for=delete pvc/data-orchestrator-postgres-0 \
    -n "$ns" --timeout=180s 2>/dev/null; then
    echo "ERROR: PostgreSQL PVC did not finish deleting; refusing to recreate AO." >&2
    return 1
  fi
}

# Succeeds only when the API server answers that the resource does not exist.
# Any other error (API unreachable, RBAC) counts as present.
ao_postgres_resource_absent() {
  local out
  out=$(kubectl get "$2" -n "$1" --ignore-not-found -o name 2>&1) || return 1
  [ -z "$out" ]
}
