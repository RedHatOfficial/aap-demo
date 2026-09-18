#!/usr/bin/env bash
# Deploy Ollama LLM server for aap-demo
#
# Deploys Ollama (CPU-only) with qwen2.5:3b model pre-pulled.
# Accessible via:
#   - Route: https://ollama.apps.<cluster-domain>
#   - OpenAI-compatible: https://ollama.apps.<cluster-domain>/v1
#   - In-cluster: http://ollama.aap-demo-ollama.svc.cluster.local:11434
#
# Usage:
#   ./deploy.sh          # Deploy Ollama and pull qwen2.5:3b
#   ./deploy.sh --delete # Remove Ollama

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:3b}"
OLLAMA_ROLLOUT_TIMEOUT="${OLLAMA_ROLLOUT_TIMEOUT:-15m}"
OLLAMA_STORAGE_CLASS="${OLLAMA_STORAGE_CLASS:-}"

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

# Detect StorageClass: explicit override > topolvm-provisioner > standard
if [ -n "$OLLAMA_STORAGE_CLASS" ]; then
  _ollama_sc="$OLLAMA_STORAGE_CLASS"
elif kubectl get sc topolvm-provisioner >/dev/null 2>&1; then
  _ollama_sc="topolvm-provisioner"
elif kubectl get sc standard >/dev/null 2>&1; then
  _ollama_sc="standard"
else
  echo "ERROR: No suitable StorageClass found (expected topolvm-provisioner or standard)." >&2
  echo "  Set OLLAMA_STORAGE_CLASS=<name> to use a different class, or run 'aap-demo create'." >&2
  exit 1
fi
echo "  StorageClass: ${_ollama_sc}"

# Detect cluster apps domain from existing AAP route, fall back to nip.io default
_aap_host=$(kubectl get route aap -n "${NAMESPACE:-aap-operator}" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -n "$_aap_host" ]; then
  CLUSTER_DOMAIN="${_aap_host#*.}"
else
  CLUSTER_DOMAIN="apps.127.0.0.1.nip.io"
fi
OLLAMA_ROUTE="ollama.${CLUSTER_DOMAIN}"

# Patch the route hostname and StorageClass from their manifest placeholders
sed -e "s|host: ollama\.apps\.127\.0\.0\.1\.nip\.io|host: ${OLLAMA_ROUTE}|" \
  -e "s|storageClassName: __STORAGE_CLASS__|storageClassName: ${_ollama_sc}|" \
  "${SCRIPT_DIR}/ollama.yaml" | kubectl apply -f -

echo "  Waiting for Ollama deployment to be ready..."
if ! kubectl rollout status deployment/ollama -n aap-demo-ollama \
  --timeout="${OLLAMA_ROLLOUT_TIMEOUT}"; then
  echo "ERROR: Ollama rollout failed — diagnostics:" >&2
  kubectl get deployment,pod,pvc -n aap-demo-ollama >&2 || true
  kubectl describe pod -n aap-demo-ollama -l app=ollama >&2 || true
  kubectl get events -n aap-demo-ollama --sort-by=.lastTimestamp >&2 || true
  exit 1
fi

echo "  Pulling model: ${OLLAMA_MODEL}..."
echo "  (This may take several minutes — model is ~2.5GB)"

# Pull model inside the pod — avoids ClusterIP routing issues on the CRC host
OLLAMA_POD=$(kubectl get pod -n aap-demo-ollama -l app=ollama \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -n "$OLLAMA_POD" ]; then
  if kubectl exec -n aap-demo-ollama "$OLLAMA_POD" -- ollama pull "${OLLAMA_MODEL}"; then
    echo "  ✓ Model ${OLLAMA_MODEL} ready"
  else
    echo "  ERROR: Model pull failed — retry:" >&2
    echo "    kubectl exec -n aap-demo-ollama $OLLAMA_POD -- ollama pull ${OLLAMA_MODEL}"
    exit 1
  fi
else
  echo "  ERROR: Could not find Ollama pod — retry: aap-demo enable ollama" >&2
  exit 1
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
