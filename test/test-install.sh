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

# The Python command (pipx) owns ~/.local/bin/aap-demo: install and uninstall
# must leave it alone.
PY_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME" "$PY_HOME"' EXIT
mkdir -p "$PY_HOME/venv/bin" "$PY_HOME/.local/bin"
printf '#!%s\nprint("python")\n' "$PY_HOME/venv/bin/python" >"$PY_HOME/venv/bin/aap-demo"
chmod +x "$PY_HOME/venv/bin/aap-demo"
ln -s "$PY_HOME/venv/bin/aap-demo" "$PY_HOME/.local/bin/aap-demo"

out="$(HOME="$PY_HOME" bash "$SCRIPT_DIR/install.sh" 2>&1)"
if [ "$(readlink "$PY_HOME/.local/bin/aap-demo")" != "$PY_HOME/venv/bin/aap-demo" ]; then
  echo "install.sh replaced the Python command" >&2
  exit 1
fi
grep -q 'pipx uninstall aap-demo' <<<"$out"
echo "✓ install_keeps_python_cli"

HOME="$PY_HOME" bash "$SCRIPT_DIR/install.sh" --uninstall >/dev/null
[ -L "$PY_HOME/.local/bin/aap-demo" ] || {
  echo "uninstall removed the Python command" >&2
  exit 1
}
echo "✓ uninstall_keeps_python_cli"

# A link to the bash script is still removed by uninstall.
rm "$PY_HOME/.local/bin/aap-demo"
ln -s "$SCRIPT_DIR/aap-demo.sh" "$PY_HOME/.local/bin/aap-demo"
HOME="$PY_HOME" bash "$SCRIPT_DIR/install.sh" --uninstall >/dev/null
if [ -e "$PY_HOME/.local/bin/aap-demo" ] || [ -L "$PY_HOME/.local/bin/aap-demo" ]; then
  echo "uninstall left the bash link" >&2
  exit 1
fi
echo "✓ uninstall_removes_bash_link"
