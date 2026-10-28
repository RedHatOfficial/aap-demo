#!/usr/bin/env bash
# Resolve the AI provider used by the ao-pr-testing Plaibook review.

ao_pr_testing_model_key() {
  if [ -n "${AO_PR_TESTING_PLAIBOOK_OPENAI_API_KEY:-}" ]; then
    printf '%s' "$AO_PR_TESTING_PLAIBOOK_OPENAI_API_KEY"
  elif [ -n "${AO_PR_TESTING_PLAIBOOK_API_KEY:-}" ]; then
    printf '%s' "$AO_PR_TESTING_PLAIBOOK_API_KEY"
  elif [ -n "${OPENAI_API_KEY:-}" ]; then
    printf '%s' "$OPENAI_API_KEY"
  else
    local key_file="${AO_LLM_API_KEY_FILE:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/ao/llm-api-key}"
    if [ -r "$key_file" ]; then
      cat "$key_file"
    fi
  fi
}

ao_pr_testing_select_model() {
  local models_json="$1"
  local preferred="${2:-}"

  printf '%s' "$models_json" | jq -r --arg preferred "$preferred" '
    (.resources // .results // []) as $models
    | if $preferred != "" then
        [$models[] | select(.model_id == $preferred)][0].model_id // empty
      else
        ([$models[] | select(.is_default == true)][0].model_id
          // $models[0].model_id
          // empty)
      end'
}

ao_pr_testing_configure_model() {
  local provider="${AO_LLM_PROVIDER:-ollama}"
  local model base_url api_key

  case "$provider" in
    ollama)
      model="${AO_PR_TESTING_PLAIBOOK_MODEL:-${OLLAMA_MODEL:-}}"
      base_url="${AO_PR_TESTING_PLAIBOOK_OPENAI_BASE_URL:-http://ollama.aap-demo-ollama.svc.cluster.local:11434/v1}"
      api_key="${AO_PR_TESTING_PLAIBOOK_OPENAI_API_KEY:-${AO_PR_TESTING_PLAIBOOK_API_KEY:-ollama}}"
      REVIEW_OLLAMA_COMPAT=true
      ;;
    external)
      model="${AO_PR_TESTING_PLAIBOOK_MODEL:-${AO_LLM_MODEL:-}}"
      [ "$model" = luna ] && model=gpt-6-luna
      base_url="${AO_PR_TESTING_PLAIBOOK_OPENAI_BASE_URL:-${AO_LLM_BASE_URL:-https://api.openai.com/v1}}"
      api_key=$(ao_pr_testing_model_key)
      [ -n "$api_key" ] || {
        printf '%s\n' 'ERROR: An API key is required for the external PR review model.' >&2
        return 1
      }
      REVIEW_OLLAMA_COMPAT=false
      ;;
    none)
      printf '%s\n' 'ERROR: ao-pr-testing requires an AI model; provider is set to none.' >&2
      return 1
      ;;
    *)
      printf 'ERROR: Unsupported AO LLM provider for PR review: %s\n' "$provider" >&2
      return 1
      ;;
  esac

  PLAIBOOK_MODEL="$model"
  PLAIBOOK_OPENAI_BASE_URL="$base_url"
  PLAIBOOK_OPENAI_API_KEY="$api_key"
  export PLAIBOOK_MODEL PLAIBOOK_OPENAI_BASE_URL PLAIBOOK_OPENAI_API_KEY REVIEW_OLLAMA_COMPAT
}
