#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deploy_script="${root_dir}/addons/mcp-server/deploy.sh"

if ! grep -Fq 'MCP_ROLLOUT_TIMEOUT="${MCP_ROLLOUT_TIMEOUT:-600s}"' "$deploy_script"; then
  echo "FAIL: MCP rollout timeout must be configurable with a six-minute default" >&2
  exit 1
fi
if ! grep -Fq -- '--timeout="$MCP_ROLLOUT_TIMEOUT"' "$deploy_script"; then
  echo "FAIL: MCP rollout must use the configured timeout" >&2
  exit 1
fi
if ! grep -Fq 'kubectl describe deployment aap-mcp-server' "$deploy_script"; then
  echo "FAIL: MCP rollout failures must print deployment diagnostics" >&2
  exit 1
fi

echo "PASS: MCP rollout timeout and diagnostics are configured"
