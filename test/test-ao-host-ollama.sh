#!/usr/bin/env bash
# AO's ollama provider uses the host's Ollama (ADR-046): checks before enable ao,
# no installs or pulls, and the cleanup-only ollama addon.
# shellcheck disable=SC2317,SC2329  # stubs are called indirectly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

export AAP_DEMO_DIR="${TMP_DIR}/home"
export AAP_DEMO_CONFIG="${TMP_DIR}/config"
mkdir -p "$AAP_DEMO_DIR"

# shellcheck source=../includes/ao-llm.sh
source "${REPO_ROOT}/includes/ao-llm.sh"
# shellcheck source=../includes/ao-host-ollama.sh
source "${REPO_ROOT}/includes/ao-host-ollama.sh"

failures=0
pass() { echo "✓ $1"; }
fail() {
  echo "✗ $1" >&2
  failures=$((failures + 1))
}
check() {
  if eval "$2"; then pass "$1"; else fail "$1"; fi
}

# -- stubs: the host's Ollama API, kubectl and crc ---------------------------------
OLLAMA_VERSION=0.40.14
OLLAMA_MODELS="granite3.3:8b"
OLLAMA_CAPS='["completion","tools"]'
REACH_STATUS=200
OLD_NAMESPACE=false
CRC_SETTING="host-network-access : true"
CALLS="${TMP_DIR}/calls"

curl() {
  local url="${*: -1}"
  printf 'curl %s\n' "$*" >>"$CALLS"
  [ -n "$OLLAMA_VERSION" ] || return 7
  case "$url" in
    */api/version) printf '{"version":"%s"}' "$OLLAMA_VERSION" ;;
    */api/tags)
      printf '%s\n' $OLLAMA_MODELS | jq -R '{name: .}' | jq -sc '{models: .}'
      ;;
    */api/show)
      if [ "$OLLAMA_CAPS" = none ]; then printf '{}'; else printf '{"capabilities":%s}' "$OLLAMA_CAPS"; fi
      ;;
    */api/pull)
      echo "pull must never be called" >&2
      return 1
      ;;
    *) return 22 ;;
  esac
}
kubectl() {
  printf 'kubectl %s\n' "$*" >>"$CALLS"
  case "$1 $2" in
    "get namespace") [ "$OLD_NAMESPACE" = true ] ;;
    "delete pod") return 0 ;;
    "run aap-demo-ollama-check")
      printf '%s' "$REACH_STATUS"
      [ "$REACH_STATUS" = 200 ]
      ;;
    *) return 0 ;;
  esac
}
crc() {
  printf 'crc %s\n' "$*" >>"$CALLS"
  [ "$1 $2" = "config get" ] && printf '%s\n' "$CRC_SETTING"
  return 0
}

reset() {
  : >"$CALLS"
  : >"$AAP_DEMO_CONFIG"
  unset OLLAMA_MODEL WIRE_OLLAMA_MODEL AO_LLM_BASE_URL AAP_DEMO_INTERACTIVE
  QUIET=true
  OLLAMA_VERSION=0.40.14
  OLLAMA_MODELS="granite3.3:8b"
  OLLAMA_CAPS='["completion","tools"]'
  REACH_STATUS=200
  OLD_NAMESPACE=false
}

run_prepare() {
  ao_host_ollama_prepare aap-operator >"${TMP_DIR}/out" 2>&1
}
out() { cat "${TMP_DIR}/out"; }

# -- detection ----------------------------------------------------------------------
reset
run_prepare
check "one_model_is_chosen_saved_and_checked_from_the_cluster" \
  '[ "$WIRE_OLLAMA_MODEL" = granite3.3:8b ] && grep -qx "OLLAMA_MODEL=granite3.3:8b" "$AAP_DEMO_CONFIG" && out | grep -q "Ollama 0.40.14 on the host"'
check "the_host_is_called_without_a_proxy_on_127_0_0_1" \
  'grep -q -- "--noproxy \* .*http://127.0.0.1:11434/api/version" "$CALLS"'
overrides=$(grep '^kubectl run aap-demo-ollama-check' "$CALLS" | sed -E 's/.*--overrides=//')
check "the_check_pod_passes_restricted_pod_security" \
  '[ "$(printf "%s" "$overrides" | jq -r ".spec.securityContext.runAsNonRoot")" = true ] && [ "$(printf "%s" "$overrides" | jq -c ".spec.containers[0].securityContext.capabilities")" = "{\"drop\":[\"ALL\"]}" ] && [ "$(printf "%s" "$overrides" | jq -r ".spec.containers[0].command[-1]")" = http://192.168.127.254:11434/api/version ]'
check "the_check_pod_runs_in_the_aap_namespace_with_ubi" \
  'grep -q "^kubectl run aap-demo-ollama-check -n aap-operator .*--image=registry.access.redhat.com/ubi9/ubi-minimal" "$CALLS"'
check "nothing_is_pulled" '! grep -q "/api/pull" "$CALLS"'

reset
OLLAMA_VERSION=""
check "ollama_not_running_says_how_to_install_it" \
  '! run_prepare && out | grep -q "Ollama is not running at http://127.0.0.1:11434" && out | grep -q "ollama.com" && ! grep -q "^kubectl run" "$CALLS"'

reset
OLLAMA_MODELS=""
check "no_models_says_to_pull_one" '! run_prepare && out | grep -q "has no models" && out | grep -q "ollama pull"'

