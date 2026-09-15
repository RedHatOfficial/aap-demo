#!/usr/bin/env bash
# Regression tests for the Ollama addon deployment and CLI registration.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OLLAMA_DEPLOY="${REPO_ROOT}/addons/ollama/deploy.sh"
AAP_DEMO="${REPO_ROOT}/aap-demo.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
MOCK_BIN="${TEST_DIR}/bin"
mkdir -p "$MOCK_BIN"

cat >"${MOCK_BIN}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "cluster-info")
    exit 0
    ;;
  "get route aap -n aap-operator -o jsonpath={.spec.host}")
    printf '%s' 'aap.apps.example.test'
    ;;
  "apply -f -")
    cat >"${MOCK_APPLY_FILE}"
    ;;
  rollout\ status\ deployment/ollama\ -n\ aap-demo-ollama\ --timeout=120s)
    exit 0
    ;;
  "get pod -n aap-demo-ollama -l app=ollama -o jsonpath={.items[0].metadata.name}")
    printf '%s' 'ollama-test-pod'
    ;;
  exec\ -n\ aap-demo-ollama\ ollama-test-pod\ --\ ollama\ pull\ qwen2.5:3b)
    exit 0
    ;;
  *)
    echo "unexpected kubectl call: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${MOCK_BIN}/kubectl"

export MOCK_APPLY_FILE="${TEST_DIR}/applied.yaml"
export PATH="${MOCK_BIN}:$PATH"

PASSED=0
FAILED=0

pass() {
  echo "✓ $1"
  ((PASSED++))
}

fail() {
  echo "✗ $1" >&2
  ((FAILED++))
}

if grep -q ' | opa | ollama)' "$AAP_DEMO"; then
  pass "cli_accepts_ollama_addon"
else
  fail "cli_accepts_ollama_addon"
fi

if grep -q 'AVAILABLE_ADDONS=.*ollama' "$AAP_DEMO" \
  && grep -q 'enable ollama' "$AAP_DEMO"; then
  pass "ollama_is_registered_and_documented"
else
  fail "ollama_is_registered_and_documented"
fi

if output=$(OLLAMA_MODEL=qwen2.5:3b "$OLLAMA_DEPLOY" 2>&1); then
  pass "ollama_deploy_completes_with_mock_cluster"
else
  fail "ollama_deploy_completes_with_mock_cluster"
  echo "$output" >&2
fi

if grep -q 'namespace: aap-demo-ollama' "$MOCK_APPLY_FILE" \
  && grep -q 'host: ollama.apps.example.test' "$MOCK_APPLY_FILE" \
  && grep -q 'kind: Deployment' "$MOCK_APPLY_FILE"; then
  pass "deployment_renders_cluster_route"
else
  fail "deployment_renders_cluster_route"
fi

if grep -q 'Model qwen2.5:3b ready' <<<"$output"; then
  pass "deployment_pulls_configured_model"
else
  fail "deployment_pulls_configured_model"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
