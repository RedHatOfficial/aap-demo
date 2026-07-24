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
AAP_ROUTE="aap-${NAMESPACE}"
sed -e "s|namespace: aap-operator|namespace: $NAMESPACE|" \
  -e "s|aap-mcp-aap-operator\.apps|aap-mcp-${NAMESPACE}.apps|g" \
  -e "s|aap-aap-operator|${AAP_ROUTE}|g" \
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
  -o jsonpath='{.data.tls\.crt}' | base64 -d >"${TMPDIR}/chain.pem"

# Split the chain — cert-01 is the self-signed ingress-ca root
awk 'BEGIN {n=0}
     /-----BEGIN CERTIFICATE-----/ {n++; fname=sprintf("'${TMPDIR}'/cert-%02d", n-1)}
     {print > fname}' "${TMPDIR}/chain.pem"
INGRESS_CA="${TMPDIR}/cert-01"

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

# Retrieve admin password from secret
if ! ADMIN_PASS=$(kubectl get secret aap-admin-password -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d); then
  echo "  ⚠ Warning: Could not retrieve admin password from secret 'aap-admin-password'"
  echo "  AAP may not be fully deployed yet. MCP token will not be auto-generated."
  ADMIN_PASS=""
fi

# Validate password was retrieved
if [ -z "$ADMIN_PASS" ]; then
  echo "  ⚠ Warning: Admin password is empty - skipping token generation"
  MCP_TOKEN=""
else
  # Attempt to generate OAuth token
  echo "  Requesting OAuth token from AAP API..."
  CURL_RESPONSE=$(curl -sk -u "admin:${ADMIN_PASS}" \
    "https://aap-${NAMESPACE}.apps.127.0.0.1.nip.io/api/gateway/v1/tokens/" \
    -X POST -H "Content-Type: application/json" \
    -d '{"description":"claude-mcp","scope":"write"}' 2>&1)

  CURL_EXIT=$?

  if [ $CURL_EXIT -ne 0 ]; then
    echo "  ⚠ Warning: curl failed to connect to AAP API (exit code: $CURL_EXIT)"
    echo "  AAP gateway may not be ready yet. Token will not be auto-generated."
    MCP_TOKEN=""
  else
    # Parse token from JSON response
    if ! MCP_TOKEN=$(echo "$CURL_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null); then
      echo "  ⚠ Warning: Failed to parse token from API response"
      echo "  Response: ${CURL_RESPONSE:0:200}"
      MCP_TOKEN=""
    elif [ -z "$MCP_TOKEN" ]; then
      echo "  ⚠ Warning: API returned empty token"
      echo "  Response: ${CURL_RESPONSE:0:200}"
      echo "  AAP gateway may still be starting. Wait a few minutes and re-run."
    else
      echo "  ✓ OAuth token generated successfully"
    fi
  fi
fi

# ── Claude Code configuration ─────────────────────────────────────────────────
CLAUDE_CONFIGURED=false
SSL_FIX_NEEDED=false

if [ -n "$MCP_TOKEN" ]; then
  # Check if claude CLI is available
  if claude --version >/dev/null 2>&1; then
    # Check if server already exists
    if claude mcp get aap-demo >/dev/null 2>&1; then
      echo "  Updating existing MCP server in Claude Code..."
      # Remove and re-add to update the token
      claude mcp remove aap-demo --scope user >/dev/null 2>&1 || true
    else
      echo "  Adding MCP server to Claude Code (user scope)..."
    fi

    # Add (or re-add) the MCP server with current token
    if MCP_OUTPUT=$(claude mcp add aap-demo "https://${MCP_ROUTE}/mcp" \
      --transport http \
      --scope user \
      -e NODE_TLS_REJECT_UNAUTHORIZED=0 \
      --header "Authorization: Bearer ${MCP_TOKEN}" 2>&1); then
      echo "  ✓ MCP server configured in Claude Code user settings"
      CLAUDE_CONFIGURED=true

      # Verify the MCP connection works
      echo "  Verifying MCP connection..."
      if MCP_STATUS=$(claude mcp get aap-demo 2>&1); then
        if echo "$MCP_STATUS" | grep -q "✓ Connected"; then
          echo "  ✓ MCP server is connected and ready"
        elif echo "$MCP_STATUS" | grep -q "✗ Failed to connect"; then
          echo "  ⚠ MCP server configured but connection failed"
        else
          echo "  ⓘ MCP server configured (connection status unknown)"
        fi
      fi
    else
      echo "  ⚠ Warning: Failed to configure MCP server in Claude Code"
      echo "  Error: $MCP_OUTPUT"
    fi
  else
    echo "  ⓘ Claude CLI not found — skipping auto-configuration"
    echo "  See https://github.com/anthropics/claude-code for installation"
  fi
fi

echo ""
echo "✓ AAP MCP Server deployed!"
echo ""
echo "  MCP Endpoint: https://${MCP_ROUTE}/mcp"
echo "  AAP Instance: https://aap-${NAMESPACE}.apps.127.0.0.1.nip.io"
echo ""

# Only show manual configuration if auto-config didn't work
if [ "$CLAUDE_CONFIGURED" = "false" ]; then
  if [ -n "$MCP_TOKEN" ]; then
    echo "  To add manually to Claude Code:"
    echo "    claude mcp add aap-demo https://${MCP_ROUTE}/mcp \\"
    echo "      --transport http \\"
    echo "      --scope user \\"
    echo "      --header \"Authorization: Bearer ${MCP_TOKEN}\""
    echo ""
    echo "  Note: The cluster uses self-signed certificates. If you get SSL errors,"
    echo "  you may need to disable certificate verification in ~/.claude.json:"
    echo "    \"aap-demo\": { ..., \"rejectUnauthorized\": false }"
  else
    echo "  Could not auto-generate token. Get one manually:"
    echo "    curl -sk -u admin:<password> \\"
    echo "      https://aap-${NAMESPACE}.apps.127.0.0.1.nip.io/api/gateway/v1/tokens/ \\"
    echo "      -X POST -H 'Content-Type: application/json' \\"
    echo "      -d '{\"description\":\"claude-mcp\",\"scope\":\"write\"}'"
    echo ""
    echo "  Then add with:"
    echo "    claude mcp add aap-demo https://${MCP_ROUTE}/mcp \\"
    echo "      --transport http \\"
    echo "      --scope user \\"
    echo "      --header \"Authorization: Bearer <token>\""
  fi
fi

echo ""
echo "  MCP Status:  kubectl get ansiblemcpserver -n $NAMESPACE"
echo "  MCP Logs:    kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=aap-mcp-server"
echo ""
if [ -n "$MCP_TOKEN" ]; then
  echo "  NOTE: The OAuth token will expire. Re-run 'aap-demo enable mcp-server'"
  echo "  or generate a new token from the AAP UI to refresh it."
fi
