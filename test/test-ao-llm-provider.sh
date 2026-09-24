#!/usr/bin/env bash
# Regression tests for AO LLM provider selection and local secret handling.

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

if [ "$(aap_demo_ao_llm_choice 1)" = "ollama" ] \
  && [ "$(aap_demo_ao_llm_choice 2)" = "external" ] \
  && [ "$(aap_demo_ao_llm_choice 3)" = "none" ]; then
  pass "provider_choice_mapping"
else
  fail "provider_choice_mapping"
fi

key_output=$(aap_demo_ao_llm_save_key "secret-fixture" 2>&1)
key_mode=$(stat -f '%Lp' "$AO_LLM_API_KEY_FILE" 2>/dev/null || stat -c '%a' "$AO_LLM_API_KEY_FILE")
if [ -z "$key_output" ] \
  && [ "$(<"$AO_LLM_API_KEY_FILE")" = "secret-fixture" ] \
  && [ "$key_mode" = "600" ]; then
  pass "api_key_is_private_and_not_printed"
else
  fail "api_key_is_private_and_not_printed"
fi

unset AO_LLM_BASE_URL AO_LLM_MODEL
aap_demo_ao_llm_external_defaults
if [ "$AO_LLM_BASE_URL" = "https://api.openai.com/v1" ] \
  && [ "$AO_LLM_MODEL" = "luna" ]; then
  pass "external_provider_defaults"
else
  fail "external_provider_defaults"
fi

if AO_LLM_BASE_URL="https://example.test/v1" AO_LLM_MODEL="custom-model" \
  bash -c "source '${REPO_ROOT}/includes/ao-llm.sh'; aap_demo_ao_llm_external_defaults; [ \"\$AO_LLM_BASE_URL\" = 'https://example.test/v1' ] && [ \"\$AO_LLM_MODEL\" = 'custom-model' ]"; then
  pass "external_provider_defaults_are_overridable"
else
  fail "external_provider_defaults_are_overridable"
fi

echo "Passed: ${PASSED}  Failed: ${FAILED}"
[ "$FAILED" -eq 0 ]
