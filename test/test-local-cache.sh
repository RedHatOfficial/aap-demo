#!/usr/bin/env bash
# Regression tests for local-cache load result handling.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CACHE_SCRIPT="${REPO_ROOT}/addons/local-cache/deploy.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

MOCK_BIN="${TEST_DIR}/bin"
MOCK_HOME="${TEST_DIR}/home"
mkdir -p "$MOCK_BIN" "$MOCK_HOME/.aap-demo/local-cache/microshift"

printf 'registry.example.test/image:latest\n' \
  >"$MOCK_HOME/.aap-demo/local-cache/microshift/test.ref"
touch "$MOCK_HOME/.aap-demo/local-cache/microshift/test.tar"

cat >"${MOCK_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${MOCK_BIN}/ssh"

cat >"${MOCK_BIN}/crc" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  config\ get\ ssh-key) printf '%s\n' '/tmp/test-crc-key' ;;
  config\ get\ preset) printf '%s\n' 'microshift' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${MOCK_BIN}/crc"

export HOME="$MOCK_HOME"
export PATH="$MOCK_BIN:$PATH"
export CRC_SSH_KEY=/tmp/test-crc-key
export CRC_SSH_PORT=2222

if "$CACHE_SCRIPT" load >/dev/null 2>&1; then
  echo "✗ explicit cache load should fail when an image import fails" >&2
  exit 1
fi
echo "✓ explicit cache load reports failed imports"

if ! AAP_DEMO_LOCAL_CACHE_QUIET=1 "$CACHE_SCRIPT" load >/dev/null 2>&1; then
  echo "✗ quiet cache load should remain non-fatal for deploy optimization" >&2
  exit 1
fi
echo "✓ quiet cache load remains non-fatal"
