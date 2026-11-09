#!/usr/bin/env bash
# Deploy the experimental EDA Playground addon to the current cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="eda-playground"
IMAGE="${EDA_PLAYGROUND_IMAGE:-ghcr.io/bbgrimmett2/eda-playground:0.1.0}"
ACTION="${1:-deploy}"

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [[ "$ACTION" != "--delete" && "$ACTION" != "delete" ]]; }; then
  echo "Usage: $0 [--delete|delete]" >&2
  exit 2
fi

command -v kubectl >/dev/null 2>&1 || {
  echo "ERROR: kubectl is required" >&2
  exit 1
}

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  kubectl cluster-info >/dev/null 2>&1 || {
    echo "ERROR: kubectl is not connected to a cluster; refusing cleanup" >&2
    exit 1
  }

  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Namespace $NAMESPACE does not exist; nothing to delete"
    exit 0
  fi

  MANAGED_BY="$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  if [ "$MANAGED_BY" != "aap-demo-eda-playground" ]; then
    echo "Namespace $NAMESPACE is not owned by the EDA Playground addon; skipping deletion"
    exit 0
  fi

  kubectl delete namespace "$NAMESPACE" --ignore-not-found
  exit 0
fi

kubectl cluster-info >/dev/null 2>&1 || {
  echo "ERROR: kubectl is not connected to a cluster" >&2
  exit 1
}

if [[ "$IMAGE" == *'|'* || "$IMAGE" == *$'\n'* ]]; then
  echo "ERROR: EDA_PLAYGROUND_IMAGE contains unsupported characters" >&2
  exit 2
fi

kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/configmap.yaml"
kubectl apply -f "$SCRIPT_DIR/service.yaml"
sed "s|__EDA_PLAYGROUND_IMAGE__|$IMAGE|g" "$SCRIPT_DIR/deployment.yaml" | kubectl apply -f -

DOMAIN="${EDA_PLAYGROUND_DOMAIN:-}"
if [ -z "$DOMAIN" ]; then
  DOMAIN="$(kubectl get route aap -n "${AAP_NAMESPACE:-aap-operator}" -o jsonpath='{.spec.host}' 2>/dev/null | sed 's/^[^.]*\.//' || true)"
fi
if [ -z "$DOMAIN" ]; then
  echo "ERROR: unable to discover the cluster application domain; set EDA_PLAYGROUND_DOMAIN" >&2
  exit 1
fi
ROUTE_HOST="eda-playground.$DOMAIN"
sed "s|__EDA_PLAYGROUND_ROUTE_HOST__|$ROUTE_HOST|g" "$SCRIPT_DIR/route.yaml" | kubectl apply -f -

if command -v oc >/dev/null 2>&1; then
  oc adm policy add-scc-to-user anyuid -z eda-playground -n "$NAMESPACE" >/dev/null
fi

echo "EDA Playground manifests applied in namespace $NAMESPACE"
echo "Route: https://$ROUTE_HOST"
