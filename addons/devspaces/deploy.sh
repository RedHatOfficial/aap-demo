#!/usr/bin/env bash
set -euo pipefail

# Deploy OpenShift DevSpaces to aap-demo
#
# Installs the DevSpaces operator via operator-sdk bundle and creates
# a CheCluster instance. Provides browser-based VS Code workspaces
# for AAP/Ansible development.
#
# Prerequisites:
#   1. aap-demo cluster running (aap-demo create)
#   2. OLM installed (auto-installed by aap-demo deploy)
#   3. operator-sdk installed
#   4. Suggest 8 vCPU / 18GB minimum for the CRC VM:
#        CRC_CPUS=8 CRC_MEMORY=18432 aap-demo create
#
# Usage:
#   ./deploy.sh          # Deploy DevSpaces
#   ./deploy.sh --delete # Remove DevSpaces

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../includes/aap-demo-paths.sh
source "${SCRIPT_DIR}/../../includes/aap-demo-paths.sh"
KUBECONFIG_PATH="$(aap_demo_resolve_kubeconfig "${KUBECONFIG:-}")"
export KUBECONFIG="$KUBECONFIG_PATH"

NAMESPACE="openshift-devspaces"
DW_CSV_LABEL="operators.coreos.com/devworkspace-operator.openshift-devspaces"
DS_CSV_LABEL="operators.coreos.com/devspaces.openshift-devspaces"

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing DevSpaces..."
  kubectl delete checluster devspaces -n "$NAMESPACE" 2>/dev/null || true
  # Wait for CheCluster finalizers
  echo "Waiting for CheCluster cleanup..."
  kubectl wait --for=delete checluster/devspaces -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  # Remove operators (both DevSpaces and its DevWorkspace dependency)
  kubectl delete sub --all -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete csv -n "$NAMESPACE" -l "$DS_CSV_LABEL" 2>/dev/null || true
  kubectl delete csv -n "$NAMESPACE" -l "$DW_CSV_LABEL" 2>/dev/null || true
  kubectl delete catalogsource --all -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete operatorgroup --all -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" 2>/dev/null || true
  # The config.openshift.io shim CRDs are intentionally left in place: other
  # addons may have come to rely on them. Remove them explicitly with:
  #   kubectl delete crd -l aap-demo.redhat.com/shim=openshift-config
  echo "✓ DevSpaces removed"
  exit 0
fi

# Check cluster connectivity
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl not connected to cluster"
  echo "Make sure aap-demo is running: aap-demo status"
  exit 1
fi

# Check OLM
if ! kubectl get crd subscriptions.operators.coreos.com >/dev/null 2>&1; then
  echo "ERROR: OLM not installed"
  echo "Run 'aap-demo deploy' first to install OLM"
  exit 1
