#!/usr/bin/env bash
# Deploy Ollama LLM server for aap-demo
#
# Deploys Ollama (CPU-only) with phi4-mini model pre-pulled.
# Accessible via:
#   - Route: https://ollama.apps.<cluster-domain>
#   - OpenAI-compatible: https://ollama.apps.<cluster-domain>/v1
#   - In-cluster: http://ollama.aap-demo-ollama.svc.cluster.local:11434
#
# Usage:
#   ./deploy.sh          # Deploy Ollama and pull phi4-mini
#   ./deploy.sh --delete # Remove Ollama

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_MODEL="${OLLAMA_MODEL:-phi4-mini}"

# shellcheck source=../../includes/infra-crc.sh
source "${SCRIPT_DIR}/../../includes/infra-crc.sh" 2>/dev/null || true

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing Ollama..."
  kubectl delete namespace aap-demo-ollama 2>/dev/null || true
  kubectl delete clusterrolebinding aap-demo-ollama-anyuid 2>/dev/null || true
  echo "✓ Ollama removed"
  exit 0
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl not connected to cluster"
  exit 1
fi

echo "Deploying Ollama (CPU-only)..."

# Detect cluster apps domain from existing AAP route, fall back to nip.io default
_aap_host=$(kubectl get route aap -n "${NAMESPACE:-aap-operator}" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -n "$_aap_host" ]; then
  CLUSTER_DOMAIN="${_aap_host#*.}"
else
  CLUSTER_DOMAIN="apps.127.0.0.1.nip.io"
fi
OLLAMA_ROUTE="ollama.${CLUSTER_DOMAIN}"

# Patch the route hostname if cluster domain differs from the nip.io default in the manifest
sed "s|host: ollama\.apps\.127\.0\.0\.1\.nip\.io|host: ${OLLAMA_ROUTE}|" \
  "${SCRIPT_DIR}/ollama.yaml" | kubectl apply -f -

echo "  Waiting for Ollama deployment to be ready..."
kubectl rollout status deployment/ollama -n aap-demo-ollama --timeout=120s

echo "  Pulling model: ${OLLAMA_MODEL}..."
echo "  (This may take several minutes — model is ~2.5GB)"

# Pull model inside the pod — avoids ClusterIP routing issues on the CRC host
OLLAMA_POD=$(kubectl get pod -n aap-demo-ollama -l app=ollama \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -n "$OLLAMA_POD" ]; then
  if kubectl exec -n aap-demo-ollama "$OLLAMA_POD" -- ollama pull "${OLLAMA_MODEL}"; then
    echo "  ✓ Model ${OLLAMA_MODEL} ready"
  else
    echo "  ⚠ Model pull failed — retry:"
    echo "    kubectl exec -n aap-demo-ollama $OLLAMA_POD -- ollama pull ${OLLAMA_MODEL}"
  fi
else
  echo "  ⚠ Could not find Ollama pod — retry: aap-demo enable ollama  (re-run is safe)"
fi

echo ""
echo "✓ Ollama deployed!"
echo ""
echo "  Route:         https://${OLLAMA_ROUTE}"
echo "  OpenAI base:   https://${OLLAMA_ROUTE}/v1"
echo "  In-cluster:    http://ollama.aap-demo-ollama.svc.cluster.local:11434"
echo "  Model:         ${OLLAMA_MODEL}"
echo ""
echo "  Test inference:"
echo "    curl https://${OLLAMA_ROUTE}/api/generate \\"
echo "      -d '{\"model\":\"${OLLAMA_MODEL}\",\"prompt\":\"Hello\",\"stream\":false}'"
echo ""
echo "  List models:   curl https://${OLLAMA_ROUTE}/api/tags"
echo ""
echo "  Pull additional model:"
echo "    OLLAMA_MODEL=mistral:7b aap-demo enable ollama"
echo "    # or directly:"
echo "    kubectl exec -n aap-demo-ollama \$(kubectl get pod -n aap-demo-ollama -l app=ollama -o jsonpath='{.items[0].metadata.name}') -- ollama pull mistral:7b"
echo ""

# Wire into AO if present
if [ "${AAP_DEMO_WIRE_AFTER_DEPLOY:-0}" != "0" ]; then
  # shellcheck source=../../includes/addon-wire.sh
  source "${SCRIPT_DIR}/../../includes/addon-wire.sh"
  aap_demo_wire || true
fi
