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

# Pull model via in-cluster ClusterIP (avoids nip.io resolution issues in scripts)
OLLAMA_SVC_IP=$(kubectl get svc ollama -n aap-demo-ollama \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

if [ -n "$OLLAMA_SVC_IP" ]; then
  echo "  Pulling model: ${OLLAMA_MODEL}..."
  echo "  (This may take several minutes — model is ~2.5GB)"

  _pull_done=false
  for _i in $(seq 1 60); do
    _resp=$(curl -s --max-time 10 -X POST \
      "http://${OLLAMA_SVC_IP}:11434/api/pull" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${OLLAMA_MODEL}\",\"stream\":false}" 2>/dev/null || true)
    if echo "$_resp" | grep -q '"status":"success"'; then
      _pull_done=true
      echo "  ✓ Model ${OLLAMA_MODEL} ready"
      break
    elif echo "$_resp" | grep -q '"error"'; then
      echo "  ⚠ Pull error: $(echo "$_resp" | grep -o '"error":"[^"]*"' | head -1)"
      break
    fi
    printf "."
    sleep 5
  done
  echo ""
  if [ "$_pull_done" = false ]; then
    echo "  ⚠ Model pull did not complete within 5 minutes"
    echo "  Pull manually: curl -X POST http://${OLLAMA_SVC_IP}:11434/api/pull"
    echo "    -d '{\"name\":\"${OLLAMA_MODEL}\",\"stream\":false}'"
  fi
else
  echo "  ⚠ Could not determine service ClusterIP — skipping model pull"
  echo "  Pull manually after deploy: aap-demo enable ollama  (re-run is safe)"
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
echo ""

# Wire into AO if present
if [ "${AAP_DEMO_WIRE_AFTER_DEPLOY:-0}" != "0" ]; then
  # shellcheck source=../../includes/addon-wire.sh
  source "${SCRIPT_DIR}/../../includes/addon-wire.sh"
  aap_demo_wire || true
fi