fi

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
# Dump everything we would want if an operator deployment never becomes ready.
# The DevWorkspace controller in particular can exit(1) with a completely empty
# log (see openshift-config-shim.yaml), so "kubectl logs" alone is not enough —
# we also need describe output, the previous container's logs, the container
# state/exit code, namespace events, and the CSV conditions from OLM.
dump_operator_diagnostics() {
  local _label="$1"   # human-readable operator name
  local _csv_label="$2"

  echo "" >&2
  echo "=== DIAGNOSTICS: ${_label} (namespace ${NAMESPACE}) ===" >&2

  echo "" >&2
  echo "--- ClusterServiceVersions ---" >&2
  kubectl get csv -n "$NAMESPACE" -o wide 2>&1 | sed 's/^/  /' >&2 || true
  local _csv
  _csv=$(kubectl get csv -n "$NAMESPACE" -l "$_csv_label" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$_csv" ]; then
    echo "" >&2
    echo "--- CSV ${_csv} status ---" >&2
    kubectl get csv "$_csv" -n "$NAMESPACE" \
      -o jsonpath='{range .status.conditions[*]}  {.lastTransitionTime}{"  "}{.phase}{"  "}{.reason}{"  "}{.message}{"\n"}{end}' 2>&1 >&2 || true
    echo "" >&2
    echo "--- CSV requirementStatus (unmet requirements) ---" >&2
    kubectl get csv "$_csv" -n "$NAMESPACE" \
      -o jsonpath='{range .status.requirementStatus[?(@.status!="Present")]}  {.kind}/{.name}: {.status} {.message}{"\n"}{end}' 2>&1 >&2 || true
  fi

  echo "" >&2
  echo "--- Subscriptions ---" >&2
  kubectl get sub -n "$NAMESPACE" -o wide 2>&1 | sed 's/^/  /' >&2 || true
  echo "" >&2
  echo "--- InstallPlans ---" >&2
  kubectl get installplan -n "$NAMESPACE" 2>&1 | sed 's/^/  /' >&2 || true
  echo "" >&2
  echo "--- OperatorGroups ---" >&2
  kubectl get operatorgroup -n "$NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,TARGETS:.spec.targetNamespaces,SELECTOR:.spec.selector' 2>&1 | sed 's/^/  /' >&2 || true

  echo "" >&2
  echo "--- Deployments ---" >&2
  kubectl get deploy -n "$NAMESPACE" -o wide 2>&1 | sed 's/^/  /' >&2 || true
  local _deploy
  for _deploy in $(kubectl get deploy -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    local _ready
    _ready=$(kubectl get deploy "$_deploy" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
    [ "${_ready:-0}" != "0" ] && [ -n "$_ready" ] && continue
    echo "" >&2
    echo "--- describe deployment/${_deploy} (not ready) ---" >&2
    kubectl describe deploy "$_deploy" -n "$NAMESPACE" 2>&1 | sed 's/^/  /' >&2 || true
  done

  echo "" >&2
  echo "--- Pods ---" >&2
  kubectl get pods -n "$NAMESPACE" -o wide 2>&1 | sed 's/^/  /' >&2 || true

  local _pod
  for _pod in $(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    local _phase
    _phase=$(kubectl get pod "$_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    local _restarts
    _restarts=$(kubectl get pod "$_pod" -n "$NAMESPACE" \
      -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
    # Only dig into pods that are not happily Running with zero restarts.
    if [ "$_phase" = "Running" ] && [ "${_restarts:-0}" = "0" ]; then
      continue
    fi

    echo "" >&2
    echo "--- describe pod/${_pod} (phase=${_phase} restarts=${_restarts}) ---" >&2
    kubectl describe pod "$_pod" -n "$NAMESPACE" 2>&1 | sed 's/^/  /' >&2 || true

    echo "" >&2
    echo "--- container states for pod/${_pod} ---" >&2
    kubectl get pod "$_pod" -n "$NAMESPACE" \
      -o jsonpath='{range .status.containerStatuses[*]}  {.name}: ready={.ready} restarts={.restartCount} state={.state} lastState={.lastState}{"\n"}{end}' 2>&1 >&2 || true

    local _container
    for _container in $(kubectl get pod "$_pod" -n "$NAMESPACE" \
      -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
      echo "" >&2
      echo "--- logs pod/${_pod} -c ${_container} (current, tail 100) ---" >&2
      kubectl logs "$_pod" -n "$NAMESPACE" -c "$_container" --tail=100 2>&1 | sed 's/^/  /' >&2 || true
      echo "" >&2
      echo "--- logs pod/${_pod} -c ${_container} --previous (tail 100) ---" >&2
      kubectl logs "$_pod" -n "$NAMESPACE" -c "$_container" --previous --tail=100 2>&1 | sed 's/^/  /' >&2 || true
    done
  done

  echo "" >&2
  echo "--- Events (last 40, by time) ---" >&2
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>&1 | tail -40 | sed 's/^/  /' >&2 || true
  echo "" >&2
  echo "=== END DIAGNOSTICS: ${_label} ===" >&2
  echo "" >&2
}

echo "Deploying OpenShift DevSpaces..."

# ---------------------------------------------------------------------------
# MicroShift compatibility: the config.openshift.io API group
# ---------------------------------------------------------------------------
# The DevWorkspace Operator classifies a cluster that has route.openshift.io but
# NOT config.openshift.io as "Unsupported" and exits 1 from init() — before its
# logger is wired up, so it produces no output at all. MicroShift is exactly
# that shape. Register minimal config.openshift.io CRDs so detection succeeds.
# See addons/devspaces/openshift-config-shim.yaml for the full explanation.
if kubectl api-resources --api-group=route.openshift.io >/dev/null 2>&1 \
  && [ -n "$(kubectl api-resources --api-group=route.openshift.io -o name 2>/dev/null)" ] \
  && [ -z "$(kubectl api-resources --api-group=config.openshift.io -o name 2>/dev/null)" ]; then
  echo "Cluster has route.openshift.io but no config.openshift.io (MicroShift)."
  echo "  Installing config.openshift.io compatibility shim (required by DevWorkspace operator)..."
  kubectl apply -f "${SCRIPT_DIR}/openshift-config-shim.yaml"
  for _crd in proxies.config.openshift.io consoles.config.openshift.io authentications.config.openshift.io; do
    kubectl wait --for=condition=Established "crd/${_crd}" --timeout=60s >/dev/null 2>&1 || true
  done
  # Give discovery a moment to pick the new API group up before any operator
  # pod starts and queries ServerGroups().
  sleep 5
  if [ -z "$(kubectl api-resources --api-group=config.openshift.io -o name 2>/dev/null)" ]; then
    echo "ERROR: config.openshift.io still not present in API discovery after applying the shim." >&2
    echo "  The DevWorkspace operator will crash-loop with an empty log without it." >&2
    exit 1
  fi
  # DWO's proxy lookup tolerates NotFound, but a real OpenShift always has this
  # singleton, so create it with an empty status (== no proxy configured).
  kubectl get proxy cluster >/dev/null 2>&1 || kubectl create -f - <<'EOF' >/dev/null 2>&1 || true
apiVersion: config.openshift.io/v1
kind: Proxy
metadata:
  name: cluster
spec: {}
EOF
  echo "  ✓ config.openshift.io shim installed"
else
  echo "  (config.openshift.io already present — no compatibility shim needed)"
fi

# Create namespace
kubectl create namespace "$NAMESPACE" 2>/dev/null || true
kubectl label namespace "$NAMESPACE" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite 2>/dev/null

# Grant SCCs needed by DevSpaces
oc adm policy add-scc-to-user privileged -z default -n "$NAMESPACE" 2>/dev/null || true
oc adm policy add-scc-to-user anyuid -z default -n "$NAMESPACE" 2>/dev/null || true

# Optional: GitHub OAuth for Dev Spaces git-provider integration.
# See addons/devspaces/README.md for how to set these credentials.
GITHUB_OAUTH_CREDS_FILE="$HOME/.aap-demo/devspaces-github-oauth.env"
if [ -f "$GITHUB_OAUTH_CREDS_FILE" ]; then
  # shellcheck disable=SC1090
  source "$GITHUB_OAUTH_CREDS_FILE"
fi

if [ -n "${GITHUB_OAUTH_CLIENT_ID:-}" ] && [ -n "${GITHUB_OAUTH_CLIENT_SECRET:-}" ]; then
  echo "Configuring GitHub OAuth for Dev Spaces..."
  kubectl create secret generic devspaces-github-oauth-config \
    -n "$NAMESPACE" \
    --from-literal=id="$GITHUB_OAUTH_CLIENT_ID" \
    --from-literal=secret="$GITHUB_OAUTH_CLIENT_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl label secret devspaces-github-oauth-config \
    app.kubernetes.io/part-of=che.eclipse.org \
    app.kubernetes.io/component=oauth-scm-configuration \
    -n "$NAMESPACE" --overwrite
  kubectl annotate secret devspaces-github-oauth-config \
    che.eclipse.org/oauth-scm-server=github \
    -n "$NAMESPACE" --overwrite
  echo "  ✓ GitHub OAuth secret configured"
else
  echo "  (GitHub OAuth not configured — see addons/devspaces/README.md to enable it)"
fi

# ---------------------------------------------------------------------------
# OperatorGroup
# ---------------------------------------------------------------------------
# Both operators are cluster-scoped and only support the AllNamespaces install
# mode. `operator-sdk run bundle` creates an OperatorGroup only if none exists,
# and the one it creates targets the install namespace (OwnNamespace). Create
# the AllNamespaces OperatorGroup ourselves first so both bundle installs share
# a correctly scoped group instead of racing to create conflicting ones.
# Red Hat's Dev Spaces install docs prescribe the same thing when installing
# outside openshift-operators.
if ! kubectl get operatorgroup -n "$NAMESPACE" -o name 2>/dev/null | grep -q .; then
  echo "Creating AllNamespaces OperatorGroup in ${NAMESPACE}..."
  kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: devspaces-operator-group
  namespace: ${NAMESPACE}
spec: {}
EOF
else
  EXISTING_OG=$(kubectl get operatorgroup -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  OG_TARGETS=$(kubectl get operatorgroup -n "$NAMESPACE" -o jsonpath='{.items[0].spec.targetNamespaces}' 2>/dev/null || echo "")
  if [ -n "$OG_TARGETS" ]; then
    echo "WARNING: existing OperatorGroup '${EXISTING_OG}' is namespace-scoped (targetNamespaces=${OG_TARGETS})." >&2
    echo "  DevWorkspace/DevSpaces require AllNamespaces mode. Converting it..." >&2
    kubectl patch operatorgroup "$EXISTING_OG" -n "$NAMESPACE" \
      --type=json -p '[{"op":"remove","path":"/spec/targetNamespaces"}]' 2>/dev/null || true
  fi
fi

csv_phase() {
  kubectl get csv -n "$NAMESPACE" -l "$1" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo ""
}

# Wait for a CSV to reach Succeeded. On timeout, dump full diagnostics.
# Args: <csv-label> <human name> <attempts> (10s apart)
wait_for_csv() {
  local _label="$1" _name="$2" _attempts="$3"
  local _phase=""
  echo "Waiting for ${_name} (up to $((_attempts * 10))s)..."
  for _ in $(seq 1 "$_attempts"); do
    _phase="$(csv_phase "$_label")"
    if [ "$_phase" = "Succeeded" ]; then
      echo "✓ ${_name} installed"
      return 0
    fi
    if [ "$_phase" = "Failed" ]; then
      echo "" >&2
      echo "ERROR: ${_name} CSV entered phase Failed." >&2
      dump_operator_diagnostics "$_name" "$_label"
      return 1
    fi
    printf "."
    sleep 10
  done
  echo "" >&2
  echo "ERROR: ${_name} did not reach phase Succeeded (last phase: ${_phase:-<none>})." >&2
  dump_operator_diagnostics "$_name" "$_label"
  return 1
}

# Install devworkspace-operator first (DevSpaces dependency)
DEVWORKSPACE_BUNDLE="${DEVWORKSPACE_BUNDLE:-registry.redhat.io/devworkspace/devworkspace-operator-bundle:0.39}"

# Grant SCCs for devworkspace
oc adm policy add-scc-to-user privileged -z devworkspace-controller-serviceaccount -n "$NAMESPACE" 2>/dev/null || true

if [ "$(csv_phase "$DW_CSV_LABEL")" = "Succeeded" ]; then
  echo "✓ DevWorkspace operator already installed — skipping bundle install"
else
  echo "Installing DevWorkspace operator (DevSpaces dependency)..."
  if ! operator-sdk run bundle "$DEVWORKSPACE_BUNDLE" \
    --namespace "$NAMESPACE" \
    --timeout 10m 2>&1; then
    echo "WARNING: 'operator-sdk run bundle' reported a failure for devworkspace-operator." >&2
    echo "  Continuing to poll the CSV — the install may still converge." >&2
  fi
fi

# The DevSpaces operator install below will fail in confusing ways if the
# DevWorkspace dependency is not actually running, so stop here rather than
# cascading. Diagnostics are dumped by wait_for_csv.
if ! wait_for_csv "$DW_CSV_LABEL" "DevWorkspace operator" 30; then
  echo "ERROR: aborting — the DevSpaces operator cannot install without a healthy" >&2
  echo "  DevWorkspace operator. See the diagnostics above." >&2
  echo "" >&2
  echo "  If devworkspace-controller-manager is CrashLoopBackOff with an EMPTY log," >&2
  echo "  the config.openshift.io shim did not take effect. Verify with:" >&2
  echo "    kubectl api-resources --api-group=config.openshift.io" >&2
  echo "    kubectl get crd -l aap-demo.redhat.com/shim=openshift-config" >&2
  echo "  and see addons/devspaces/openshift-config-shim.yaml." >&2
  exit 1
fi

# Install DevSpaces operator
DEVSPACES_BUNDLE="${DEVSPACES_BUNDLE:-registry.redhat.io/devspaces/devspaces-operator-bundle:3.26}"

if [ "$(csv_phase "$DS_CSV_LABEL")" = "Succeeded" ]; then
  echo "✓ DevSpaces operator already installed — skipping bundle install"
else
  echo "Installing DevSpaces operator..."
  if ! operator-sdk run bundle "$DEVSPACES_BUNDLE" \
    --namespace "$NAMESPACE" \
    --timeout 10m 2>&1; then
    echo "WARNING: 'operator-sdk run bundle' reported a failure for devspaces-operator." >&2
    echo "  Continuing to poll the CSV — the install may still converge." >&2
  fi
fi

if ! wait_for_csv "$DS_CSV_LABEL" "DevSpaces operator" 30; then
  exit 1
fi

# Apply CheCluster CR
echo "Creating DevSpaces instance..."
kubectl apply -f "${SCRIPT_DIR}/checluster.yaml"

# Wait for DevSpaces to be ready
echo "Waiting for DevSpaces to start (this may take a few minutes)..."
for i in $(seq 1 60); do
  CHE_PHASE=$(kubectl get checluster devspaces -n "$NAMESPACE" -o jsonpath='{.status.chePhase}' 2>/dev/null || echo "")
  if [ "$CHE_PHASE" = "Active" ]; then
    CHE_URL=$(kubectl get checluster devspaces -n "$NAMESPACE" -o jsonpath='{.status.cheURL}' 2>/dev/null || echo "")
    echo ""
    echo "✓ DevSpaces deployed!"
    echo ""
    echo "  URL: ${CHE_URL:-https://devspaces.apps.127.0.0.1.nip.io}"
    echo ""
    exit 0
  fi
  printf "."
  sleep 10
done

echo "" >&2
echo "ERROR: DevSpaces did not reach chePhase=Active within 10 minutes." >&2
CHE_PHASE=$(kubectl get checluster devspaces -n "$NAMESPACE" -o jsonpath='{.status.chePhase}' 2>/dev/null || echo "")
CHE_MSG=$(kubectl get checluster devspaces -n "$NAMESPACE" -o jsonpath='{.status.reason}{" "}{.status.message}' 2>/dev/null || echo "")
echo "  chePhase: ${CHE_PHASE:-<none>}" >&2
[ -n "${CHE_MSG// /}" ] && echo "  status:   ${CHE_MSG}" >&2
dump_operator_diagnostics "DevSpaces (CheCluster)" "$DS_CSV_LABEL"
echo "Check status:" >&2
echo "  kubectl get checluster devspaces -n $NAMESPACE -o yaml" >&2
echo "  kubectl get pods -n $NAMESPACE" >&2
exit 1
