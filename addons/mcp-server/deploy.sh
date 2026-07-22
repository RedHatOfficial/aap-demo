#!/usr/bin/env bash
# Deploy AAP MCP Server
# ADDON_REQUIRES_AAP=true
#
# Deploys the AnsibleMCPServer CR which provides MCP (Model Context Protocol)
# access to AAP functionality for AI assistants and automation tools.
#
# After deployment, patches the MCP server pod to trust the cluster's self-signed
# ingress CA cert (NODE_EXTRA_CA_CERTS) — required for token validation against AAP.
# Also generates an AAP OAuth token and prints Claude Code configuration.
#
# Prerequisites:
#   - AAP operator installed and AAP CR deployed
#   - AnsibleMCPServer CRD available (included in AAP operator 2.6+)
#
# Usage:
#   ./deploy.sh          # Deploy MCP server
#   ./deploy.sh --delete # Remove MCP server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing AAP MCP Server..."
  kubectl delete ansiblemcpserver aap-mcp-server -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete configmap aap-ingress-ca -n "$NAMESPACE" 2>/dev/null || true
  echo "✓ MCP Server removed"
  exit 0
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl not connected to cluster"
  exit 1
fi

# Check AAP operator is running
if ! kubectl get csv -n "$NAMESPACE" 2>/dev/null | grep -q "aap-operator"; then
  echo "WARNING: AAP operator not found in namespace '$NAMESPACE'"
  echo "  Deploy AAP first: aap-demo deploy"
  echo "  Proceeding anyway (CR will reconcile once operator is ready)..."
fi

# Check if AnsibleMCPServer CRD exists
if ! kubectl get crd ansiblemcpservers.mcpserver.ansible.com &>/dev/null; then
  echo "WARNING: AnsibleMCPServer CRD not found"
  echo "  This CRD is included in AAP operator 2.6+"
  echo "  Proceeding anyway (CR will be applied once CRD is available)..."
fi

# Check pull secret exists
if ! kubectl get secret -n "$NAMESPACE" redhat-operators-pull-secret &>/dev/null; then
  echo "WARNING: Pull secret 'redhat-operators-pull-secret' not found in $NAMESPACE"
  echo "  MCP server pod may fail to pull images without it"
fi

echo "Deploying AAP MCP Server..."

# Apply the CR with namespace and hostname substitution
MCP_ROUTE="aap-mcp-${NAMESPACE}.apps.127.0.0.1.nip.io"
AAP_ROUTE="aap-${NAMESPACE}.apps.127.0.0.1.nip.io"
sed -e "s|namespace: aap-operator|namespace: $NAMESPACE|" \
  -e "s|aap-mcp-aap-operator\.apps|aap-mcp-${NAMESPACE}.apps|g" \
  -e "s|aap-aap-operator\.apps|${AAP_ROUTE}.apps|g" \
  "${SCRIPT_DIR}/mcp-server.yaml" | kubectl apply -f -

echo "  Waiting for MCP server deployment..."
# Wait up to 3 minutes for the deployment to appear (operator may take a moment)
for i in $(seq 1 18); do
  if kubectl get deployment aap-mcp-server -n "$NAMESPACE" &>/dev/null; then
    break
  fi
  sleep 10
done

kubectl rollout status deployment/aap-mcp-server -n "$NAMESPACE" --timeout=120s

# ── Ingress CA fix ────────────────────────────────────────────────────────────
# The MCP server validates AAP bearer tokens by calling back to the AAP API over
# HTTPS. Node.js (undici) does not honour REQUESTS_CA_BUNDLE or SSL_CERT_FILE —
# it needs NODE_EXTRA_CA_CERTS. The cluster's ingress uses a self-signed CA
# (ingress-ca) that is not in the system bundle, so we extract it and inject it.
echo "  Applying ingress CA fix (NODE_EXTRA_CA_CERTS)..."

# Extract the ingress CA cert from the router secret (cert-01 in the chain)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

kubectl get secret router-certs-default -n openshift-ingress \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "${TMPDIR}/chain.pem"

# Split the chain — cert-01 is the self-signed ingress-ca root
csplit -z "${TMPDIR}/chain.pem" '/-----BEGIN CERTIFICATE-----/' '{*}' \
  -f "${TMPDIR}/cert-" --suffix-format='%02d.pem' -s
INGRESS_CA="${TMPDIR}/cert-01.pem"

