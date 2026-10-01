#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wire_script="$(cat "${repo_root}/includes/addon-wire.sh")"

if grep -q 'discovered_tools_json' <<<"$wire_script"; then
  echo '✗ AO MCP integration must not embed an unbounded discovery result in create payloads' >&2
  exit 1
fi
if ! grep -q 'MCP discovery probe failed; AO will retry during refresh' <<<"$wire_script"; then
  echo '✗ AO MCP integration must tolerate a failed discovery probe' >&2
  exit 1
fi
if ! grep -q 'wire_ao_enable_all_tools' <<<"$wire_script"; then
  echo '✗ AO MCP integration must refresh and enable tools after creation' >&2
  exit 1
fi

echo 'AO MCP integration checks passed'
