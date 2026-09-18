#!/usr/bin/env bash
# Regression tests for the Ollama addon deployment and CLI registration.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OLLAMA_DEPLOY="${REPO_ROOT}/addons/ollama/deploy.sh"
AAP_DEMO="${REPO_ROOT}/aap-demo.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export MOCK_APPLY_FILE="${TEST_DIR}/applied.yaml"

MOCK_BIN="${TEST_DIR}/bin"
mkdir -p "$MOCK_BIN"

# Parameterized mock kubectl. Callers set env vars to control behavior:
#   SC_TOPOLVM_RC   exit code for 'get sc topolvm-provisioner' (default 0 = present)
#   SC_STANDARD_RC  exit code for 'get sc standard'            (default 0 = present)
#   ROLLOUT_RC      exit code for rollout status               (default 0 = success)
# Unrecognised calls print DIAGNOSTIC_OUTPUT (allows failure-path diagnostics through).
cat >"${MOCK_BIN}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "cluster-info") exit 0 ;;
  "get sc topolvm-provisioner") exit "${SC_TOPOLVM_RC:-0}" ;;
  "get sc standard") exit "${SC_STANDARD_RC:-0}" ;;
  "get route aap -n aap-operator -o jsonpath={.spec.host}")
    printf '%s' 'aap.apps.example.test' ;;
  "apply -f -") cat >"${MOCK_APPLY_FILE}" ;;
  rollout\ status\ deployment/ollama\ -n\ aap-demo-ollama\ --timeout=15m)
    exit "${ROLLOUT_RC:-0}" ;;
  get\ pod\ -n\ aap-demo-ollama\ -l\ app=ollama\ --sort-by=.metadata.creationTimestamp\ -o\ jsonpath=*)
    printf '%s\n' 'ollama-test-pod' ;;
  wait\ --for=condition=ready\ pod/ollama-test-pod\ -n\ aap-demo-ollama\ --timeout=10s)
    exit 0 ;;
  exec\ -n\ aap-demo-ollama\ ollama-test-pod\ --\ ollama\ pull\ qwen2.5:3b) exit 0 ;;
  *) printf 'DIAGNOSTIC_OUTPUT for: %s\n' "$*" ;;
esac
EOF
chmod +x "${MOCK_BIN}/kubectl"

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

# ---------------------------------------------------------------------------
# CLI registration
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Happy-path deploy (topolvm-provisioner available)
# ---------------------------------------------------------------------------

if output=$(OLLAMA_MODEL=qwen2.5:3b SC_TOPOLVM_RC=0 "$OLLAMA_DEPLOY" 2>&1); then
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

if grep -q 'OLLAMA_ROLLOUT_TIMEOUT:-15m' "$OLLAMA_DEPLOY" \
  && grep -q 'exit 1' "$OLLAMA_DEPLOY"; then
  pass "deployment_allows_slow_image_pull_and_fails_incomplete_setup"
else
  fail "deployment_allows_slow_image_pull_and_fails_incomplete_setup"
fi

# ---------------------------------------------------------------------------
# Image pinning — :latest must not appear in the applied manifest
# ---------------------------------------------------------------------------

if ! grep -q ':latest' "$MOCK_APPLY_FILE"; then
  pass "deployed_image_is_pinned_not_latest"
else
  fail "deployed_image_is_pinned_not_latest"
fi

# ---------------------------------------------------------------------------
# Progress deadline — must match rollout timeout to avoid premature failure
# ---------------------------------------------------------------------------

if grep -q 'progressDeadlineSeconds: 900' "$MOCK_APPLY_FILE"; then
  pass "deployment_has_progress_deadline_seconds_900"
else
  fail "deployment_has_progress_deadline_seconds_900"
fi

# ---------------------------------------------------------------------------
# StorageClass placeholder resolution
# ---------------------------------------------------------------------------

# The __STORAGE_CLASS__ token must not survive into the applied manifest
if ! grep -q '__STORAGE_CLASS__' "$MOCK_APPLY_FILE"; then
  pass "storage_class_placeholder_is_resolved"
else
  fail "storage_class_placeholder_is_resolved"
fi

# topolvm-provisioner detected and used when present
if grep -q 'storageClassName: topolvm-provisioner' "$MOCK_APPLY_FILE"; then
  pass "sc_detection_uses_topolvm_when_available"
else
  fail "sc_detection_uses_topolvm_when_available"
fi

# ---------------------------------------------------------------------------
# StorageClass: OLLAMA_STORAGE_CLASS override
# ---------------------------------------------------------------------------

if OLLAMA_MODEL=qwen2.5:3b OLLAMA_STORAGE_CLASS=my-custom-sc \
  "$OLLAMA_DEPLOY" >/dev/null 2>&1 \
  && grep -q 'storageClassName: my-custom-sc' "$MOCK_APPLY_FILE"; then
  pass "sc_detection_honors_ollama_storage_class_override"
else
  fail "sc_detection_honors_ollama_storage_class_override"
fi

# ---------------------------------------------------------------------------
# StorageClass: fallback to 'standard' when topolvm absent
# ---------------------------------------------------------------------------

if OLLAMA_MODEL=qwen2.5:3b SC_TOPOLVM_RC=1 SC_STANDARD_RC=0 \
  "$OLLAMA_DEPLOY" >/dev/null 2>&1 \
  && grep -q 'storageClassName: standard' "$MOCK_APPLY_FILE"; then
  pass "sc_detection_falls_back_to_standard"
else
  fail "sc_detection_falls_back_to_standard"
fi

# ---------------------------------------------------------------------------
# StorageClass: no suitable SC → must exit non-zero before applying
# ---------------------------------------------------------------------------

if ! OLLAMA_MODEL=qwen2.5:3b SC_TOPOLVM_RC=1 SC_STANDARD_RC=1 \
  "$OLLAMA_DEPLOY" >/dev/null 2>&1; then
  pass "sc_detection_fails_when_no_sc_available"
else
  fail "sc_detection_fails_when_no_sc_available"
fi

# ---------------------------------------------------------------------------
# Rollout failure: diagnostic output must be emitted before exit
# ---------------------------------------------------------------------------

_fail_output=$(ROLLOUT_RC=1 OLLAMA_MODEL=qwen2.5:3b "$OLLAMA_DEPLOY" 2>&1 || true)
if echo "$_fail_output" | grep -q 'DIAGNOSTIC_OUTPUT'; then
  pass "rollout_failure_emits_diagnostics"
else
  fail "rollout_failure_emits_diagnostics"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
