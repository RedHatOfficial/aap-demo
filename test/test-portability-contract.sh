#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

PASSED=0
FAILED=0

pass() {
  echo "✓ $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo "✗ $1" >&2
  FAILED=$((FAILED + 1))
}

export HOME="${TEST_DIR}/home"
export AAP_DEMO_DIR="${TEST_DIR}/custom state"
export AAP_DEMO_CONFIG="${TEST_DIR}/custom config/settings"
mkdir -p "$HOME" "$AAP_DEMO_DIR" "$(dirname "$AAP_DEMO_CONFIG")"

# shellcheck source=includes/aap-demo-paths.sh
source "${REPO_ROOT}/includes/aap-demo-paths.sh"

if [ "$AAP_DEMO_KUBECONFIG" = "$AAP_DEMO_DIR/kubeconfig.microshift" ] \
  && [ "$(bash -c 'printf "%s|%s" "$AAP_DEMO_DIR" "$AAP_DEMO_KUBECONFIG"')" \
    = "$AAP_DEMO_DIR|$AAP_DEMO_DIR/kubeconfig.microshift" ]; then
  pass "custom data paths are exported to child addon processes"
else
  fail "custom data paths are exported to child addon processes"
fi

printf 'CRC_PRESET=openshift\n' >"$AAP_DEMO_CONFIG"
# shellcheck source=includes/infra-crc.sh
source "${REPO_ROOT}/includes/infra-crc.sh"
if [ "$(_detect_crc_preset)" = "openshift" ]; then
  pass "CRC backend reads the overridden config file"
else
  fail "CRC backend reads the overridden config file"
fi

# shellcheck source=includes/temp-swap.sh
source "${REPO_ROOT}/includes/temp-swap.sh"
if [ "$(aap_demo_temp_swap_marker_path)" = "$AAP_DEMO_DIR/.temp-swap-active" ]; then
  pass "host preparation state follows the overridden data directory"
else
  fail "host preparation state follows the overridden data directory"
fi

if grep -R -E 'kubectl create namespace .*(2>/dev/null )?\|\| true' \
  "${REPO_ROOT}/aap-demo.sh" "${REPO_ROOT}/addons" --include='*.sh' >/dev/null; then
  fail "namespace convergence does not hide API failures"
else
  pass "namespace convergence does not hide API failures"
fi

namespace_commands=$(grep -R -E 'kubectl create namespace ' \
  "${REPO_ROOT}/aap-demo.sh" "${REPO_ROOT}/addons" --include='*.sh' || true)
if [ -n "$namespace_commands" ] \
  && ! printf '%s\n' "$namespace_commands" | grep -v -- '--dry-run=client' >/dev/null; then
  pass "namespace creation uses repeatable dry-run/apply manifests"
else
  fail "namespace creation uses repeatable dry-run/apply manifests"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
