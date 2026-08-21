#!/usr/bin/env bash
# Shared OLM catalog signature policy helpers (MicroShift 4.22+).
# Used by aap-demo deploy and AO addon catalog waits.

if [ -n "${_OLM_CATALOG_SIGNATURE_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_OLM_CATALOG_SIGNATURE_LOADED=1

_OLM_CATALOG_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_catalog_hat_idx=0
_catalog_hat() {
  _catalog_hat_idx=$(((_catalog_hat_idx + 1) % 2))
  case $_catalog_hat_idx in
    0) printf '⏳' ;;
    1) printf '⌛' ;;
  esac
}

resolve_aap_ocp_version() {
  if [ -n "${AAP_OCP_VERSION:-}" ]; then
    echo "$AAP_OCP_VERSION"
    return 0
  fi
  local _crc_ocp_version _cluster_version
  _crc_ocp_version=$(crc status -o json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('openshiftVersion',''))" 2>/dev/null \
    || true)
  if [[ "$_crc_ocp_version" =~ ^([0-9]+\.[0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  _cluster_version=$(kubectl get clusterversion version \
    -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "")
  if [[ "$_cluster_version" =~ ^([0-9]+\.[0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  echo "4.20"
}

needs_signature_policy_relaxation() {
  local _ocp_version _major _minor
  _ocp_version=$(resolve_aap_ocp_version)
  _major="${_ocp_version%%.*}"
  _minor="${_ocp_version#*.}"
  if [ "$_major" -lt 4 ]; then
    return 1
  fi
  if [ "$_major" -eq 4 ] && [ "$_minor" -lt 22 ]; then
    return 1
  fi
  return 0
}

_reload_crio_on_crc_vm() {
  _ensure_crc_ssh_ready || return 1
  ssh -p "$CRC_SSH_PORT" "${CRC_SSH_OPTS[@]}" core@127.0.0.1 \
    'sudo systemctl reload crio' 2>/dev/null \
    && echo "  ✓ Reloaded CRI-O" \
    || echo "  WARNING: CRI-O reload failed — restart CRC if catalog pull still fails" >&2
}

_ensure_crc_ssh_ready() {
  # shellcheck source=includes/infra-crc.sh
  source "${_OLM_CATALOG_REPO_ROOT}/includes/infra-crc.sh" 2>/dev/null || return 1
  refresh_crc_ssh_config || return 1
}

maybe_relax_redhat_registry_signature_policy() {
  # MicroShift 4.22+ requires GPG signatures for registry.redhat.io; the operator
  # index image fails verification. Demo-only: relax policy on the CRC VM.
  # Optional arg 1: force CRI-O reload even when policy.json is already relaxed.
  local _force_crio_reload="${1:-0}"
  if ! needs_signature_policy_relaxation; then
    return 0
  fi
  if ! _ensure_crc_ssh_ready; then
    echo "  WARNING: MicroShift 4.22+ blocks unsigned registry.redhat.io images." >&2
    echo "  Ensure CRC is running (crc start) and SSH key exists under ~/.crc/machines/crc/." >&2
    echo "  Test: aap-demo ssh" >&2
    return 1
  fi
  local _relax_output
  _relax_output=$(ssh -p "$CRC_SSH_PORT" "${CRC_SSH_OPTS[@]}" core@127.0.0.1 'sudo python3 -c "
import json
p = \"/etc/containers/policy.json\"
with open(p) as f: d = json.load(f)
docker = d.setdefault(\"transports\", {}).setdefault(\"docker\", {})
reg = docker.get(\"registry.redhat.io\", [])
if not reg or reg[0].get(\"type\") != \"insecureAcceptAnything\":
    docker[\"registry.redhat.io\"] = [{\"type\": \"insecureAcceptAnything\"}]
    with open(p, \"w\") as f: json.dump(d, f, indent=4)
    print(\"CHANGED\")
else:
    print(\"UNCHANGED\")
"') || {
    echo "  WARNING: Could not relax signature policy via SSH (is CRC running? port ${CRC_SSH_PORT} open?)" >&2
    return 1
  }
  case "$_relax_output" in
    CHANGED)
      echo "  ✓ Relaxed container signature policy (MicroShift 4.22+)"
      _reload_crio_on_crc_vm || true
      ;;
    UNCHANGED)
      echo "  Container signature policy already relaxed"
      if [ "$_force_crio_reload" = "1" ]; then
        _reload_crio_on_crc_vm || true
      fi
      ;;
    *)
      echo "  WARNING: Unexpected signature policy response from CRC VM" >&2
      return 1
      ;;
  esac
}

catalog_pod_container_waiting() {
  local _catalog_ns="$1"
  kubectl get pods -n "$_catalog_ns" -l olm.catalogSource=redhat-operators \
    -o jsonpath='{range .items[0].status.containerStatuses[*].state.waiting}{.reason}{": "}{.message}{"\n"}{end}' \
    2>/dev/null || echo ""
}

catalog_pod_has_image_pull_backoff() {
  local _catalog_ns="$1"
  local _pod_status _waiting
  _pod_status=$(kubectl get pods -n "$_catalog_ns" -l olm.catalogSource=redhat-operators \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  if [ "$_pod_status" = "ImagePullBackOff" ] || [ "$_pod_status" = "ErrImagePull" ]; then
    return 0
  fi
  _waiting=$(catalog_pod_container_waiting "$_catalog_ns")
  echo "$_waiting" | grep -qE 'ImagePullBackOff|ErrImagePull|SignatureValidationFailed'
}

catalog_pod_has_signature_pull_failure() {
  local _catalog_ns="$1"
  local _pod _waiting _phase
  _pod=$(kubectl get pods -n "$_catalog_ns" -l olm.catalogSource=redhat-operators \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -z "$_pod" ]; then
    return 1
  fi
  _phase=$(kubectl get pod "$_pod" -n "$_catalog_ns" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  _waiting=$(catalog_pod_container_waiting "$_catalog_ns")
  if echo "$_waiting" | grep -q "SignatureValidationFailed"; then
    return 0
  fi
  if catalog_pod_has_image_pull_backoff "$_catalog_ns"; then
    kubectl get events -n "$_catalog_ns" --field-selector "involvedObject.name=${_pod}" \
      2>/dev/null | grep -q "SignatureValidationFailed"
    return $?
  fi
  return 1
}

report_catalog_signature_failure() {
  echo "ERROR: redhat-operator-index cannot be pulled (SignatureValidationFailed)." >&2
  echo "  MicroShift 4.22+ requires GPG signatures; the index image fails that check." >&2
  echo "  Fix (demo-only): aap-demo deploy re-applies signature policy and restarts the catalog pod." >&2
  echo "  Ensure CRC is running with a valid ~/.crc/machines/crc SSH key." >&2
}

catalog_pod_wait_reason() {
  local _catalog_ns="$1"
  kubectl get pods -n "$_catalog_ns" -l olm.catalogSource=redhat-operators \
    -o jsonpath='{range .items[0].status.conditions[?(@.type=="PodScheduled")]}{.reason}{": "}{.message}{"\n"}{end}{range .items[0].status.containerStatuses[*].state.waiting}{.reason}{": "}{.message}{"\n"}{end}' \
    2>/dev/null | head -3
}

maybe_recover_catalog_pull() {
  local _catalog_ns="$1"
  local _fix_signature="${2:-0}"
  if [ "$_fix_signature" = "1" ] && needs_signature_policy_relaxation; then
    echo "  Applying MicroShift 4.22+ signature policy fix..."
    if ! maybe_relax_redhat_registry_signature_policy 1; then
      return 1
    fi
  fi
  echo "  Restarting catalog pod..."
  kubectl delete pod -n "$_catalog_ns" -l olm.catalogSource=redhat-operators \
    --wait=false >/dev/null 2>&1 || true
}

ensure_catalog_signature_policy() {
  if ! needs_signature_policy_relaxation; then
    return 0
  fi
  echo "  Ensuring MicroShift 4.22+ signature policy allows registry.redhat.io..."
  maybe_relax_redhat_registry_signature_policy || return 1
}

catalog_pod_is_pulling() {
  local _status="$1"
  local _pod_status="$2"
  case "$_status" in
    TRANSIENT_FAILURE | CONNECTING | "") ;;
    Pending) ;;
    *) return 1 ;;
  esac
  case "$_pod_status" in
    Pending | ContainerCreating | Running) return 0 ;;
    *) return 1 ;;
  esac
}

catalog_wait_timeout_seconds() {
  printf '%s' "${AAP_CATALOG_TIMEOUT:-${AO_CATALOG_TIMEOUT:-600}}"
}

wait_for_catalog_ready() {
  local _catalog_ns="$1"
  local _i _status _pod_status _timeout _pod_restart_attempted _signature_fix_attempted
  _timeout="$(catalog_wait_timeout_seconds)"
  _pod_restart_attempted=0
  _signature_fix_attempted=0
  for _i in $(seq 1 "$((_timeout / 5))"); do
    _status=$(kubectl get catalogsource redhat-operators -n "$_catalog_ns" \
      -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
    if [ "$_status" = "READY" ]; then
      echo ""
      return 0
    fi
    _pod_status=$(kubectl get pods -n "$_catalog_ns" -l olm.catalogSource=redhat-operators \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    # Pod phase stays Pending while the container reports ImagePullBackOff.
    if catalog_pod_has_image_pull_backoff "$_catalog_ns"; then
      if catalog_pod_has_signature_pull_failure "$_catalog_ns"; then
        if [ "$_signature_fix_attempted" -eq 0 ]; then
          if maybe_recover_catalog_pull "$_catalog_ns" 1; then
            _signature_fix_attempted=1
            _pod_restart_attempted=1
            sleep 15
            continue
          fi
        fi
        echo ""
        report_catalog_signature_failure
        return 1
      fi
      if [ "$_pod_restart_attempted" -eq 0 ]; then
        maybe_recover_catalog_pull "$_catalog_ns"
        _pod_restart_attempted=1
        sleep 15
        continue
      fi
      echo ""
      _reason=$(catalog_pod_wait_reason "$_catalog_ns")
      echo "ERROR: Catalog pod cannot pull operator index image." >&2
      if [ -n "$_reason" ]; then
        echo "  Pod detail:" >&2
        echo "$_reason" | sed 's/^/    /' >&2
      fi
      return 1
    fi
    if catalog_pod_is_pulling "$_status" "$_pod_status"; then
      printf "\r  %s Pulling catalog image... (%ds / %ds)    " \
        "$(_catalog_hat)" "$((_i * 5))" "$_timeout"
    else
      printf "\r  %s CatalogSource: %-18s | pod: %-16s (%ds)    " \
        "$(_catalog_hat)" "${_status:-Pending}" "$_pod_status" "$((_i * 5))"
    fi
    sleep 5
  done
  echo ""
  return 1
}
