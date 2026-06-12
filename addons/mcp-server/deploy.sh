#!/usr/bin/env bash
# Deploy AAP MCP Server
# ADDON_REQUIRES_AAP=true
#
# Deploys the AnsibleMCPServer CR which provides MCP (Model Context Protocol)
# access to AAP functionality for AI assistants and automation tools.
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
sed -e "s|namespace: aap-operator|namespace: $NAMESPACE|" \
  -e "s|aap-mcp-aap-operator\.apps|aap-mcp-${NAMESPACE}.apps|g" \
  "${SCRIPT_DIR}/mcp-server.yaml" | kubectl apply -f -

echo ""
echo "✓ AAP MCP Server deployed!"
echo ""
echo "  MCP Endpoint: https://${MCP_ROUTE}/mcp"
echo "  AAP Instance: https://aap-${NAMESPACE}.apps.127.0.0.1.nip.io"
echo ""
echo "  Status:  kubectl get ansiblemcpserver -n $NAMESPACE"
echo "  Logs:    kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=aap-mcp-server"
echo ""
echo "  Connect your MCP client to:"
echo "    https://${MCP_ROUTE}/mcp"
echo ""
echo "  Note: The MCP server CR is handled by whichever AAP operator is deployed"
echo "  (latest). The AnsibleMCPServer CRD requires AAP operator 2.6+."
echo "  Write operations (POST, DELETE, PATCH) are enabled — dev/test use only."
