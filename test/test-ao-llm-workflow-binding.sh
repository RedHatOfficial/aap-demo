#!/usr/bin/env bash
# Regression tests for rebinding existing AO workflows to the selected LLM model.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=../includes/addon-wire.sh
source "${REPO_ROOT}/includes/addon-wire.sh"

failures=0
fail() {
  echo "✗ $1" >&2
  failures=$((failures + 1))
}

AO_LLM_PROVIDER=external
AO_LLM_MODEL=gpt-6-luna
wire_ao_llm_agent_credential_id() { printf '%s\n' 'gpt-6-luna-credential-id'; }
wire_ao_llm_agent_integration_id() { printf '%s\n' 'gpt-6-luna-integration-id'; }
wire_ao_llm_agent_model_id() { printf '%s\n' 'gpt-6-luna-model-id'; }
wire_ao_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  case "$method $path" in
    "GET /workflows?limit=100")
      printf '%s\n' '{"resources":[
        {"id":"demo-workflow","labels":{"aap-demo":"true"},"workflow_definition":{"nodes":[
          {"type":"agentic","parameters":{"model":"stale-model","credential_id":"stale-credential"}},
          {"type":"agentic","parameters":{"model":"another-stale-model"}},
          {"type":"aap_job_template","parameters":{}}
        ]}},
        {"id":"unrelated-workflow","labels":{"aap-demo":"false"},"workflow_definition":{"nodes":[
          {"type":"agentic","parameters":{"model":"leave-me-alone"}}
        ]}}
      ]}'
      ;;
    "PATCH /workflows/demo-workflow")
      printf '%s' "$data" >"$TEST_DIR/demo-patch.json"
      printf '%s\n' '{}'
      ;;
    *)
      echo "unexpected API call: $method $path" >&2
      return 1
      ;;
  esac
}

if ! wire_ao_rebind_agentic_workflows; then
  fail "workflow_rebinding_succeeds"
elif [ "$(jq -r '.workflow_definition.nodes | map(select(.type == "agentic")) | length' "$TEST_DIR/demo-patch.json")" != 2 ] \
  || [ "$(jq -r '.workflow_definition.nodes[0].parameters.credential_id' "$TEST_DIR/demo-patch.json")" != gpt-6-luna-credential-id ] \
  || [ "$(jq -r '.workflow_definition.nodes[0].parameters.integration_id' "$TEST_DIR/demo-patch.json")" != gpt-6-luna-integration-id ] \
  || [ "$(jq -r '.workflow_definition.nodes[0].parameters.llm_model_id' "$TEST_DIR/demo-patch.json")" != gpt-6-luna-model-id ] \
  || [ "$(jq -r '.workflow_definition.nodes[1].parameters.llm_model_id' "$TEST_DIR/demo-patch.json")" != gpt-6-luna-model-id ] \
  || [ "$(jq -r '.workflow_definition.nodes[0].parameters.model // empty' "$TEST_DIR/demo-patch.json")" != "" ]; then
  fail "all_demo_agentic_nodes_receive_selected_model"
fi

AO_LLM_PROVIDER=none
wire_ao_api() {
  echo "AO API should not be called for none" >&2
  return 1
}
if ! wire_ao_rebind_agentic_workflows; then
  fail "none_provider_skips_workflow_rebinding"
fi

echo "AO LLM workflow binding failures: ${failures}"
[ "$failures" -eq 0 ]
