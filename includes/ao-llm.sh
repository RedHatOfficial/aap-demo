#!/usr/bin/env bash
# =============================================================================
# ao-llm.sh — shared Automation Orchestrator LLM provider configuration
# =============================================================================

if [ -n "${_AAP_DEMO_AO_LLM_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_AO_LLM_LOADED=1

: "${AAP_DEMO_DIR:=${HOME}/.aap-demo}"
: "${AAP_DEMO_CONFIG:=${AAP_DEMO_DIR}/config}"

aap_demo_ao_llm_choice() {
  case "${1:-}" in
    1) printf '%s\n' ollama ;;
    2) printf '%s\n' external ;;
    *) return 1 ;;
  esac
}

aap_demo_ao_llm_key_file() {
  printf '%s\n' "${AO_LLM_API_KEY_FILE:-${AAP_DEMO_DIR}/ao/llm-api-key}"
}

aap_demo_ao_llm_save_key() {
  local key="${1:-}"
  local key_file tmp_file
  [ -n "$key" ] || return 1

  key_file=$(aap_demo_ao_llm_key_file)
  mkdir -p "$(dirname "$key_file")"
  tmp_file="${key_file}.tmp.$$"
  (
    umask 077
    printf '%s' "$key" >"$tmp_file"
    chmod 600 "$tmp_file"
  )
  mv "$tmp_file" "$key_file"
  chmod 600 "$key_file"
}

aap_demo_ao_llm_save_config() {
  local key="${1:-}"
  local value="${2:-}"
  local config_file tmp_file
  case "$key" in
    AO_LLM_PROVIDER | AO_LLM_BASE_URL | AO_LLM_MODEL) ;;
    *) return 1 ;;
  esac

  config_file="${AAP_DEMO_CONFIG:-${AAP_DEMO_DIR}/config}"
  mkdir -p "$(dirname "$config_file")"
  tmp_file="${config_file}.tmp.$$"
  (
    umask 077
    if [ -f "$config_file" ]; then
      awk -v key="$key" -v value="$value" '
        BEGIN { updated = 0 }
        $0 ~ ("^" key "=") {
          if (!updated) print key "=" value
          updated = 1
          next
        }
        { print }
        END {
          if (!updated) print key "=" value
        }
      ' "$config_file" >"$tmp_file"
    else
      printf '%s=%s\n' "$key" "$value" >"$tmp_file"
    fi
    chmod 600 "$tmp_file"
  )
  mv "$tmp_file" "$config_file"
}

aap_demo_ao_llm_external_defaults() {
  : "${AO_LLM_BASE_URL:=https://api.openai.com/v1}"
  : "${AO_LLM_MODEL:=luna}"
  export AO_LLM_BASE_URL AO_LLM_MODEL
}

aap_demo_ao_llm_configure_provider() {
  local provider="${1:-}"
  local api_key="${2:-}"

  case "$provider" in
    ollama)
      export AO_LLM_PROVIDER=ollama
      aap_demo_ao_llm_save_config AO_LLM_PROVIDER ollama
      ;;
    external)
      aap_demo_ao_llm_external_defaults
      if [ -n "$api_key" ]; then
        aap_demo_ao_llm_save_key "$api_key"
      fi
      if [ ! -s "$(aap_demo_ao_llm_key_file)" ]; then
        echo "ERROR: An API key is required for the external LLM provider." >&2
        return 1
      fi
      export AO_LLM_PROVIDER=external
      aap_demo_ao_llm_save_config AO_LLM_PROVIDER external
      aap_demo_ao_llm_save_config AO_LLM_BASE_URL "$AO_LLM_BASE_URL"
      aap_demo_ao_llm_save_config AO_LLM_MODEL "$AO_LLM_MODEL"
      ;;
    *)
      echo "ERROR: Unsupported AO LLM provider: ${provider:-empty}" >&2
      return 1
      ;;
  esac
}

aap_demo_ao_llm_prompt_for_key() {
  local prompt_device="${AO_LLM_PROMPT_DEVICE:-/dev/tty}"
  local api_key

  printf 'External LLM API key (input hidden): ' >&2
  IFS= read -r -s api_key <"$prompt_device" || return 1
  printf '\n' >&2
  [ -n "$api_key" ] || {
    echo "ERROR: API key cannot be empty." >&2
    return 1
  }
  aap_demo_ao_llm_configure_provider external "$api_key"
}

aap_demo_ao_llm_prepare() {
  local provider="${AO_LLM_PROVIDER:-}"
  local prompt_device="${AO_LLM_PROMPT_DEVICE:-/dev/tty}"
  local choice selected

  if [ "${QUIET:-false}" = true ]; then
    aap_demo_ao_llm_configure_provider ollama
    return
  fi

  if [ "$provider" = external ] && [ ! -s "$(aap_demo_ao_llm_key_file)" ]; then
    aap_demo_ao_llm_prompt_for_key
    return
  fi
  if [ "$provider" = ollama ] || [ "$provider" = external ]; then
    aap_demo_ao_llm_configure_provider "$provider"
    return
  fi

  echo "Choose an AO LLM provider:"
  echo "  1) Install local Ollama (recommended for offline demos)"
  echo "  2) Use an external OpenAI-compatible provider"
  printf 'Choice [1]: '
  IFS= read -r choice <"$prompt_device" || return 1
  choice="${choice:-1}"
  selected=$(aap_demo_ao_llm_choice "$choice") || {
    echo "ERROR: Choose 1 for Ollama or 2 for an external provider." >&2
    return 1
  }
  if [ "$selected" = external ]; then
    aap_demo_ao_llm_prompt_for_key
  else
    aap_demo_ao_llm_configure_provider ollama
  fi
}
