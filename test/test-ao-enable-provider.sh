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

if ! aap_demo_ao_llm_configure_provider none; then
  fail "none_provider_configuration"
elif [ "${AO_LLM_PROVIDER:-}" != none ] \
  || ! grep -q '^AO_LLM_PROVIDER=none$' "$AAP_DEMO_CONFIG"; then
  fail "none_provider_configuration"
fi

profile_key_file="$TEST_DIR/state/ao/profile-api-key"
if OPENAI_API_KEY="profile-secret" AO_LLM_API_KEY_FILE="$profile_key_file" \
  AO_LLM_PROMPT_DEVICE=/dev/null \
  bash -c "source '${REPO_ROOT}/includes/ao-llm.sh'; aap_demo_ao_llm_prompt_for_key" \
  && [ "$(<"$profile_key_file")" = "profile-secret" ]; then
  :
else
  fail "imports_exported_openai_api_key"
fi

prompt_key_file="$TEST_DIR/state/ao/prompt-api-key"
prompt_input="$TEST_DIR/prompt-input"
printf '%s\n' 'prompt-secret' >"$prompt_input"
if env -u OPENAI_API_KEY AO_LLM_API_KEY_FILE="$prompt_key_file" \
  AO_LLM_PROMPT_DEVICE="$prompt_input" \
  bash -c "source '${REPO_ROOT}/includes/ao-llm.sh'; aap_demo_ao_llm_prompt_for_key" \
  >/dev/null 2>&1 \
  && [ "$(<"$prompt_key_file")" = "prompt-secret" ]; then
  :
else
  fail "prompts_when_openai_api_key_is_unavailable"
fi

none_key_file="$TEST_DIR/state/ao/none-api-key"
if OPENAI_API_KEY="profile-secret" AO_LLM_API_KEY_FILE="$none_key_file" \
  bash -c "source '${REPO_ROOT}/includes/ao-llm.sh'; aap_demo_ao_llm_configure_provider none" \
  && [ ! -e "$none_key_file" ]; then
  :
else
  fail "none_does_not_import_exported_openai_api_key"
fi

unset AO_LLM_PROVIDER
QUIET=true
if ! aap_demo_ao_llm_prepare; then
  fail "quiet_mode_provider_preparation"
elif [ "${AO_LLM_PROVIDER:-}" != ollama ]; then
  fail "quiet_mode_defaults_to_ollama"
fi

AO_LLM_PROVIDER=external
if ! aap_demo_ao_llm_prepare; then
  fail "quiet_mode_respects_explicit_external_provider"
elif [ "${AO_LLM_PROVIDER:-}" != external ]; then
  fail "quiet_mode_respects_explicit_external_provider"
fi

AO_LLM_PROVIDER=none
if ! aap_demo_ao_llm_prepare; then
  fail "quiet_mode_respects_explicit_none_provider"
elif [ "${AO_LLM_PROVIDER:-}" != none ]; then
  fail "quiet_mode_respects_explicit_none_provider"
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
