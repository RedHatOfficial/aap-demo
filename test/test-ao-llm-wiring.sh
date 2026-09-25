#!/usr/bin/env bash
# Regression tests for AO LLM provider wiring dispatch and configuration.
# shellcheck disable=SC2218  # wiring functions are loaded from addon-wire.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../includes/addon-wire.sh
source "${REPO_ROOT}/includes/addon-wire.sh"

failures=0
fail() {
  echo "✗ $1" >&2
  failures=$((failures + 1))
}

if ! grep -q 'wire_ao_external_llm' "${REPO_ROOT}/includes/addon-wire.sh"; then
  fail "external_llm_wiring_function_exists"
fi

wire_ao_default_project_id() { printf '%s' 'target-project'; }
wire_ao_api() {
  case "$1 $2" in
    "GET /credentials?name=aap-demo%20External%20LLM&limit=100")
      printf '%s' '{"resources":[
        {"id":"wrong-project-credential","name":"aap-demo External LLM","project_id":"other-project"},
        {"id":"target-project-credential","name":"aap-demo External LLM","project_id":"target-project"}
      ]}'
      ;;
    *) return 1 ;;
  esac
}
if [ "$(wire_ao_find_credential_by_name 'aap-demo External LLM')" != target-project-credential ]; then
  fail "credential_lookup_is_scoped_to_default_project"
fi

AO_LLM_BASE_URL="https://api.example.test/v1"
AO_LLM_MODEL="gpt-5.6-luna"
external_config=$(wire_ao_llm_config_json 2>/dev/null || true)
if [ "$(printf '%s' "$external_config" | jq -r '.integration_type // empty' 2>/dev/null)" != "llm_provider" ] \
  || [ "$(printf '%s' "$external_config" | jq -r '.base_url // empty' 2>/dev/null)" != "https://api.example.test/v1" ] \
  || [ "$(printf '%s' "$external_config" | jq -r '.provider_hint // empty' 2>/dev/null)" != "custom" ]; then
  fail "external_llm_configuration"
fi

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
AO_LLM_API_KEY_FILE="$TEST_DIR/llm-api-key"
printf '%s' 'secret-fixture' >"$AO_LLM_API_KEY_FILE"
chmod 600 "$AO_LLM_API_KEY_FILE"
AO_LLM_BASE_URL="https://api.example.test/v1"
AO_LLM_MODEL="gpt-5.6-luna"

wire_ao_ensure_credential() {
  printf '%s' "$3" >"$TEST_DIR/credential.json"
  printf '%s' 'credential-id'
}

model_patch_called=false
wire_ao_api() {
  local method="$1"
  local path="$2"
  case "$method $path" in
    "GET /integrations/integration-id/models?limit=50")
      printf '%s' '{"resources":[]}'
      ;;
    "PATCH /integrations/integration-id/models/model-id")
      model_patch_called=true
      printf '%s' '{}'
      ;;
  esac
}
if wire_ao_set_default_llm_model integration-id gpt-5.6-luna; then
  fail "missing_model_fails_closed"
elif [ "$model_patch_called" = true ]; then
  fail "missing_model_does_not_patch"
fi

wire_ao_api() {
  local method="$1"
  local path="$2"
  case "$method $path" in
    "GET /integrations/integration-id/models?limit=50")
      printf '%s' '{"resources":[{"id":"model-id","model_id":"gpt-5.6-luna"}]}'
      ;;
    "PATCH /integrations/integration-id/models/model-id")
      printf '%s' '{"code":"MODEL_UPDATE_FAILED"}'
      ;;
  esac
}
if wire_ao_set_default_llm_model integration-id gpt-5.6-luna; then
  fail "model_patch_failure_fails_closed"
fi

