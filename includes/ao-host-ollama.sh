#!/usr/bin/env bash
# =============================================================================
# ao-host-ollama.sh — AO's ollama provider: Ollama running on the host (ADR-046)
# =============================================================================
#
# aap-demo does not install Ollama or pull models. Before AO installs, this
# checks that Ollama answers on the host, picks a model already pulled, and
# checks from a pod that the cluster reaches the host. With CRC's
# host-network-access on macOS and Windows, pods reach the host at
# 192.168.127.254; Ollama itself can stay on 127.0.0.1.

if [ -n "${_AAP_DEMO_AO_HOST_OLLAMA_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_AO_HOST_OLLAMA_LOADED=1

AO_HOST_OLLAMA_CLUSTER_HOST=192.168.127.254
AO_HOST_OLLAMA_PORT=11434
AO_HOST_OLLAMA_HOST_API="http://127.0.0.1:${AO_HOST_OLLAMA_PORT}"
AO_HOST_OLLAMA_CLUSTER_URL="http://${AO_HOST_OLLAMA_CLUSTER_HOST}:${AO_HOST_OLLAMA_PORT}/v1"
AO_HOST_OLLAMA_OLD_NAMESPACE=aap-demo-ollama
AO_HOST_OLLAMA_CHECK_POD=aap-demo-ollama-check
AO_HOST_OLLAMA_CHECK_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest
AO_HOST_OLLAMA_INSTALL_HINT="Install Ollama from https://ollama.com/download (on macOS: brew install ollama), start it, pull a model that supports tools (ollama pull <model>), then run aap-demo enable ao again. To use another LLM, set AO_LLM_PROVIDER=external, or AO_LLM_PROVIDER=none to install AO without one."

# A key's value saved in the aap-demo config, if any.
ao_host_ollama_saved() {
  local file="${AAP_DEMO_CONFIG:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/config}"
  [ -f "$file" ] || return 0
  awk -v key="$1" -F= '$1 == key { value = substr($0, index($0, "=") + 1) } END { if (value != "") print value }' "$file"
}

# The OpenAI-compatible URL AO calls: the host through CRC, or AO_LLM_BASE_URL
# when set for this run. aap-demo.sh loads saved keys into the environment, and
# the saved AO_LLM_BASE_URL belongs to the external provider, so it is ignored.
ao_host_ollama_base_url() {
  if [ -n "${AO_LLM_BASE_URL:-}" ] && [ "$AO_LLM_BASE_URL" != "$(ao_host_ollama_saved AO_LLM_BASE_URL)" ]; then
    printf '%s\n' "$AO_LLM_BASE_URL"
  else
    printf '%s\n' "$AO_HOST_OLLAMA_CLUSTER_URL"
  fi
}

# Ollama's API root for an OpenAI-compatible URL (without /v1).
ao_host_ollama_api_root() {
  local url="${1%/}"
  printf '%s\n' "${url%/v1}"
}

# True for CRC's address for the host, however the URL is written.
ao_host_ollama_is_cluster_url() {
  local url="$1"
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"
  url=$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')
  [ "$(ao_host_ollama_api_root "$url")" = "$(ao_host_ollama_api_root "$AO_HOST_OLLAMA_CLUSTER_URL")" ]
}

# Where this host calls Ollama: 127.0.0.1, unless AO_LLM_BASE_URL moved it.
ao_host_ollama_host_api() {
  local base_url="$1"
  if ao_host_ollama_is_cluster_url "$base_url"; then
    printf '%s\n' "$AO_HOST_OLLAMA_HOST_API"
  else
    ao_host_ollama_api_root "$base_url"
  fi
}

# GET (one argument) or POST JSON (two). Never through a proxy.
ao_host_ollama_fetch() {
  local url="$1" body="${2:-}"
  if [ -n "$body" ]; then
    curl --noproxy '*' -fsS -m 5 -H 'Content-Type: application/json' -d "$body" "$url" 2>/dev/null
  else
    curl --noproxy '*' -fsS -m 5 "$url" 2>/dev/null
  fi
}

ao_host_ollama_version() {
  ao_host_ollama_fetch "$1/api/version" | jq -r '.version // empty' 2>/dev/null
}

ao_host_ollama_models() {
  ao_host_ollama_fetch "$1/api/tags" | jq -r '.models[]?.name // empty' 2>/dev/null | LC_ALL=C sort
}

# Prints the model's capabilities one per line, or "?" when Ollama does not report them.
ao_host_ollama_capabilities() {
  local response
  response=$(ao_host_ollama_fetch "$1/api/show" "$(jq -cn --arg m "$2" '{model: $m}')") || {
    printf '?\n'
    return 0
  }
  printf '%s' "$response" | jq -r 'if has("capabilities") then .capabilities[] else "?" end' 2>/dev/null \
    || printf '?\n'
}

# The model asked for: OLLAMA_MODEL, which aap-demo.sh also loads from the saved config.
ao_host_ollama_requested_model() {
  printf '%s\n' "${OLLAMA_MODEL:-}"
}

# A name without a tag matches name:latest.
ao_host_ollama_match() {
  local wanted="$1" name
  shift
  for name in "$@"; do
    if [ "$name" = "$wanted" ] || { [[ "$wanted" != *:* ]] && [ "$name" = "${wanted}:latest" ]; }; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 1
}

ao_host_ollama_can_ask() {
  [ "${QUIET:-false}" != true ] || return 1
  [ "${AAP_DEMO_INTERACTIVE:-}" = 1 ] && return 0
  [ -t 0 ] || { : </dev/tty; } 2>/dev/null
}

# Times the model prompt asks again after an answer that names no model.
AO_HOST_OLLAMA_ASK_ATTEMPTS=3

# Reads answers from stdin, up to AO_HOST_OLLAMA_ASK_ATTEMPTS, until one names a model.
_ao_host_ollama_read_answers() {
  local answer="" attempt
  for ((attempt = 1; attempt <= AO_HOST_OLLAMA_ASK_ATTEMPTS; attempt++)); do
    printf 'Model for AO [1-%d]: ' "$#" >&2
    IFS= read -r answer || answer=""
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    [ -n "$answer" ] || break
    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "$#" ]; then
      printf '%s\n' "${!answer}"
      return 0
    fi
    ao_host_ollama_match "$answer" "$@" && return 0
    echo "${answer} is not on this host. Enter a number or a model name." >&2
  done
  if [ -n "$answer" ]; then
    echo "ERROR: No model chosen for AO: ${answer} is not on this host." >&2
  else
    echo "ERROR: No model chosen for AO." >&2
  fi
  echo "  Run aap-demo enable ao again, or set OLLAMA_MODEL=<model>." >&2
  return 1
}

