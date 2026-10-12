#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deploy_script="${repo_root}/addons/mcp-server/deploy.sh"
readme="${repo_root}/addons/mcp-server/README.md"

grep -Fq '_mcp_route_resolves' "$deploy_script"
grep -Fq '_mcp_report_route_resolution' "$deploy_script"
grep -Fq 'getent hosts' "$deploy_script"
grep -Fq 'dscacheutil -q host' "$deploy_script"
grep -Fq 'MCP route hostname does not resolve' "$deploy_script"
grep -Fq 'aap-demo status' "$deploy_script"
grep -Fq 'aap-demo start' "$deploy_script"
grep -Fq 'host-side DNS' "$readme"

echo "PASS: MCP connection failures include host-route DNS diagnostics"