wire_ao_find_integration_by_name() {
  return 1
}
wire_ao_api() {
  local method="$1"
  local path="$2"
  local data="$3"
  case "$method $path" in
    "POST /integrations")
      printf '%s' "$data" >"$TEST_DIR/integration.json"
      printf '%s' '{"id":"integration-id"}'
      ;;
    "POST /integrations/"*"/validate" | "POST /integrations/"*"/refresh")
      printf '%s' '{}'
      ;;
  esac
}
wire_ao_set_default_llm_model() {
  printf '%s:%s' "$1" "$2" >"$TEST_DIR/default-model"
}
AO_LLM_PROVIDER=external
wire_output=$(wire_ao_external_llm 2>&1)
if printf '%s' "$wire_output" | grep -q 'secret-fixture' \
  || [ "$(jq -r '.api_key // empty' "$TEST_DIR/credential.json")" != "secret-fixture" ] \
  || [ "$(jq -r '.configuration.base_url // empty' "$TEST_DIR/integration.json")" != "https://api.example.test/v1" ] \
  || grep -q 'secret-fixture' "$TEST_DIR/integration.json" \
  || [ "$(<"$TEST_DIR/default-model")" != "integration-id:gpt-5.6-luna" ]; then
  fail "external_llm_api_payloads"
fi

wire_ao_find_integration_by_name() {
  printf '%s' 'provider-integration-id'
}
wire_ao_api() {
  local method="$1"
  local path="$2"
  case "$method $path" in
    "GET /integrations/explicit-integration-id/models?limit=50")
      printf '%s' '{"resources":[{"id":"model-id","model_id":"gpt-5.6-luna"}]}'
      ;;
    *)
      echo "unexpected model lookup API call: $method $path" >&2
      return 1
      ;;
  esac
}
if [ "$(wire_ao_llm_agent_model_id explicit-integration-id)" != model-id ]; then
  fail "model_lookup_uses_explicit_integration"
fi

external_called=false
ollama_called=false
wire_ao_external_llm() { external_called=true; }
wire_ao_ollama() { ollama_called=true; }

AO_LLM_PROVIDER=external
wire_ao_llm
if [ "$external_called" != true ] || [ "$ollama_called" = true ]; then
  fail "external_provider_dispatch"
fi

external_called=false
ollama_called=false
AO_LLM_PROVIDER=ollama
wire_ao_llm
if [ "$ollama_called" != true ] || [ "$external_called" = true ]; then
  fail "ollama_provider_dispatch"
fi

AO_LLM_PROVIDER=external
AO_LLM_MODEL=gpt-5.6-luna
if [ "$(wire_ao_llm_integration_name)" != "aap-demo External LLM" ] \
  || [ "$(wire_ao_llm_model_name)" != gpt-5.6-luna ]; then
  fail "external_agent_model_selection"
fi

AO_LLM_MODEL=luna
if [ "$(wire_ao_llm_model_name)" != gpt-5.6-luna ]; then
  fail "legacy_external_model_is_migrated"
fi

AO_LLM_PROVIDER=ollama
WIRE_OLLAMA_MODEL=qwen2.5:3b
if [ "$(wire_ao_llm_integration_name)" != "aap-demo Ollama" ] \
  || [ "$(wire_ao_llm_model_name)" != qwen2.5:3b ]; then
  fail "ollama_agent_model_selection"
fi

external_called=false
ollama_called=false
AO_LLM_PROVIDER=none
if ! wire_ao_llm; then
  fail "none_provider_dispatch"
elif [ "$ollama_called" = true ] || [ "$external_called" = true ]; then
  fail "none_provider_dispatch"
fi

if grep -q 'AO_LLM_PROVIDER.*none' "${REPO_ROOT}/addons/ao/deploy.sh" \
  && grep -q 'agent-credential-id' "${REPO_ROOT}/addons/ao/deploy.sh"; then
  :
else
  fail "none_provider_skips_agent_credential_import"
fi

if grep -q -- '--ao-agent-credential-id' "${REPO_ROOT}/addons/ao/deploy.sh" \
  && grep -q -- '--ao-agent-model-id' "${REPO_ROOT}/addons/ao/deploy.sh" \
  && grep -q 'ao_agent_model_id' "${REPO_ROOT}/addons/ao/scripts/provision-aap-demos.py"; then
  :
else
  fail "aap_sync_receives_agent_model_binding"
fi

if grep -q 'wire_ao_rebind_agentic_workflows' "${REPO_ROOT}/includes/addon-wire.sh"; then
  :
else
  fail "wire_command_rebinds_existing_workflows"
fi

echo "AO LLM wiring failures: ${failures}"
[ "$failures" -eq 0 ]
