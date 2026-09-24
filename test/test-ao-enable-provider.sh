#!/usr/bin/env bash
# Regression tests for AO provider preparation and dependency selection.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export AAP_DEMO_DIR="${TEST_DIR}/state"
export AAP_DEMO_CONFIG="${TEST_DIR}/config"
export AO_LLM_API_KEY_FILE="${TEST_DIR}/state/ao/llm-api-key"

# shellcheck source=../includes/ao-llm.sh
source "${REPO_ROOT}/includes/ao-llm.sh"

failures=0
fail() {
  echo "✗ $1" >&2
  failures=$((failures + 1))
}

if ! aap_demo_ao_llm_configure_provider external "external-secret"; then
  fail "external_provider_configuration"
else
  if [ "${AO_LLM_PROVIDER:-}" != external ] \
    || ! grep -q '^AO_LLM_PROVIDER=external$' "$AAP_DEMO_CONFIG" \
    || ! grep -q '^AO_LLM_BASE_URL=https://api.openai.com/v1$' "$AAP_DEMO_CONFIG" \
    || ! grep -q '^AO_LLM_MODEL=luna$' "$AAP_DEMO_CONFIG"; then
    fail "external_provider_configuration"
  elif grep -q 'external-secret' "$AAP_DEMO_CONFIG"; then
    fail "external_provider_configuration_does_not_persist_secret"
  fi
fi

unset AO_LLM_PROVIDER
QUIET=true
if ! aap_demo_ao_llm_prepare; then
  fail "quiet_mode_provider_preparation"
elif [ "${AO_LLM_PROVIDER:-}" != ollama ]; then
  fail "quiet_mode_defaults_to_ollama"
fi

if grep -q 'source .*includes/ao-llm.sh' "${REPO_ROOT}/aap-demo.sh" \
  && grep -q 'aap_demo_ao_llm_prepare' "${REPO_ROOT}/aap-demo.sh" \
  && grep -q '_ensure_addon_dependency ollama' "${REPO_ROOT}/aap-demo.sh"; then
  :
else
  fail "cli_integrates_provider_preparation"
fi

echo "Provider preparation failures: ${failures}"
[ "$failures" -eq 0 ]
