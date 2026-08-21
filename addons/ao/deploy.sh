#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../includes/aap-demo-paths.sh
source "${SCRIPT_DIR}/../../includes/aap-demo-paths.sh"
KUBECONFIG_PATH="$(aap_demo_resolve_kubeconfig "${KUBECONFIG:-}")"
export KUBECONFIG="$KUBECONFIG_PATH"

# Deploy Automation Orchestrator (GA) to aap-demo.
#
# Instance manifests come from `aapctl install ao --dry-run` (GitOps path):
#   https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-generate_aapctl_manifests_for_gitops
#
# MicroShift still needs a CatalogSource in the AO namespace (OLM cannot
# resolve openshift-marketplace). CNPG is installed from the upstream
# manifest because certified-operators is not on MicroShift.
#
# Prerequisites:
#   1. aap-demo cluster with OLM (aap-demo deploy)
#   2. Valid registry.redhat.io pull secret
#
# aapctl is NOT required at install time (manifests are checked in under manifests/).
# Optional: aapctl for disable cleanup and for scripts/generate-manifests.sh refresh.
#
# Usage:
#   ./deploy.sh                    # Install Automation Orchestrator
#   ./deploy.sh --delete           # Remove Automation Orchestrator
#   ./deploy.sh --force            # Reinstall even if already running
#   ./deploy.sh --refresh-catalog  # Re-pull redhat-operator-index before install
#   AO_REFRESH_CATALOG=1 ./deploy.sh
#   AO_INDEX_IMAGE=registry.redhat.io/redhat/redhat-operator-index:v4.22-... ./deploy.sh

NAMESPACE="automation-orchestrator"
AAP_NAMESPACE="${AAP_DEMO_NAMESPACE:-aap-operator}"
AO_STATE_FILE="${AO_STATE_FILE:-$HOME/.aap-demo/ao-state}"
if [ ! -f "$AO_STATE_FILE" ] && [ -f "$HOME/.aap-demo/ao-eap-state" ]; then
  AO_STATE_FILE="$HOME/.aap-demo/ao-eap-state"
fi
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
REPO_ROOT="${SCRIPT_DIR}/../.."
CATALOG_SOURCE_TEMPLATE="${REPO_ROOT}/config/olm/catalogsource.yaml"
AO_FALLBACK_INDEX_IMAGE="${AO_FALLBACK_INDEX_IMAGE:-registry.redhat.io/redhat/redhat-operator-index:v4.22-automation-orchestrator-operator-early-access-1787151066}"
AO_ACTIVE_INDEX_IMAGE=""
AO_INDEX_FALLBACK_USED=0

if [ -z "${AO_STORAGE_CLASS:-}" ]; then
  if kubectl get sc nfs-local-rwx &>/dev/null 2>&1; then
    STORAGE_CLASS="nfs-local-rwx"
  elif kubectl get sc topolvm-provisioner &>/dev/null 2>&1; then
    STORAGE_CLASS="topolvm-provisioner"
  else
    echo "ERROR: No suitable StorageClass found (expected nfs-local-rwx or topolvm-provisioner)"
    echo "Run 'aap-demo create' to provision storage, or set AO_STORAGE_CLASS."
    exit 1
  fi
else
  STORAGE_CLASS="$AO_STORAGE_CLASS"
fi

ACTION="${1:-deploy}"
FORCE="${FORCE:-}"
REFRESH_CATALOG="${AO_REFRESH_CATALOG:-}"
for _arg in "$@"; do
  case "$_arg" in
    --force) FORCE=1 ;;
    --refresh-catalog) REFRESH_CATALOG=1 ;;
  esac
done

_HAT_IDX=0
hat() {
  _HAT_IDX=$(((_HAT_IDX + 1) % 2))
  case $_HAT_IDX in
    0) printf '⏳' ;;
    1) printf '⌛' ;;
  esac
}

short_image_ref() {
  local _ref="${1:-}"
  case "$_ref" in
    */*) printf '%s' "${_ref#*/}" ;;
    *) printf '%s' "$_ref" ;;
  esac
}

find_catalog_namespace() {
  local _ns
  for _ns in aap-operator openshift-marketplace olm; do
    if kubectl get catalogsource redhat-operators -n "$_ns" &>/dev/null 2>&1; then
      echo "$_ns"
      return 0
    fi
  done
  echo "aap-operator"
}

