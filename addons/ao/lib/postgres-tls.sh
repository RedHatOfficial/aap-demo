# shellcheck shell=bash
# Keeps AO's copy of the PostgreSQL CA in step with service-ca (ADR-043).
#
# service-ca publishes its CA in the orchestrator-postgres-ca-bundle ConfigMap
# and updates it when the CA rotates. The AutomationOrchestrator CR can only
# name a Secret, so aap-demo copies the CA into orchestrator-postgres-ca. AO's
# pods read that Secret when they start.

# Prints the CA that service-ca injected into the bundle ConfigMap.
ao_postgres_bundle_ca() {
  kubectl get configmap orchestrator-postgres-ca-bundle -n "$1" \
    -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null || true
}

# Copies the bundle CA into the orchestrator-postgres-ca Secret.
# Returns 0 when the Secret changed, 1 when it already matched, 2 when
# service-ca has not published a CA yet, and 3 when the write failed.
ao_postgres_ca_sync() {
  local _ns="$1" _ca _current
  _ca=$(ao_postgres_bundle_ca "$_ns")
  [ -n "$_ca" ] || return 2
  _current=$(kubectl get secret orchestrator-postgres-ca -n "$_ns" \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [ "$_current" != "$_ca" ] || return 1
  kubectl create secret generic orchestrator-postgres-ca -n "$_ns" \
    --from-literal=ca.crt="$_ca" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null || return 3
  return 0
}

# Restarts the AO workloads, which read the CA Secret only when they start.
# The operator does not connect to PostgreSQL and is left running.
ao_restart_postgres_clients() {
  local _ns="$1" _deployment
  for _deployment in $(kubectl get deployment -n "$_ns" -o name 2>/dev/null); do
    case "$_deployment" in
      *-operator-controller-manager) ;;
      */automation-orchestrator-*)
        kubectl rollout restart "$_deployment" -n "$_ns" >/dev/null || return 1
        ;;
    esac
  done
}