ao_host_ollama_ask() {
  local i=1 name device
  echo "Ollama models on this host:" >&2
  for name in "$@"; do
    printf '  %d) %s\n' "$i" "$name" >&2
    i=$((i + 1))
  done
  device=$(aap_demo_ao_llm_prompt_device 2>/dev/null || true)
  if [ -n "$device" ]; then
    _ao_host_ollama_read_answers "$@" <"$device"
  else
    _ao_host_ollama_read_answers "$@"
  fi
}

ao_host_ollama_join() {
  local out="" name
  for name in "$@"; do out="${out:+${out}, }${name}"; done
  printf '%s' "${out:-none}"
}

# Pick a model from those pulled: requested, the only one, or ask.
ao_host_ollama_choose_model() {
  local wanted
  wanted=$(ao_host_ollama_requested_model)
  if [ -n "$wanted" ]; then
    ao_host_ollama_match "$wanted" "$@" && return 0
    echo "ERROR: ${wanted} is not on this host's Ollama." >&2
    echo "  Pull it (ollama pull ${wanted}) or set OLLAMA_MODEL to one of: $(ao_host_ollama_join "$@")." >&2
    return 1
  fi
  if [ "$#" -eq 0 ]; then
    echo "ERROR: This host's Ollama has no models." >&2
    echo "  Pull a model that supports tools (ollama pull <model>), then run aap-demo enable ao again." >&2
    echo "  aap-demo does not choose or download models." >&2
    return 1
  fi
  if [ "$#" -eq 1 ]; then
    printf '%s\n' "$1"
    return 0
  fi
  if ao_host_ollama_can_ask; then
    ao_host_ollama_ask "$@"
    return
  fi
  echo "ERROR: This host's Ollama has several models; choose one for AO." >&2
  echo "  Set OLLAMA_MODEL=<model> and run aap-demo enable ao again. Models here: $(ao_host_ollama_join "$@")." >&2
  return 1
}

# A pod the restricted Pod Security profile admits, that curls the URL.
ao_host_ollama_check_overrides() {
  jq -cn --arg url "$1" --arg image "$AO_HOST_OLLAMA_CHECK_IMAGE" '{
    spec: {
      securityContext: {runAsNonRoot: true, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{
        name: "check",
        image: $image,
        command: ["curl", "-s", "-m", "10", "-o", "/dev/null", "-w", "%{http_code}", $url],
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
      }]
    }
  }'
}