maybe_relax_redhat_registry_signature_policy() {
  # MicroShift 4.22+ requires GPG signatures for registry.redhat.io; the operator
  # index image fails verification. aap-demo deploy applies the same fix.
  # shellcheck source=../../includes/infra-crc.sh
  source "${REPO_ROOT}/includes/infra-crc.sh" 2>/dev/null || return 0
  if [ -z "${CRC_SSH_KEY:-}" ]; then
    return 0
  fi
  local _ocp_version _major _minor
  _ocp_version=$(resolve_aap_ocp_version)
  _major="${_ocp_version%%.*}"
  _minor="${_ocp_version#*.}"
  if [ "$_major" -lt 4 ]; then
    return 0
  fi
  if [ "$_major" -eq 4 ] && [ "$_minor" -lt 22 ]; then
    return 0
  fi
  ssh -p "$CRC_SSH_PORT" "${CRC_SSH_OPTS[@]}" core@127.0.0.1 'sudo python3 -c "
import json
p = \"/etc/containers/policy.json\"
with open(p) as f: d = json.load(f)
reg = d.get(\"transports\",{}).get(\"docker\",{}).get(\"registry.redhat.io\",[])
if reg and reg[0].get(\"type\") != \"insecureAcceptAnything\":
    d[\"transports\"][\"docker\"][\"registry.redhat.io\"] = [{\"type\": \"insecureAcceptAnything\"}]
    with open(p, \"w\") as f: json.dump(d, f, indent=4)
    print(\"  ✓ Relaxed container signature policy (MicroShift 4.22+)\")
else:
    print(\"  Container signature policy already relaxed\")
"' || {
    echo "  WARNING: Could not relax signature policy via SSH (is CRC running?)" >&2
    return 1
  }
}

catalog_pod_has_signature_pull_failure() {
  local _catalog_ns="$1"
  kubectl get events -n "$_catalog_ns" --field-selector involvedObject.kind=Pod \
    2>/dev/null | grep -q "SignatureValidationFailed" \
    || kubectl describe pod -n "$_catalog_ns" -l olm.catalogSource=redhat-operators \
      2>/dev/null | grep -q "SignatureValidationFailed"
}

report_catalog_signature_failure() {
  echo "ERROR: redhat-operator-index cannot be pulled (SignatureValidationFailed)." >&2
  echo "  MicroShift 4.22+ requires GPG signatures; the index image fails that check." >&2
  echo "  Fix (demo-only, same as aap-demo deploy):" >&2
  echo "    aap-demo deploy   # re-applies signature policy + catalog" >&2
  echo "  Or re-run with catalog refresh after deploy fixes policy:" >&2
  echo "    AO_REFRESH_CATALOG=1 aap-demo enable ao" >&2
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

resolve_operator_index_image() {
  if [ -n "${AO_INDEX_IMAGE:-}" ]; then
    echo "$AO_INDEX_IMAGE"
    return 0
  fi
  if [ -n "${AO_ACTIVE_INDEX_IMAGE:-}" ]; then
    echo "$AO_ACTIVE_INDEX_IMAGE"
    return 0
  fi
  local _ocp_version
  _ocp_version=$(resolve_aap_ocp_version)
  echo "registry.redhat.io/redhat/redhat-operator-index:v${_ocp_version}"
}

resolve_operator_channel() {
  if [ -n "${AO_OPERATOR_CHANNEL:-}" ]; then
    echo "$AO_OPERATOR_CHANNEL"
    return 0
  fi
  echo "stable"
}

refresh_operator_channel() {
  OPERATOR_CHANNEL="$(resolve_operator_channel)"
}

try_fallback_operator_index() {
  if [ "${AO_DISABLE_INDEX_FALLBACK:-}" = "1" ]; then
    return 1
  fi
  if [ -n "${AO_INDEX_IMAGE:-}" ]; then
    return 1
  fi
  if [ "${AO_INDEX_FALLBACK_USED:-0}" = "1" ]; then
    return 1
  fi
  local _current_index
  _current_index=$(resolve_operator_index_image)
  if [ "$_current_index" = "$AO_FALLBACK_INDEX_IMAGE" ]; then
    return 1
  fi

  echo "  Switching AO catalog to fallback index..."
  echo "    $(short_image_ref "$AO_FALLBACK_INDEX_IMAGE")"
  AO_ACTIVE_INDEX_IMAGE="$AO_FALLBACK_INDEX_IMAGE"
  AO_INDEX_FALLBACK_USED=1
  refresh_operator_channel
  CATALOG_NAMESPACE=$(ensure_ao_catalog_source) || return 1
  OLM_NAMESPACE="$NAMESPACE"
  operator_package_in_catalog "$CATALOG_NAMESPACE"
}

refresh_operator_channel

wait_for_catalog_ready() {
  local _catalog_ns="$1"
  local _i _status _pod_status
  for _i in $(seq 1 60); do
    _status=$(kubectl get catalogsource redhat-operators -n "$_catalog_ns" \
      -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "Pending")
    if [ "$_status" = "READY" ]; then
      echo "" >&2
      return 0
    fi
    _pod_status=$(kubectl get pods -n "$_catalog_ns" -l olm.catalogSource=redhat-operators \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    if [ "$_pod_status" = "ImagePullBackOff" ] || [ "$_pod_status" = "ErrImagePull" ]; then
      if catalog_pod_has_signature_pull_failure "$_catalog_ns"; then
        echo "" >&2
        report_catalog_signature_failure
        return 1
      fi
    fi
    printf "\r  $(hat) CatalogSource: %-18s | pod: %-16s    " "$_status" "$_pod_status" >&2
    sleep 5
  done
  echo "" >&2
  return 1
}

wait_for_operator_package() {
  local _catalog_ns="$1"
  local _i
  for _i in $(seq 1 24); do
    if operator_package_in_catalog "$_catalog_ns"; then
      echo "" >&2
      return 0
    fi
    printf "\r  $(hat) waiting for packagemanifest... (%ds)    " "$((_i * 5))" >&2
    sleep 5
  done
  echo "" >&2
  return 1
}

copy_pull_secret_to_namespace() {
  local _src_ns="$1"
  local _dst_ns="$2"
  local _src_name="$3"
  local _dst_name="${4:-$_src_name}"
  if ! kubectl get secret "$_src_name" -n "$_src_ns" &>/dev/null; then
    return 1
  fi
  kubectl get secret "$_src_name" -n "$_src_ns" -o json \
    | DST_NAME="$_dst_name" DST_NS="$_dst_ns" python3 -c "
import json, os, sys
secret = json.load(sys.stdin)
out = {
    'apiVersion': 'v1',
    'kind': 'Secret',
    'metadata': {
        'name': os.environ['DST_NAME'],
        'namespace': os.environ['DST_NS'],
    },
    'type': secret.get('type', 'kubernetes.io/dockerconfigjson'),
    'data': secret.get('data', {}),
}
json.dump(out, sys.stdout)
" | kubectl apply -f - >&2
}

select_ao_index_image() {
  local _aap_ns _aap_image
  if [ -n "${AO_INDEX_IMAGE:-}" ]; then
    AO_ACTIVE_INDEX_IMAGE="$AO_INDEX_IMAGE"
    echo "$AO_ACTIVE_INDEX_IMAGE"
    return 0
  fi
  if [ -n "${AO_ACTIVE_INDEX_IMAGE:-}" ]; then
    echo "$AO_ACTIVE_INDEX_IMAGE"
    return 0
  fi
  _aap_ns=$(find_catalog_namespace)
  _aap_image=$(kubectl get catalogsource redhat-operators -n "$_aap_ns" \
    -o jsonpath='{.spec.image}' 2>/dev/null || echo "")
  if operator_package_in_catalog "$_aap_ns" && [ -n "$_aap_image" ]; then
    AO_ACTIVE_INDEX_IMAGE="$_aap_image"
    echo "$AO_ACTIVE_INDEX_IMAGE"
    return 0
  fi
  if [ "${AO_DISABLE_INDEX_FALLBACK:-}" != "1" ]; then
    echo "  automation-orchestrator-operator not in default catalog — using fallback index" >&2
    echo "    $(short_image_ref "$AO_FALLBACK_INDEX_IMAGE")" >&2
    AO_ACTIVE_INDEX_IMAGE="$AO_FALLBACK_INDEX_IMAGE"
    AO_INDEX_FALLBACK_USED=1
    echo "$AO_ACTIVE_INDEX_IMAGE"
    return 0
  fi
  resolve_operator_index_image
}

ensure_ao_catalog_source() {
  local _catalog_ns="$NAMESPACE"
  local _src_ns _target_image _current_image

  _src_ns=$(find_catalog_namespace)
  _target_image=$(select_ao_index_image)
  _current_image=$(kubectl get catalogsource redhat-operators -n "$_catalog_ns" \
    -o jsonpath='{.spec.image}' 2>/dev/null || echo "")

  echo "Creating AO CatalogSource in ${_catalog_ns}..." >&2
  echo "  Index: $(short_image_ref "$_target_image")" >&2

  if ! copy_pull_secret_to_namespace "$_src_ns" "$_catalog_ns" \
    "redhat-operators-pull-secret" "redhat-operators-pull-secret"; then # pragma: allowlist secret
    echo "ERROR: redhat-operators-pull-secret not found in ${_src_ns}" >&2
    echo "  Run 'aap-demo deploy' first." >&2
    return 1
  fi

  if [ ! -f "$CATALOG_SOURCE_TEMPLATE" ]; then
    echo "ERROR: CatalogSource template not found: ${CATALOG_SOURCE_TEMPLATE}" >&2
    return 1
  fi

  sed -e "s|image: .*|image: ${_target_image}|" \
    -e "s|namespace: aap-operator|namespace: ${_catalog_ns}|" \
    "$CATALOG_SOURCE_TEMPLATE" | kubectl apply -f - >&2

  if [ -n "$REFRESH_CATALOG" ] || { [ -n "$_current_image" ] && [ "$_current_image" != "$_target_image" ]; }; then
    echo "  Restarting catalog pod..." >&2
    kubectl delete pod -n "$_catalog_ns" -l olm.catalogSource=redhat-operators \
      --wait=false 2>/dev/null || true
  fi

  echo "  Waiting for CatalogSource READY..." >&2
  if ! wait_for_catalog_ready "$_catalog_ns"; then
    echo "ERROR: CatalogSource not READY after refresh." >&2
    kubectl describe catalogsource redhat-operators -n "$_catalog_ns" 2>/dev/null | tail -20 >&2
    return 1
  fi
  echo "✓ CatalogSource READY" >&2

  echo "  Waiting for operator index to sync..." >&2
  if wait_for_operator_package "$_catalog_ns"; then
    echo "✓ automation-orchestrator-operator found in catalog" >&2
  else
    echo "  ⚠ automation-orchestrator-operator still not in catalog after refresh" >&2
    echo "    The index image may not include this operator yet." >&2
  fi

  echo "$_catalog_ns"
}

resolve_cluster_domain() {
  local _host _domain
  _host=$(kubectl get route -n "$AAP_NAMESPACE" \
    -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  if [ -n "$_host" ]; then
    _domain="${_host#*.}"
    if [ "$_domain" != "$_host" ]; then
      echo "$_domain"
      return 0
    fi
  fi
  echo "apps.127.0.0.1.nip.io"
}

operator_controller_namespace() {
  local _ns
  for _ns in "${OLM_NAMESPACE:-}" "$NAMESPACE"; do
    [ -z "$_ns" ] && continue
    if kubectl get deployment automation-orchestrator-operator-controller-manager \
      -n "$_ns" &>/dev/null; then
      echo "$_ns"
      return 0
    fi
  done
  echo "${OLM_NAMESPACE:-$NAMESPACE}"
}

operator_is_available() {
  local _ns
  _ns=$(operator_controller_namespace)
  kubectl wait --for=condition=Available \
    deployment/automation-orchestrator-operator-controller-manager \
    -n "$_ns" --timeout=5s &>/dev/null 2>&1
}

operator_package_in_catalog() {
  local _catalog_ns="$1"
  kubectl get packagemanifest automation-orchestrator-operator \
    -n "$_catalog_ns" &>/dev/null 2>&1
}

subscription_has_resolution_failure() {
  kubectl get subscription automation-orchestrator-operator -n "${OLM_NAMESPACE}" \
    -o json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
for cond in data.get("status", {}).get("conditions", []):
    if cond.get("status") != "True":
        continue
    if cond.get("type") == "ResolutionFailed":
        sys.exit(0)
    if cond.get("type") == "CatalogSourcesUnhealthy":
        if cond.get("reason") != "AllCatalogSourcesHealthy":
            sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

subscription_failure_detail() {
  kubectl get subscription automation-orchestrator-operator -n "${OLM_NAMESPACE}" \
    -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' 2>/dev/null \
    || echo ""
}

apply_operator_olm_manifests() {
  sed -e "s|__NAMESPACE__|${NAMESPACE}|g" \
    -e "s|__CATALOG_NAMESPACE__|${CATALOG_NAMESPACE}|g" \
    -e "s|__OPERATOR_CHANNEL__|${OPERATOR_CHANNEL}|g" \
    "${MANIFESTS_DIR}/operator-subscription.yaml" | kubectl apply -f -
}

cleanup_ao_olm_state() {
  local _ns
  for _ns in "${OLM_NAMESPACE:-}" "$NAMESPACE" "$AAP_NAMESPACE"; do
    [ -z "$_ns" ] && continue
    kubectl delete subscription automation-orchestrator-operator -n "$_ns" --wait=false 2>/dev/null || true
    kubectl delete operatorgroup automation-orchestrator-operator -n "$_ns" --wait=false 2>/dev/null || true
    if [ "$_ns" = "$AAP_NAMESPACE" ]; then
      continue
    fi
    kubectl get installplan -n "$_ns" -o name 2>/dev/null \
      | xargs -r kubectl delete -n "$_ns" --wait=false 2>/dev/null || true
    kubectl get csv -n "$_ns" -o name 2>/dev/null \
      | grep "automation-orchestrator" \
      | xargs -r kubectl delete -n "$_ns" --wait=false 2>/dev/null || true
  done
}

reset_operator_subscription() {
  echo "  Resetting failed operator subscription..."
  cleanup_ao_olm_state
  sleep 10
  apply_operator_olm_manifests
}

report_subscription_resolution_failure() {
  local _catalog_ns="$1"
  echo "ERROR: OLM could not resolve automation-orchestrator-operator subscription."
  echo ""
  subscription_failure_detail | sed 's/^/  /'
  echo ""
  if operator_package_in_catalog "$_catalog_ns"; then
    echo "  The operator package exists in catalog (${_catalog_ns}) but OLM resolution failed."
    echo "  On MicroShift, CatalogSource, OperatorGroup, and Subscription must all live in"
    echo "  ${NAMESPACE}. The Automation Orchestrator operator also requires AllNamespaces mode,"
    echo "  so its OperatorGroup cannot share ${AAP_NAMESPACE} with AAP."
    if [ "${AO_INDEX_FALLBACK_USED:-0}" = "1" ]; then
      echo "  Fallback index was already applied. Retry:"
    else
      echo "  This is usually a stale subscription from when the catalog was unhealthy. Retry:"
    fi
    echo "    aap-demo disable ao && FORCE=1 aap-demo enable ao"
  else
    report_operator_not_in_catalog "$_catalog_ns"
    return 1
  fi
}

report_operator_not_in_catalog() {
  local _catalog_ns="$1"
  local _index_image
  _index_image=$(kubectl get catalogsource redhat-operators -n "$_catalog_ns" \
    -o jsonpath='{.spec.image}' 2>/dev/null || echo "unknown")
  echo "ERROR: automation-orchestrator-operator is not in catalog redhat-operators (${_catalog_ns})."
  echo ""
  echo "  OLM message (if subscription already exists):"
  echo "    constraints not satisfiable: no operators found from catalog redhat-operators"
  echo ""
  echo "  The operator may not be published in your current operator index:"
  echo "    $(short_image_ref "$_index_image")"
  echo ""
  echo "  This install path requires automation-orchestrator-operator in redhat-operator-index"
  echo "  (v4.18+). If the package is missing, verify catalog index version and refresh."
  echo ""
  echo "  Verify:"
  echo "    kubectl get packagemanifest automation-orchestrator-operator -n ${_catalog_ns}"
  echo "    kubectl get subscription automation-orchestrator-operator -n ${OLM_NAMESPACE:-$CATALOG_NAMESPACE} -o yaml"
  echo ""
  echo "  Clean up a failed attempt:"
  echo "    aap-demo disable ao"
  echo ""
  echo "  Force catalog refresh (re-pull index, restart catalog pod):"
  echo "    AO_REFRESH_CATALOG=1 aap-demo enable ao"
  echo "  Fallback index (automatic when default catalog lacks AO):"
  echo "    $(short_image_ref "$AO_FALLBACK_INDEX_IMAGE")"
  echo "  Disable automatic fallback:"
  echo "    AO_DISABLE_INDEX_FALLBACK=1 aap-demo enable ao"
}

show_access_info() {
  local AO_ROUTE PASS_SECRET AO_PASSWORD
  AO_ROUTE=$(kubectl get routes -n "$NAMESPACE" \
    -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  PASS_SECRET=$(kubectl get secret -n "$NAMESPACE" \
    -o name 2>/dev/null | grep -i "admin-password" | head -1 || echo "")

  if [ -n "$AO_ROUTE" ]; then
    echo "  URL:      https://${AO_ROUTE}"
  else
    echo "  URL:      kubectl get routes -n ${NAMESPACE} -o jsonpath='{.items[0].spec.host}'"
  fi
  echo "  Username: admin"
  if [ -n "$PASS_SECRET" ]; then
    if [ "${CI:-}" != "true" ]; then
      AO_PASSWORD=$(kubectl get "$PASS_SECRET" -n "$NAMESPACE" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
      if [ -n "$AO_PASSWORD" ]; then
        echo "  Password: ${AO_PASSWORD}"
      else
        echo "  Password: kubectl get $PASS_SECRET -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
      fi
    else
      echo "  Password: kubectl get $PASS_SECRET -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
    fi
  else
    echo "  Password: kubectl get secret -n $NAMESPACE | grep admin-password"
  fi
  echo "  Status:   kubectl get pods -n $NAMESPACE"
}

AO_PULL_SECRET_NAME="${AO_PULL_SECRET_NAME:-automation-orchestrator-pull-secret}"

ensure_ao_pull_secret() {
  local _src_ns="${CATALOG_NAMESPACE:-$AAP_NAMESPACE}"
  if kubectl get secret "$AO_PULL_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    return 0
  fi
  if ! kubectl get secret redhat-operators-pull-secret -n "$_src_ns" &>/dev/null; then
    echo "WARNING: redhat-operators-pull-secret not found in ${_src_ns}"
    return 1
  fi
  echo "Copying pull secret into ${NAMESPACE}..."
  kubectl get secret redhat-operators-pull-secret -n "$_src_ns" -o json \
    | AO_PULL_SECRET_NAME="$AO_PULL_SECRET_NAME" NAMESPACE="$NAMESPACE" python3 -c "
import json, os, sys
secret = json.load(sys.stdin)
secret['metadata'] = {
    'name': os.environ['AO_PULL_SECRET_NAME'],
    'namespace': os.environ['NAMESPACE'],
}
json.dump(secret, sys.stdout)
" | kubectl apply -f -
}

link_ao_pull_secrets_to_operator() {
  ensure_ao_pull_secret || return 0
  echo "Linking pull secret to operator service accounts..."
  local _ns
  for _ns in "${OLM_NAMESPACE:-}" "$NAMESPACE"; do
    [ -z "$_ns" ] && continue
    for _sa in automation-orchestrator-operator-controller-manager default; do
      if kubectl get sa "$_sa" -n "$_ns" &>/dev/null; then
        kubectl patch sa "$_sa" -n "$_ns" --type=merge \
          -p "{\"imagePullSecrets\":[{\"name\":\"${AO_PULL_SECRET_NAME}\"}]}" 2>/dev/null || true
      fi
    done
  done
}

deploy_ao_instance() {
  kubectl delete secret automation-orchestrator-initial-admin-password \
    -n "$NAMESPACE" 2>/dev/null || true

  echo "Creating AutomationOrchestrator instance (aapctl GitOps CR)..."
  sed -e "s|__NAMESPACE__|${NAMESPACE}|g" \
    -e "s|__INGRESS_HOST__|${INGRESS_HOST}|g" \
    -e "s|__PULL_SECRET_NAME__|${AO_PULL_SECRET_NAME}|g" \
    "${MANIFESTS_DIR}/automationorchestrator-cr.yaml" | kubectl apply -f -
}

cleanup_legacy_ea_resources() {
  local _ns
  for _ns in aap-operator olm openshift-marketplace; do
    kubectl delete catalogsource cs-automation-orchestrator -n "$_ns" --wait=false 2>/dev/null || true
    kubectl delete secret ao-registry-pull-secret -n "$_ns" 2>/dev/null || true
  done
}

# --- Delete ---
if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing Automation Orchestrator..."

  if command -v aapctl >/dev/null 2>&1; then
    aapctl uninstall automation-orchestrator --force --yes 2>/dev/null || true
  fi

  kubectl get automationorchestrator -n "$NAMESPACE" -o name 2>/dev/null \
    | xargs -r -I{} kubectl patch {} -n "$NAMESPACE" \
      --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' \
      2>/dev/null || true
  kubectl get automationorchestrators.aap.ansible.com -n "$NAMESPACE" -o name 2>/dev/null \
    | xargs -r -I{} kubectl patch {} -n "$NAMESPACE" \
      --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' \
      2>/dev/null || true

  kubectl delete automationorchestrator --all -n "$NAMESPACE" --wait=false 2>/dev/null || true
  OLM_NAMESPACE="$NAMESPACE"
  cleanup_ao_olm_state

  cleanup_legacy_ea_resources

  kubectl delete namespace "$NAMESPACE" --wait=false 2>/dev/null || true

  echo "  Waiting for namespace to terminate..."
  for _i in $(seq 1 60); do
    _ao_ns=$(kubectl get namespace "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ') || _ao_ns=0
    printf "\r  $(hat) automation-orchestrator: %s    " \
      "$([ "$_ao_ns" -eq 0 ] && echo "gone" || echo "terminating")"
    if [ "$_ao_ns" -eq 0 ]; then
      echo ""
      break
    fi
    if [ "$_i" -eq 60 ]; then
      echo ""
      echo "  ⚠ Namespace still terminating after 5 minutes — continuing anyway"
      echo "  Check: kubectl get namespace $NAMESPACE"
    fi
    sleep 5
  done

  if [ -f "$AO_STATE_FILE" ]; then
    # shellcheck source=/dev/null
    source "$AO_STATE_FILE"
  fi
  CNPG_VERSION="${CNPG_VERSION:-1.25.1}"
  CNPG_MANIFEST="https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_VERSION}/cnpg-${CNPG_VERSION}.yaml"
  kubectl delete -f "$CNPG_MANIFEST" 2>/dev/null || true
  rm -f "$AO_STATE_FILE"

  echo "✓ Automation Orchestrator removed"
  exit 0
fi

# --- Skip if already running (unless --force) ---
if [ -z "$FORCE" ]; then
  _ao_total=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | { grep -v "Completed" || true; } | wc -l | tr -d ' ' || echo "0")
  _ao_running=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | { grep "Running" || true; } | wc -l | tr -d ' ' || echo "0")
  _sub_channel=$(kubectl get subscription automation-orchestrator-operator -n "$NAMESPACE" \
    -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
  if [ "${_ao_total:-0}" -gt 2 ] \
    && [ "${_ao_running:-0}" -eq "${_ao_total:-0}" ] \
    && [ "$_sub_channel" = "$OPERATOR_CHANNEL" ] \
    && operator_is_available; then
    echo "✓ Automation Orchestrator already running (${_ao_running}/${_ao_total} pods, ${OPERATOR_CHANNEL} channel)"
    echo "  Use FORCE=1 aap-demo enable ao (or ./deploy.sh --force) to reinstall."
    echo ""
    show_access_info
    exit 0
  fi
fi

# --- Namespace + SCCs ---
echo "Creating namespace and SCC grants..."
kubectl create namespace "$NAMESPACE" 2>/dev/null || true
oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${NAMESPACE}" 2>/dev/null || true
oc adm policy add-scc-to-group privileged "system:serviceaccounts:${NAMESPACE}" 2>/dev/null || true
echo "✓ Namespace ready"

# --- AO-local catalog (MicroShift cannot resolve CatalogSources across namespaces) ---
echo "Checking AAP redhat-operators catalog (for index image and pull secret)..."
_aap_catalog_ns=$(find_catalog_namespace)
if ! kubectl get catalogsource redhat-operators -n "$_aap_catalog_ns" &>/dev/null; then
  echo "ERROR: redhat-operators CatalogSource is missing."
  echo "  Run 'aap-demo deploy' first to install OLM and the operator catalog."
  exit 1
fi
if catalog_pod_has_signature_pull_failure "$_aap_catalog_ns"; then
  echo "  Catalog pod cannot pull operator index (signature verification)..."
  maybe_relax_redhat_registry_signature_policy
fi
if ! CATALOG_NAMESPACE=$(ensure_ao_catalog_source); then
  echo "ERROR: Could not create AO CatalogSource in ${NAMESPACE}."
  exit 1
fi
OLM_NAMESPACE="$NAMESPACE"
refresh_operator_channel
if ! operator_package_in_catalog "$CATALOG_NAMESPACE"; then
  if try_fallback_operator_index; then
    echo "✓ Operator package found via fallback catalog index"
  else
    report_operator_not_in_catalog "$CATALOG_NAMESPACE"
    exit 1
  fi
fi
echo "✓ Operator package found in AO catalog (${CATALOG_NAMESPACE}, ${OPERATOR_CHANNEL})"

CLUSTER_DOMAIN=$(resolve_cluster_domain)
INGRESS_HOST="automation-orchestrator.${CLUSTER_DOMAIN}"
echo "✓ Ingress host: ${INGRESS_HOST}"

# --- CloudNativePG operator (dev-only PostgreSQL) ---
CNPG_VERSION="${CNPG_VERSION:-1.25.1}"

if kubectl get crd clusters.postgresql.cnpg.io &>/dev/null; then
  echo "✓ CloudNativePG CRDs already registered"
  mkdir -p "$(dirname "$AO_STATE_FILE")"
  grep -q "^CNPG_VERSION=" "$AO_STATE_FILE" 2>/dev/null \
    || echo "CNPG_VERSION=${CNPG_VERSION}" >>"$AO_STATE_FILE"
else
  echo "Installing CloudNativePG operator v${CNPG_VERSION} (dev-only, not Red Hat supported)..."
  CNPG_MANIFEST="https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_VERSION}/cnpg-${CNPG_VERSION}.yaml"
  if ! kubectl apply --server-side -f "$CNPG_MANIFEST" 2>&1 | tail -5; then
    echo "ERROR: Failed to install CloudNativePG from ${CNPG_MANIFEST}"
    exit 1
  fi
  mkdir -p "$(dirname "$AO_STATE_FILE")"
  echo "CNPG_VERSION=${CNPG_VERSION}" >"$AO_STATE_FILE"
  oc adm policy add-scc-to-group anyuid "system:serviceaccounts:cnpg-system" 2>/dev/null || true
  oc adm policy add-scc-to-group privileged "system:serviceaccounts:cnpg-system" 2>/dev/null || true

  echo "Waiting for CloudNativePG operator..."
  kubectl rollout status deployment/cnpg-controller-manager \
    -n cnpg-system --timeout=5m
  echo "✓ CloudNativePG operator running"
fi

# --- PostgreSQL cluster + aapctl-shaped credential secrets ---
# Secret names/keys match `aapctl install ao --dry-run` (GitOps manifests).
echo "Creating PostgreSQL cluster for Automation Orchestrator..."

_legacy_secret=""
if kubectl get cluster orchestrator-postgres -n "$NAMESPACE" -o jsonpath='{.spec.bootstrap.initdb.secret.name}' 2>/dev/null \
  | grep -qx "orchestrator-pg-credentials"; then
  _legacy_secret=1
fi
if kubectl get secret orchestrator-pg-credentials -n "$NAMESPACE" &>/dev/null \
  || kubectl get secret temporal-pg-credentials -n "$NAMESPACE" &>/dev/null; then
  _legacy_secret=1
fi

if [ -n "$FORCE" ] || [ -n "$_legacy_secret" ]; then
  if [ -n "$_legacy_secret" ]; then
    echo "  Recreating postgres to match aapctl secret names..."
    kubectl delete secret orchestrator-pg-credentials temporal-pg-credentials -n "$NAMESPACE" \
      --ignore-not-found 2>/dev/null || true
  fi
  if kubectl get cluster orchestrator-postgres -n "$NAMESPACE" &>/dev/null \
    || kubectl get pvc orchestrator-postgres-1 -n "$NAMESPACE" &>/dev/null; then
    echo "  Resetting postgres cluster for fresh init..."
    kubectl delete cluster orchestrator-postgres -n "$NAMESPACE" 2>/dev/null || true
    kubectl wait --for=delete cluster/orchestrator-postgres -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
    kubectl delete pvc orchestrator-postgres-1 -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
  fi
fi

# Reuse the existing aapctl secret password so we never desync from CNPG.
if kubectl get secret orchestrator-postgres-secret -n "$NAMESPACE" &>/dev/null; then
  PG_PASSWORD=$(kubectl get secret orchestrator-postgres-secret -n "$NAMESPACE" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
fi
if [ -z "${PG_PASSWORD:-}" ]; then
  PG_PASSWORD="$(head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"
fi
PG_HOST="orchestrator-postgres-rw.${NAMESPACE}.svc"

kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: orchestrator-postgres-secret
  namespace: ${NAMESPACE}
type: kubernetes.io/basic-auth
stringData:
  database: orchestrator
  host: ${PG_HOST}
  password: ${PG_PASSWORD}
  port: "5432"
  username: orchestrator
---
apiVersion: v1
kind: Secret
metadata:
  name: temporal-postgres-secret
  namespace: ${NAMESPACE}
type: kubernetes.io/basic-auth
stringData:
  database: temporal
  host: ${PG_HOST}
  password: ${PG_PASSWORD}
  port: "5432"
  username: orchestrator
---
apiVersion: v1
kind: Secret
metadata:
  name: temporal-visibility-postgres-secret
  namespace: ${NAMESPACE}
type: kubernetes.io/basic-auth
stringData:
  database: temporal_visibility
  host: ${PG_HOST}
  password: ${PG_PASSWORD}
  port: "5432"
  username: orchestrator
EOF

sed -e "s|__NAMESPACE__|${NAMESPACE}|g" \
  -e "s|__STORAGE_CLASS__|${STORAGE_CLASS}|g" \
  "${MANIFESTS_DIR}/postgres-cluster.yaml" | kubectl apply -f -

echo "Waiting for PostgreSQL cluster to be ready..."
for i in $(seq 1 60); do
  READY=$(kubectl get cluster orchestrator-postgres -n "$NAMESPACE" \
    -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
  if [ "$READY" = "1" ]; then
    echo "✓ PostgreSQL cluster ready"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: PostgreSQL cluster not ready after 10 minutes. Continuing..."
  fi
  printf "\r  $(hat) readyInstances: %-4s    " "${READY}"
  sleep 10
done
echo ""
echo "✓ PostgreSQL databases created"

# --- Operator install (GA OLM subscription) ---
# AAP already has an OperatorGroup in aap-operator; a second one there
# makes OLM refuse all subscriptions in that namespace.
kubectl delete subscription automation-orchestrator-operator -n "$AAP_NAMESPACE" --wait=false 2>/dev/null || true
kubectl delete operatorgroup automation-orchestrator-operator -n "$AAP_NAMESPACE" --wait=false 2>/dev/null || true

if [ -n "$FORCE" ]; then
  echo "Clearing existing operator OLM state..."
  kubectl delete automationorchestrator --all -n "$NAMESPACE" --wait=false 2>/dev/null || true
  cleanup_ao_olm_state
  for _csv_wait in $(seq 1 12); do
    _stuck_csv=""
    for _csv_ns in "$OLM_NAMESPACE" "$NAMESPACE"; do
      _stuck_csv="${_stuck_csv}$(kubectl get csv -n "$_csv_ns" -o name 2>/dev/null \
        | grep "automation-orchestrator" || true)"
    done
    [ -z "$_stuck_csv" ] && break
    if [ "$_csv_wait" -ge 6 ]; then
      echo "  Clearing stuck CSV finalizers..."
      for _csv_ns in "$OLM_NAMESPACE" "$NAMESPACE"; do
        kubectl get csv -n "$_csv_ns" -o name 2>/dev/null \
          | grep "automation-orchestrator" \
          | while read -r _csv; do
            kubectl patch "$_csv" -n "$_csv_ns" --type=json \
              -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
          done
      done
    fi
    sleep 5
  done
  cleanup_legacy_ea_resources
fi

echo "Installing automation orchestrator operator (${OPERATOR_CHANNEL} channel)..."
apply_operator_olm_manifests

echo "Waiting for InstallPlan..."
_sub_reset=0
for i in $(seq 1 30); do
  _pending_ips=$(kubectl get installplan -n "$OLM_NAMESPACE" -o json 2>/dev/null \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data.get("items", []):
    if not item.get("spec", {}).get("approved", False):
        print(item["metadata"]["name"])
' 2>/dev/null || echo "")
  if [ -n "$_pending_ips" ]; then
    while read -r _ip; do
      [ -z "$_ip" ] && continue
      echo "  Approving InstallPlan: ${_ip}"
      kubectl patch installplan "$_ip" -n "$OLM_NAMESPACE" \
        --type merge -p '{"spec":{"approved":true}}'
    done <<<"$_pending_ips"
  fi
  if kubectl get csv -n "$OLM_NAMESPACE" -o name 2>/dev/null | grep -q "automation-orchestrator"; then
    echo "✓ CSV created"
    break
  fi
  if subscription_has_resolution_failure; then
    if [ "$_sub_reset" -lt 1 ]; then
      echo "  Subscription resolution failed — resetting OLM state..."
      reset_operator_subscription
      _sub_reset=1
      printf "\r  $(hat) subscription reset, waiting for OLM...    "
      sleep 10
      continue
    fi
    if [ "${AO_INDEX_FALLBACK_USED:-0}" = "0" ] && try_fallback_operator_index; then
      echo "  Retrying operator subscription on fallback catalog (${OPERATOR_CHANNEL})..."
      reset_operator_subscription
      _sub_reset=0
      sleep 10
      continue
    fi
    echo ""
    report_subscription_resolution_failure "$CATALOG_NAMESPACE"
    exit 1
  fi
  if subscription_failure_detail | grep -qi "constraints not satisfiable\|no operators found"; then
    if [ "${AO_INDEX_FALLBACK_USED:-0}" = "0" ] && try_fallback_operator_index; then
      echo "  Retrying operator subscription on fallback catalog (${OPERATOR_CHANNEL})..."
      reset_operator_subscription
      _sub_reset=0
      sleep 10
      continue
    fi
    echo ""
    report_operator_not_in_catalog "$CATALOG_NAMESPACE"
    exit 1
  fi
  if [ "$i" -eq 30 ]; then
    echo ""
    echo "ERROR: Operator CSV not found after 5 minutes."
    echo "  Subscription conditions:"
    subscription_failure_detail | sed 's/^/    /'
    echo "  InstallPlans:"
    kubectl get installplan -n "$OLM_NAMESPACE" 2>/dev/null
    echo ""
    report_subscription_resolution_failure "$CATALOG_NAMESPACE" || true
    exit 1
  fi
  SUB_STATE=$(kubectl get subscription automation-orchestrator-operator -n "$OLM_NAMESPACE" \
    -o jsonpath='{.status.state}' 2>/dev/null || echo "")
  if [ -z "$SUB_STATE" ]; then
    SUB_STATE=$(kubectl get subscription automation-orchestrator-operator -n "$OLM_NAMESPACE" \
      -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "pending")
  fi
  printf "\r  $(hat) subscription: %-15s    " "${SUB_STATE}"
  sleep 10
done
echo ""

echo "Waiting for operator to become available..."
if ! kubectl wait --for=condition=Available \
  deployment/automation-orchestrator-operator-controller-manager \
  -n "$(operator_controller_namespace)" --timeout=300s 2>/dev/null; then
  echo "ERROR: Operator deployment not Available after 5 minutes."
  kubectl get pods -n "$OLM_NAMESPACE" 2>/dev/null || true
  kubectl get pods -n "$NAMESPACE" 2>/dev/null || true
  exit 1
fi
echo "✓ Operator running"

link_ao_pull_secrets_to_operator
if kubectl get deployment automation-orchestrator-operator-controller-manager \
  -n "$(operator_controller_namespace)" &>/dev/null; then
  kubectl rollout restart deployment/automation-orchestrator-operator-controller-manager \
    -n "$(operator_controller_namespace)" 2>/dev/null || true
  kubectl rollout status deployment/automation-orchestrator-operator-controller-manager \
    -n "$(operator_controller_namespace)" --timeout=5m 2>/dev/null || true
fi

# --- Instance deploy (AutomationOrchestrator CR from GitOps manifest) ---
deploy_ao_instance

# --- Wait for instance ---
echo "Waiting for Automation Orchestrator instance (may take 10+ minutes)..."
_AO_TIMEOUT=1200
_AO_START=$(date +%s)
while true; do
  _AO_ELAPSED=$(($(date +%s) - _AO_START))
  _ao_reason=$(kubectl get automationorchestrator automation-orchestrator -n "$NAMESPACE" \
    -o jsonpath='{range .status.conditions[?(@.type=="Degraded")]}{.reason}{end}' 2>/dev/null || echo "")
  _ao_degraded=$(kubectl get automationorchestrator automation-orchestrator -n "$NAMESPACE" \
    -o jsonpath='{range .status.conditions[?(@.type=="Degraded")]}{.status}{end}' 2>/dev/null || echo "")
  _ao_route=$(kubectl get routes -n "$NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  _ao_running=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | awk '$3=="Running" && $1 !~ /^redhat-operators-/ {c++} END {print c+0}')
  _ao_problem=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | awk '$3 ~ /CrashLoopBackOff|Error|ImagePullBackOff/ {c++} END {print c+0}')
  printf "\r  running=%s degraded=%s" "${_ao_running}" "${_ao_reason:-none}"
  [ "${_ao_problem:-0}" -gt 0 ] && printf " problems=%s" "$_ao_problem"
  printf " (%ds)    " "$_AO_ELAPSED"
  if [ -n "$_ao_route" ] && [ "${_ao_degraded}" != "True" ] && [ "${_ao_running:-0}" -gt 3 ]; then
    echo ""
    echo "✓ Route ready"
    break
  fi
  if [ "$_AO_ELAPSED" -ge "$_AO_TIMEOUT" ]; then
    echo ""
    echo "  ⚠ Instance not ready after 20 minutes — continuing anyway"
    echo "  Check: kubectl get automationorchestrator,pods,routes -n $NAMESPACE"
    break
  fi
  sleep 10
done

echo ""
echo "✓ Automation Orchestrator operator and instance applied"
if [ -z "${_ao_route:-}" ]; then
  echo "  Route is not ready yet; instance may still be reconciling."
fi
echo ""
show_access_info
