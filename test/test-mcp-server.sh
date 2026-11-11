#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/addons/mcp-server/mcp-server.yaml"
DOC="$REPO_ROOT/docs/aap-mcp-server.md"

analytics_block=$(grep -A2 -- '- setting: ANALYTICS_KEY' "$MANIFEST")
grep -q "value: ' '" <<<"$analytics_block"
grep -q 'does not resolve `api.segment.io`' "$DOC"

echo "✓ mcp_local_analytics_is_disabled"
