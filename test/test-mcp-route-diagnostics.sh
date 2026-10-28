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

mock_bin="$(mktemp -d)"
trap 'rm -rf "$mock_bin"' EXIT
cat >"$mock_bin/getent" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
chmod +x "$mock_bin/getent"

route_diagnostics="$(sed -n \
  '/^_mcp_route_resolves()/,/^}/p; /^_mcp_report_route_resolution()/,/^}/p' \
  "$deploy_script")"
eval "$route_diagnostics"
if PATH="$mock_bin" _mcp_route_resolves invalid.example; then
  echo "FAIL: getent exit status 2 was treated as resolved" >&2
  exit 1
fi

resolver_status=0
PATH="$mock_bin" _mcp_route_resolves invalid.example || resolver_status=$?
if [ "$resolver_status" -ne 1 ]; then
  echo "FAIL: getent exit status 2 was not normalized to unresolved (status 1)" >&2
  exit 1
fi

diagnostics="$(PATH="$mock_bin" _mcp_report_route_resolution invalid.example || true)"
grep -Fq 'MCP route hostname does not resolve' <<<"$diagnostics"
if grep -Fq 'Cannot check MCP route DNS' <<<"$diagnostics"; then
  echo "FAIL: getent exit status 2 selected the unavailable-DNS diagnostic" >&2
  exit 1
fi

echo "PASS: MCP connection failures include host-route DNS diagnostics"
