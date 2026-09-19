#!/usr/bin/env bash
# Regression tests for the Portal addon's Helm detection and auto-install path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_SCRIPT="${REPO_ROOT}/addons/portal/deploy.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

MOCK_BIN="${TEST_DIR}/bin"
mkdir -p "${MOCK_BIN}" "${TEST_DIR}/home"
export HOME="${TEST_DIR}/home"
export PATH="${MOCK_BIN}:/usr/bin:/bin"

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

write_mock_helm() {
  local version="$1"
  cat >"${MOCK_BIN}/helm" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = version ]; then
  printf '%s\\n' "${version}"
else
  exit 0
fi
EOF
  chmod +x "${MOCK_BIN}/helm"
}

rm -f "${MOCK_BIN}/helm"

# shellcheck source=/dev/null
source "${DEPLOY_SCRIPT}"

write_mock_helm 'v3.10.0+g123456'
if helm_version_ok; then
  pass "accepts_minimum_supported_helm"
else
  fail "accepts_minimum_supported_helm"
fi

write_mock_helm 'v3.9.9+g123456'
if ! helm_version_ok; then
  pass "rejects_old_helm"
else
  fail "rejects_old_helm"
fi

write_mock_helm 'v4.0.0+g123456'
if helm_version_ok; then
  pass "accepts_newer_helm"
else
  fail "accepts_newer_helm"
fi

rm -f "${MOCK_BIN}/helm"
INSTALL_CALLED=false
HELM_CHECKS=0
helm_version_ok() {
  HELM_CHECKS=$((HELM_CHECKS + 1))
  [ "${HELM_CHECKS}" -gt 1 ]
}
install_helm_binary() {
  INSTALL_CALLED=true
  write_mock_helm 'v3.21.4+gabcdef'
}

if ensure_helm >/dev/null 2>&1 \
  && [ "${INSTALL_CALLED}" = true ] \
  && [ "${HELM_CHECKS}" -eq 2 ]; then
  pass "auto_installs_when_helm_is_missing"
else
  fail "auto_installs_when_helm_is_missing"
fi

echo "Passed: ${PASSED}  Failed: ${FAILED}"
[ "${FAILED}" -eq 0 ]