# Create/update the ConfigMap with the ingress CA cert
kubectl create configmap aap-ingress-ca \
  -n "$NAMESPACE" \
  --from-file=ca.crt="${INGRESS_CA}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Patch the deployment to mount the CA and set NODE_EXTRA_CA_CERTS.
# Check whether the patch is already applied before patching to make the script
# idempotent on re-runs.
if ! kubectl get deployment aap-mcp-server -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.volumes}' | grep -q aap-ingress-ca; then

  kubectl patch deployment aap-mcp-server -n "$NAMESPACE" --type='json' -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/volumes/-",
      "value": {"name": "ingress-ca", "configMap": {"name": "aap-ingress-ca"}}
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/volumeMounts/-",
      "value": {"name": "ingress-ca", "mountPath": "/etc/ssl/ingress-ca", "readOnly": true}
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/env/-",
      "value": {"name": "NODE_EXTRA_CA_CERTS", "value": "/etc/ssl/ingress-ca/ca.crt"}
    }
  ]'

  kubectl rollout status deployment/aap-mcp-server -n "$NAMESPACE" --timeout=120s
fi

# ── Generate AAP OAuth token ──────────────────────────────────────────────────
echo "  Generating AAP OAuth token..."
ADMIN_PASS=$(kubectl get secret aap-admin-password -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' | base64 -d)

MCP_TOKEN=$(curl -sk -u "admin:${ADMIN_PASS}" \
  "https://aap-${NAMESPACE}.apps.127.0.0.1.nip.io/api/gateway/v1/tokens/" \
  -X POST -H "Content-Type: application/json" \
  -d '{"description":"claude-mcp","scope":"write"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)

# ── Claude Code configuration ─────────────────────────────────────────────────
# Find the project root (where .claude/ lives) relative to this addon
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLAUDE_SETTINGS="${PROJECT_ROOT}/.claude/settings.json"

if [ -f "$CLAUDE_SETTINGS" ] && [ -n "$MCP_TOKEN" ]; then
  # Merge the mcpServers entry into the existing settings file using python
  python3 - <<PYEOF
import json, sys

path = "${CLAUDE_SETTINGS}"
with open(path) as f:
    settings = json.load(f)

settings.setdefault("mcpServers", {})["aap"] = {
    "type": "http",
    "url": "https://${MCP_ROUTE}/mcp",
    "headers": {"Authorization": "Bearer ${MCP_TOKEN}"}
}

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("  ✓ Claude Code settings updated: ${CLAUDE_SETTINGS}")
PYEOF
fi

echo ""
echo "✓ AAP MCP Server deployed!"
echo ""
echo "  MCP Endpoint: https://${MCP_ROUTE}/mcp"
echo "  AAP Instance: https://aap-${NAMESPACE}.apps.127.0.0.1.nip.io"
echo ""
if [ -n "$MCP_TOKEN" ]; then
  echo "  Claude Code is configured — restart Claude Code to load the MCP server."
  echo ""
  echo "  Or add manually to .claude/settings.json:"
  echo '  {'
  echo '    "mcpServers": {'
  echo '      "aap": {'
  echo '        "type": "http",'
  echo "        \"url\": \"https://${MCP_ROUTE}/mcp\","
  echo "        \"headers\": {\"Authorization\": \"Bearer ${MCP_TOKEN}\"}"
  echo '      }'
  echo '    }'
  echo '  }'
else
  echo "  Could not auto-generate token. Get one manually:"
  echo "    curl -sk -u admin:<password> \\"
  echo "      https://aap-${NAMESPACE}.apps.127.0.0.1.nip.io/api/gateway/v1/tokens/ \\"
  echo "      -X POST -H 'Content-Type: application/json' \\"
  echo "      -d '{\"description\":\"claude-mcp\",\"scope\":\"write\"}'"
  echo ""
  echo "  Then add to .claude/settings.json:"
  echo '  {'
  echo '    "mcpServers": {'
  echo '      "aap": {'
  echo '        "type": "http",'
  echo "        \"url\": \"https://${MCP_ROUTE}/mcp\","
  echo '        "headers": {"Authorization": "Bearer <token>"}'
  echo '      }'
  echo '    }'
  echo '  }'
fi
echo ""
echo "  Status:  kubectl get ansiblemcpserver -n $NAMESPACE"
echo "  Logs:    kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=aap-mcp-server"
echo ""
echo "  NOTE: The token written to settings.json will expire. Re-run this script"
echo "  or generate a new token from the AAP UI to refresh it."