# 0 when a pod in the namespace gets HTTP 200 from Ollama's version API,
# 1 when the pod ran and Ollama did not answer, and 2 (with the error printed)
# when the pod itself did not run, which is a cluster problem, not a network one.
ao_host_ollama_reaches() {
  local base_url="$1" namespace="$2" url output errors rc=0 code detail
  url="$(ao_host_ollama_api_root "$base_url")/api/version"
  errors=$(mktemp)
  kubectl delete pod "$AO_HOST_OLLAMA_CHECK_POD" -n "$namespace" --ignore-not-found --wait >/dev/null 2>&1 || true
  output=$(kubectl run "$AO_HOST_OLLAMA_CHECK_POD" -n "$namespace" --rm -i --quiet \
    --restart=Never --pod-running-timeout=3m "--image=${AO_HOST_OLLAMA_CHECK_IMAGE}" \
    "--overrides=$(ao_host_ollama_check_overrides "$url")" 2>"$errors") || rc=$?
  detail=$(tr '\n' ' ' <"$errors")
  rm -f "$errors"
  output="${output%"${output##*[![:space:]]}"}"
  code="${output: -3}"
  if [[ "$code" =~ ^[0-9]{3}$ ]]; then
    [ "$rc" -eq 0 ] && [ "$code" = 200 ]
    return
  fi
  detail="${detail%"${detail##*[![:space:]]}"}"
  echo "ERROR: The pod that checks the path to Ollama did not run in namespace ${namespace}." >&2
  [ -z "$detail" ] || echo "  ${detail}" >&2
  echo "  The pod pulls ${AO_HOST_OLLAMA_CHECK_IMAGE}; check that the cluster can pull it, then run aap-demo enable ao again (kubectl get events -n ${namespace})." >&2
  return 2
}

ao_host_ollama_unreachable() {
  local base_url="$1" other setting why
  other="Or set AO_LLM_PROVIDER=external, or none to install AO without an LLM."
  echo "ERROR: The cluster cannot reach Ollama at $(ao_host_ollama_api_root "$base_url")." >&2
  if ! ao_host_ollama_is_cluster_url "$base_url"; then
    echo "  Check that Ollama listens on an address the VM reaches, and that AO_LLM_BASE_URL points at it. ${other}" >&2
    return 0
  fi
  if [ "$(uname -s)" = Linux ]; then
    echo "  On Linux, CRC has no host network access setting. Make Ollama listen on the libvirt bridge (OLLAMA_HOST) and set AO_LLM_BASE_URL to that address and port with /v1. ${other}" >&2
    return 0
  fi
  setting=$(crc config get host-network-access 2>/dev/null || true)
  if [[ "$setting" == *true ]]; then
    why="CRC's host-network-access is on, but this VM may have been created before it was set."
  elif [[ "$setting" != *false ]]; then
    why="Could not read CRC's host-network-access setting (crc config get host-network-access). Pods reach the host only when it was on at create time."
  else
    why="This VM was created without CRC's host-network-access, which lets pods reach the host. AAP_DEMO_HOST_NETWORK_ACCESS=false at create time turns it off."
  fi
  echo "  ${why} The setting needs a new VM: aap-demo destroy, then aap-demo create (which turns it on), then aap-demo deploy. ${other}" >&2
}

# Check the host's Ollama and the path to it. Saves the model as OLLAMA_MODEL
# in the aap-demo config and exports it as WIRE_OLLAMA_MODEL. The cluster check
# runs before the model prompt, so a VM that cannot reach the host fails before
# anyone answers a question.
ao_host_ollama_prepare() {
  local namespace="${1:-${NAMESPACE:-aap-operator}}"
  local base_url api found model caps reach=0
  local -a available=()

  base_url=$(ao_host_ollama_base_url)
  api=$(ao_host_ollama_host_api "$base_url")
  found=$(ao_host_ollama_version "$api")
  if [ -z "$found" ]; then
    echo "ERROR: Ollama is not responding at ${api}." >&2
    echo "  Is it running? It has 5 seconds to answer. ${AO_HOST_OLLAMA_INSTALL_HINT}" >&2
    return 1
  fi
  echo "✓ Ollama ${found} on the host"
  if kubectl get namespace "$AO_HOST_OLLAMA_OLD_NAMESPACE" >/dev/null 2>&1; then
    echo "  The in-cluster Ollama from an earlier aap-demo is still installed, and AO no longer uses it."
    echo "  Remove it with: aap-demo disable ollama"
  fi
  echo "Checking that the cluster reaches the host's Ollama..."
  ao_host_ollama_reaches "$base_url" "$namespace" || reach=$?
  if [ "$reach" -ne 0 ]; then
    [ "$reach" -eq 2 ] || ao_host_ollama_unreachable "$base_url"
    return 1
  fi
  echo "✓ The cluster reaches Ollama at $(ao_host_ollama_api_root "$base_url")"
  while IFS= read -r model; do
    [ -n "$model" ] && available+=("$model")
  done < <(ao_host_ollama_models "$api")
  model=$(ao_host_ollama_choose_model ${available[@]+"${available[@]}"}) || return 1
  if [ "$model" != "$(ao_host_ollama_saved OLLAMA_MODEL)" ] \
    && ! aap_demo_ao_llm_save_config OLLAMA_MODEL "$model"; then
    echo "WARNING: Could not save OLLAMA_MODEL=${model} to ${AAP_DEMO_CONFIG:-the aap-demo config}; later runs will ask again. Set OLLAMA_MODEL to keep it." >&2
  fi
  OLLAMA_MODEL="$model"
  WIRE_OLLAMA_MODEL="$model"
  export OLLAMA_MODEL WIRE_OLLAMA_MODEL
  echo "✓ Ollama model for AO: ${model}"
  caps=$(ao_host_ollama_capabilities "$api" "$model")
  if [ "$caps" = "?" ]; then
    echo "WARNING: This Ollama does not report model capabilities; could not check that ${model} supports tools, which AO's agents need." >&2
  elif ! printf '%s\n' "$caps" | grep -qx tools; then
    echo "WARNING: ${model} does not list tool support, which AO's agents need. Choose a model that does with OLLAMA_MODEL=<model>." >&2
  fi
}
