#!/usr/bin/env bash
# Deploy AAP Self-Service Portal via Portal CRD
# ADDON_REQUIRES_AAP=true
#
# Installs Portal CRD and creates Portal resource.
# Reconciler watches Portal CRD, renders Helm manifests, applies via kubectl.
#
# Prerequisites:
#   - AAP 2.6+ deployed
#   - Helm 3.10+ installed (for chart templating only)
#
# Usage:
#   ./deploy.sh          # Install portal via CRD
#   ./deploy.sh --delete # Delete portal

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"
PORTAL_NAMESPACE="${PORTAL_NAMESPACE:-aap-portal}"
PORTAL_NAME="${PORTAL_NAME:-automation-portal}"

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Deleting Portal resource..."

  if kubectl get portal "$PORTAL_NAME" -n "$PORTAL_NAMESPACE" &>/dev/null; then
    kubectl delete portal "$PORTAL_NAME" -n "$PORTAL_NAMESPACE"
    echo "✓ Portal resource deleted"
  else
    echo "  Portal resource not found"
  fi

  # Run reconciler once to clean up OAuth app
  if [ -f "$SCRIPT_DIR/reconcile.sh" ]; then
    "$SCRIPT_DIR/reconcile.sh" --once 2>/dev/null || true
  fi

  kubectl delete namespace "$PORTAL_NAMESPACE" --ignore-not-found=true
  echo "✓ Portal namespace deleted"

  exit 0
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl not connected to cluster"
  exit 1
fi

if ! command -v helm &>/dev/null; then
  echo "ERROR: Helm not found (required for chart templating)"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found"
  exit 1
fi

# Check AAP deployed
if ! kubectl get aap aap -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: AAP not deployed in namespace $NAMESPACE"
  exit 1
fi

# Get cluster domain
CLUSTER_DOMAIN=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null | sed 's/^aap-aap-operator\.//' || echo "apps.127.0.0.1.nip.io")

echo "Installing Portal via CRD..."
echo "  AAP namespace: $NAMESPACE"
echo "  Portal namespace: $PORTAL_NAMESPACE"
echo "  Cluster domain: $CLUSTER_DOMAIN"
echo ""

# Install Portal CRD
echo "Installing Portal CRD..."
kubectl apply -f "$SCRIPT_DIR/portal-crd.yaml"

# Add Helm repo if not present (for templating)
if ! helm repo list 2>/dev/null | grep -q "openshift-helm-charts"; then
  echo "Adding OpenShift Helm charts repository (for templating)..."
  helm repo add openshift-helm-charts https://charts.openshift.io/
fi
helm repo update openshift-helm-charts >/dev/null 2>&1

# Create portal namespace
kubectl create namespace "$PORTAL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create Portal resource
echo "Creating Portal resource..."
kubectl apply -f - <<EOF
apiVersion: aap.ansible.com/v1alpha1
kind: Portal
metadata:
  name: ${PORTAL_NAME}
  namespace: ${PORTAL_NAMESPACE}
spec:
  aapNamespace: ${NAMESPACE}
  clusterDomain: ${CLUSTER_DOMAIN}
  chartVersion: "2.2.1"
  organization: "Default"
EOF

echo "✓ Portal resource created"
echo ""

# Run reconciler once to apply immediately
echo "Running reconciler to deploy portal..."
"$SCRIPT_DIR/reconcile.sh" --once

echo ""
echo "Portal deployed via CRD!"
echo ""
echo "Check status:"
echo "  kubectl get portal $PORTAL_NAME -n $PORTAL_NAMESPACE"
echo "  kubectl describe portal $PORTAL_NAME -n $PORTAL_NAMESPACE"
echo ""
echo "To run continuous reconciler (watch for changes):"
echo "  $SCRIPT_DIR/reconcile.sh"
echo ""
