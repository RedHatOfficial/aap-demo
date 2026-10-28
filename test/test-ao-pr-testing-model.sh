#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DEPLOY="$ROOT_DIR/addons/ao-pr-testing/deploy.sh"

# shellcheck source=../addons/ao-pr-testing/lib/model-config.sh
source "$ROOT_DIR/addons/ao-pr-testing/lib/model-config.sh"

grep -Fq 'find_configured_model' "$DEPLOY"
grep -Fq 'ao_pr_testing_select_model' "$DEPLOY"
if grep -Fq 'ao_pr_testing_configure_model || die' "$DEPLOY"; then
  echo 'missing AI provider must not abort addon setup' >&2
  exit 1
fi
if grep -Fq 'PLAIBOOK_MODEL=$(env_value AO_PR_TESTING_PLAIBOOK_MODEL qwen2.5:3b)' "$DEPLOY"; then
  echo 'PR workflow must not require the qwen2.5:3b model by name' >&2
  exit 1
fi

models='{"resources":[{"model_id":"first-model"},{"model_id":"default-model","is_default":true}]}'
[ "$(ao_pr_testing_select_model "$models")" = default-model ]
[ "$(ao_pr_testing_select_model "$models" first-model)" = first-model ]
[ -z "$(ao_pr_testing_select_model "$models" missing-model)" ]

unset AO_LLM_PROVIDER AO_LLM_BASE_URL AO_LLM_MODEL
unset AO_PR_TESTING_PLAIBOOK_MODEL AO_PR_TESTING_PLAIBOOK_OPENAI_BASE_URL
unset AO_PR_TESTING_PLAIBOOK_OPENAI_API_KEY
AO_LLM_BASE_URL=https://stale.example.test/v1
AO_LLM_MODEL=stale-model
if ! ao_pr_testing_configure_model; then
  echo 'default Ollama model configuration failed' >&2
  exit 1
fi
[ -z "$PLAIBOOK_MODEL" ]
[ "$PLAIBOOK_OPENAI_BASE_URL" = 'http://ollama.aap-demo-ollama.svc.cluster.local:11434/v1' ]
[ "$PLAIBOOK_OPENAI_API_KEY" = ollama ]
[ "$REVIEW_OLLAMA_COMPAT" = true ]

AO_LLM_PROVIDER=external
AO_LLM_BASE_URL=https://api.example.test/v1
AO_LLM_MODEL=review-model
AO_PR_TESTING_PLAIBOOK_OPENAI_API_KEY=external-key
if ! ao_pr_testing_configure_model; then
  echo 'external model configuration failed' >&2
  exit 1
fi
[ "$PLAIBOOK_MODEL" = review-model ]
[ "$PLAIBOOK_OPENAI_BASE_URL" = https://api.example.test/v1 ]
[ "$PLAIBOOK_OPENAI_API_KEY" = external-key ]
[ "$REVIEW_OLLAMA_COMPAT" = false ]

AO_PR_TESTING_PLAIBOOK_MODEL=workflow-model
if ! ao_pr_testing_configure_model; then
  echo 'explicit workflow model configuration failed' >&2
  exit 1
fi
[ "$PLAIBOOK_MODEL" = workflow-model ]

AO_LLM_PROVIDER=none
warning_file=$(mktemp)
if ! ao_pr_testing_configure_model 2>"$warning_file"; then
  echo 'provider none should warn without failing setup' >&2
  rm -f "$warning_file"
  exit 1
fi
grep -Fiq 'set up an AI provider' "$warning_file"
rm -f "$warning_file"
[ "$REVIEW_AI_READY" = false ]

echo 'ao-pr-testing model configuration is valid'
