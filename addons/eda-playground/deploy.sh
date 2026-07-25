#!/usr/bin/env bash
# Deploy EDA Playground to aap-demo
#
# Deploys EDA Playground - an interactive web-based tool for testing and
# experimenting with Event-Driven Ansible integrations and webhooks.
#
# Prerequisites:
#   - kubectl connected to cluster
#
# Usage:
#   ./deploy.sh          # Deploy EDA Playground
#   ./deploy.sh --delete # Remove EDA Playground

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-eda-playground}"

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing EDA Playground..."
  kubectl delete namespace "$NAMESPACE" 2>/dev/null || true
  echo "✓ EDA Playground removed"
  exit 0
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl not connected to cluster"
  exit 1
fi

echo "Deploying EDA Playground..."

# Apply manifests
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/configmap.yaml"
kubectl apply -f "${SCRIPT_DIR}/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/route.yaml"

# Grant anyuid SCC for the deployment (needed for OpenShift/MicroShift)
oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${NAMESPACE}" 2>/dev/null || true

# Wait for deployment to be ready
echo "  Waiting for deployment to be ready..."
kubectl wait --for=condition=available deployment/eda-playground \
  -n "$NAMESPACE" --timeout=120s 2>/dev/null || {
  echo "  ⚠ Warning: Deployment not ready after 120s"
  echo "  Check: kubectl get pods -n $NAMESPACE"
}

# Get route hostname
ROUTE_HOST=$(kubectl get route eda-playground -n "$NAMESPACE" \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "eda-playground.apps.127.0.0.1.nip.io")

echo ""
echo "✓ EDA Playground deployed!"
echo ""
echo "  URL:       https://${ROUTE_HOST}"
echo "  Namespace: ${NAMESPACE}"
echo ""
echo "  Status:  kubectl get pods -n ${NAMESPACE}"
echo "  Logs:    kubectl logs -n ${NAMESPACE} -l app=eda-playground"
echo ""
echo "  EDA Playground provides an interactive environment for testing"
echo "  Event-Driven Ansible integrations and webhook payloads."
echo ""