reset
OLLAMA_MODEL=llama3.2
check "a_requested_model_that_is_missing_stops" \
  '! run_prepare && out | grep -q "llama3.2 is not on this host" && out | grep -q "ollama pull llama3.2"'

reset
OLLAMA_MODELS="granite:latest qwen3:8b"
OLLAMA_MODEL=granite
run_prepare
check "a_model_without_a_tag_matches_latest" '[ "$WIRE_OLLAMA_MODEL" = granite:latest ]'

reset
OLLAMA_MODELS="granite3.3:8b qwen3:8b"
check "several_models_without_a_terminal_list_them" \
  '! run_prepare && out | grep -q "several models" && out | grep -q "granite3.3:8b, qwen3:8b" && out | grep -q OLLAMA_MODEL'

reset
OLLAMA_MODELS="granite3.3:8b qwen3:8b"
QUIET=false
AAP_DEMO_INTERACTIVE=1
AO_LLM_PROMPT_DEVICE="${TMP_DIR}/answer"
printf '2\n' >"$AO_LLM_PROMPT_DEVICE"
export AO_LLM_PROMPT_DEVICE
run_prepare
check "several_models_are_offered_in_a_terminal" \
  '[ "$WIRE_OLLAMA_MODEL" = qwen3:8b ] && grep -qx "OLLAMA_MODEL=qwen3:8b" "$AAP_DEMO_CONFIG"'
unset AO_LLM_PROMPT_DEVICE

reset
OLLAMA_CAPS='["completion"]'
run_prepare
check "a_model_without_tools_is_a_warning" 'out | grep -q "does not list tool support"'

reset
OLLAMA_CAPS=none
run_prepare
check "an_ollama_without_capabilities_warns" 'out | grep -q "does not report model capabilities"'

reset
OLD_NAMESPACE=true
run_prepare
check "the_old_in_cluster_ollama_is_pointed_out" 'out | grep -q "aap-demo disable ollama"'

reset
AO_LLM_BASE_URL=http://192.168.130.1:11434/v1
run_prepare
check "a_base_url_override_checks_that_address" \
  'grep -q "curl .*http://192.168.130.1:11434/api/version" "$CALLS" && printf "%s" "$(grep "^kubectl run" "$CALLS")" | grep -q "192.168.130.1:11434/api/version"'

reset
printf 'AO_LLM_BASE_URL=https://api.openai.com/v1\n' >"$AAP_DEMO_CONFIG"
AO_LLM_BASE_URL=https://api.openai.com/v1
run_prepare
check "the_saved_external_url_is_ignored" 'grep -q "curl .*http://127.0.0.1:11434/api/version" "$CALLS"'

# -- reachability -------------------------------------------------------------------
if [ "$(uname -s)" != Linux ]; then
  reset
  REACH_STATUS=000
  CRC_SETTING="host-network-access : false"
  check "an_unreachable_host_explains_the_new_vm" \
    '! run_prepare && out | grep -q "cannot reach Ollama" && out | grep -q "created without" && out | grep -q "aap-demo destroy, then aap-demo create" && ! grep -q "^crc cleanup" "$CALLS"'
fi

# -- the ollama addon ---------------------------------------------------------------
STUB_BIN="${TMP_DIR}/bin"
mkdir -p "$STUB_BIN"
cat >"${STUB_BIN}/kubectl" <<EOF
#!/usr/bin/env bash
printf 'kubectl %s\n' "\$*" >>"${TMP_DIR}/addon-calls"
EOF
chmod +x "${STUB_BIN}/kubectl"
: >"${TMP_DIR}/addon-calls"
deploy_out=$(PATH="${STUB_BIN}:$PATH" bash "${REPO_ROOT}/addons/ollama/deploy.sh" 2>&1)
deploy_rc=$?
check "enable_ollama_explains_the_host_ollama" \
  '[ "$deploy_rc" -ne 0 ] && printf "%s" "$deploy_out" | grep -q "no longer installs Ollama" && printf "%s" "$deploy_out" | grep -q "ollama.com" && [ ! -s "${TMP_DIR}/addon-calls" ]'
PATH="${STUB_BIN}:$PATH" bash "${REPO_ROOT}/addons/ollama/deploy.sh" --delete >/dev/null 2>&1
delete_rc=$?
check "disable_ollama_removes_the_old_install" \
  '[ "$delete_rc" -eq 0 ] && grep -qx "kubectl delete namespace aap-demo-ollama --ignore-not-found" "${TMP_DIR}/addon-calls" && grep -qx "kubectl delete clusterrolebinding aap-demo-ollama-anyuid --ignore-not-found" "${TMP_DIR}/addon-calls"'
check "the_old_manifest_and_qwen_default_are_gone" \
  '[ ! -e "${REPO_ROOT}/addons/ollama/ollama.yaml" ] && ! grep -rq "qwen2.5:3b" "${REPO_ROOT}/addons/ollama" "${REPO_ROOT}/includes" "${REPO_ROOT}/aap-demo.sh"'
check "ollama_is_not_listed_but_disable_still_works" \
  '! grep "^AVAILABLE_ADDONS=" "${REPO_ROOT}/aap-demo.sh" | grep -qw ollama && [ -f "${REPO_ROOT}/addons/ollama/deploy.sh" ]'

echo "Host Ollama failures: ${failures}"
[ "$failures" -eq 0 ]
