#!/usr/bin/env bash
# Deploy in-cluster container registry for aap-demo
#
# Provides a local registry accessible via:
#   - Route: https://registry.apps.127.0.0.1.nip.io
#   - In-cluster: registry.aap-demo-registry.svc.cluster.local:5000
#
# Usage:
#   ./deploy.sh          # Deploy registry
#   ./deploy.sh --delete # Remove registry

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source CRC SSH helpers for registry mirror configuration
# shellcheck source=../../includes/infra-crc.sh
source "${SCRIPT_DIR}/../../includes/infra-crc.sh" 2>/dev/null || true

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing in-cluster registry..."
  kubectl delete namespace aap-demo-registry 2>/dev/null || true
  kubectl delete clusterrolebinding aap-demo-registry-anyuid 2>/dev/null || true
  echo "✓ Registry removed"
  exit 0
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl not connected to cluster"
  exit 1
fi

echo "Deploying in-cluster container registry..."

kubectl apply -f "${SCRIPT_DIR}/registry.yaml"

echo "Waiting for registry to be ready..."
kubectl wait --for=condition=available deployment/registry -n aap-demo-registry --timeout=120s 2>/dev/null || true

# Configure CRI-O to allow insecure pull from in-cluster registry via ClusterIP
REGISTRY_SVC_IP=$(kubectl get svc registry -n aap-demo-registry -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

if [ -n "$REGISTRY_SVC_IP" ]; then
  # CRC_SSH_KEY and CRC_SSH_OPTS are set when infra-crc.sh is sourced
  if [ -n "$CRC_SSH_KEY" ]; then
    # Add registry mirror: route hostname -> ClusterIP (for CRI-O pulls)
    if ssh -p 2222 "${CRC_SSH_OPTS[@]}" core@127.0.0.1 "sudo tee /etc/containers/registries.conf.d/999-aap-demo-registry.conf > /dev/null <<REGEOF
[[registry]]
location = \"registry.apps.127.0.0.1.nip.io\"
insecure = true
[[registry.mirror]]
location = \"${REGISTRY_SVC_IP}:5000\"
insecure = true
REGEOF" 2>/dev/null && ssh -p 2222 "${CRC_SSH_OPTS[@]}" core@127.0.0.1 'sudo systemctl reload crio' 2>/dev/null; then
      echo "  ✓ CRI-O mirror configured: registry.apps.127.0.0.1.nip.io -> ${REGISTRY_SVC_IP}:5000"
    else
      echo "  ⚠ CRI-O mirror config skipped (SSH unavailable — pods may need imagePullPolicy: Always)"
    fi
  fi
fi

# Wait for the registry route to be reachable — the ingress controller takes
# 10-30s after the pod is ready to configure TLS and start routing traffic.
REGISTRY_ROUTE=$(kubectl get route registry -n aap-demo-registry \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "registry.apps.127.0.0.1.nip.io")
echo "Waiting for registry route to be reachable..."
for _i in $(seq 1 30); do
  if curl -sk --max-time 3 "https://${REGISTRY_ROUTE}/v2/" &>/dev/null; then
    echo "  ✓ Registry route ready"
    break
  fi
  if [ "$_i" -eq 30 ]; then
    echo "  ⚠ Registry route not reachable after 60s — continuing anyway"
  fi
  printf "."
  sleep 2
done
echo ""

echo "✓ In-cluster registry deployed!"
echo ""
echo "  Route:      https://registry.apps.127.0.0.1.nip.io"
echo "  In-cluster: registry.aap-demo-registry.svc.cluster.local:5000"
echo ""
echo "  Push images:"
echo "    podman --connection aap-demo tag <image> registry.apps.127.0.0.1.nip.io/<repo>:<tag>"
echo "    podman --connection aap-demo push --tls-verify=false registry.apps.127.0.0.1.nip.io/<repo>:<tag>"
echo ""
echo "  Use in deployments:"
echo "    image: registry.apps.127.0.0.1.nip.io/<repo>:<tag>"
echo "    imagePullPolicy: Always"
