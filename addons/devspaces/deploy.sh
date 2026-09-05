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
NAMESPACE="openshift-devspaces"

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing DevSpaces..."
  kubectl delete checluster devspaces -n "$NAMESPACE" 2>/dev/null || true
  # Wait for CheCluster finalizers
  echo "Waiting for CheCluster cleanup..."
  kubectl wait --for=delete checluster/devspaces -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  # Remove operator
  kubectl delete sub devspaces -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete csv -n "$NAMESPACE" -l operators.coreos.com/devspaces.openshift-devspaces 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" 2>/dev/null || true
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

echo "Deploying OpenShift DevSpaces..."

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

# Install devworkspace-operator first (DevSpaces dependency)
echo "Installing DevWorkspace operator (DevSpaces dependency)..."
DEVWORKSPACE_BUNDLE="registry.redhat.io/devworkspace/devworkspace-operator-bundle:0.39"

# Grant SCCs for devworkspace
oc adm policy add-scc-to-user privileged -z devworkspace-controller-serviceaccount -n "$NAMESPACE" 2>/dev/null || true

if ! operator-sdk run bundle "$DEVWORKSPACE_BUNDLE" \
  --namespace "$NAMESPACE" \
  --timeout 10m 2>&1; then
  echo "WARNING: devworkspace-operator install may have timed out."
fi

# Wait for devworkspace operator
echo "Waiting for DevWorkspace operator..."
for i in $(seq 1 30); do
  DW_PHASE=$(kubectl get csv -n "$NAMESPACE" -l operators.coreos.com/devworkspace-operator.openshift-devspaces -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  if [ "$DW_PHASE" = "Succeeded" ]; then
    echo "✓ DevWorkspace operator installed"
    break
  fi
  sleep 10
done

# Install DevSpaces operator
echo "Installing DevSpaces operator..."
DEVSPACES_BUNDLE="registry.redhat.io/devspaces/devspaces-operator-bundle:3.26"

if ! operator-sdk run bundle "$DEVSPACES_BUNDLE" \
  --namespace "$NAMESPACE" \
  --timeout 10m 2>&1; then
  echo ""
  echo "WARNING: operator-sdk bundle install may have timed out."
  echo "Check status: kubectl get csv -n $NAMESPACE"
  echo ""
fi

# Wait for operator CSV
echo "Waiting for DevSpaces operator..."
for i in $(seq 1 30); do
  CSV_PHASE=$(kubectl get csv -n "$NAMESPACE" -l operators.coreos.com/devspaces.openshift-devspaces -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  if [ "$CSV_PHASE" = "Succeeded" ]; then
    echo "✓ DevSpaces operator installed"
    break
  fi
  sleep 10
done

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

echo ""
echo "DevSpaces not fully ready yet. Check status:"
echo "  kubectl get checluster devspaces -n $NAMESPACE"
echo "  kubectl get pods -n $NAMESPACE"
