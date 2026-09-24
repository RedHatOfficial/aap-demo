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
