#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT

mkdir -p "$TEST_HOME/.aap-demo"
cat >"$TEST_HOME/.aap-demo/config" <<'EOF'
INFRA=crc
ADDONS=ao,portal
EOF

HOME="$TEST_HOME" bash "$SCRIPT_DIR/install.sh" --uninstall >/dev/null

grep -q '^INFRA=crc$' "$TEST_HOME/.aap-demo/config"
if grep -q '^ADDONS=' "$TEST_HOME/.aap-demo/config"; then
  echo "ADDONS state was not removed during uninstall" >&2
  exit 1
fi

echo "✓ uninstall_clears_addon_state"
