#!/usr/bin/env bash
# Register the addon-owned read-only OpenShift MCP endpoint with Codex.

set -euo pipefail

MCP_NAMESPACE=${AO_PR_TESTING_MCP_NAMESPACE:-openshift-mcp-server}
MCP_RELEASE=${AO_PR_TESTING_MCP_RELEASE:-ao-pr-testing-openshift-mcp}
CODEX_MCP_NAME=${AO_PR_TESTING_CODEX_MCP_NAME:-openshift-aap-demo}

command -v codex >/dev/null 2>&1 || {
  echo "ERROR: codex is required to register the MCP server" >&2
  exit 1
}
command -v kubectl >/dev/null 2>&1 || {
  echo "ERROR: kubectl is required to discover the MCP route" >&2
  exit 1
}

MCP_ROUTE=$(kubectl get route -n "$MCP_NAMESPACE" \
  -l "app.kubernetes.io/instance=$MCP_RELEASE" \
  -o jsonpath='{.items[0].spec.host}')
[ -n "$MCP_ROUTE" ] || {
  echo "ERROR: OpenShift MCP route not found; enable ao-pr-testing first" >&2
  exit 1
}

MCP_URL="https://$MCP_ROUTE/mcp"
codex mcp remove "$CODEX_MCP_NAME" >/dev/null 2>&1 || true
codex mcp add "$CODEX_MCP_NAME" --url "$MCP_URL"

printf 'Registered Codex MCP server: %s\n' "$CODEX_MCP_NAME"
printf '  URL: %s\n' "$MCP_URL"
printf '  Access: read-only, local route\n'
printf '  Start a new Codex task/session for the server to appear in its tool list.\n'
