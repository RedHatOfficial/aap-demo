#!/usr/bin/env bash
# Live, opt-in smoke tests for the add-ons exposed by aap-demo.
#
# This script intentionally performs a real enable -> verify -> disable cycle.
# It is not part of the default offline test suite.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AAP_DEMO="${AAP_DEMO_COMMAND:-${REPO_ROOT}/aap-demo.sh}"
AAP_NAMESPACE="${AAP_NAMESPACE:-aap-operator}"
LOG_DIR="${AAP_DEMO_TEST_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/aap-addon-test.XXXXXX")}"
KEEP=false
CONTINUE=false
DRY_RUN=false
LIVE=false
LOW_RESOURCE=false
SELECTED=()

# These are the user-facing add-ons in aap-demo. product-demo-* domain add-ons
# are installed by product-demos and are not separate entries in the CLI help.
ADDONS=(
  mcp-server
  portal
  portal-operator
  setup-pah
  ao
  apme-eap
  local-cache
  product-demos
  product-demo-satellite
  opa
  ollama
)

usage() {
  cat <<'EOF'
Usage: test/test-addons-live.sh --live [options]

Run an enable/verify/disable smoke test for each aap-demo add-on.

Options:
  --live                 Required confirmation that this changes a live cluster
  --addon NAME           Test only NAME; may be repeated
  --continue             Continue after a failed test (default: stop)
  --keep                 Do not disable add-ons after testing
  --low-resource         Set AO_LOW_RESOURCE=1 when testing AO
  --dry-run              Print the test plan without contacting a cluster
  --help                 Show this help

Useful environment variables:
  AAP_DEMO_TEST_LOG_DIR  Directory for per-add-on logs
  PRODUCT_DEMOS_DOMAINS  Domains for product-demos (default: all domains)
  OLLAMA_ROLLOUT_TIMEOUT Ollama rollout timeout (default: addon default)
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --live) LIVE=true ;;
      --addon)
        [ "$#" -ge 2 ] || die "--addon requires a name"
        SELECTED+=("$2")
        shift
        ;;
      --continue) CONTINUE=true ;;
      --keep) KEEP=true ;;
      --low-resource) LOW_RESOURCE=true ;;
      --dry-run) DRY_RUN=true ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done

  if [ "$DRY_RUN" = false ] && [ "$LIVE" = false ]; then
    die "refusing to change a cluster; pass --live (or use --dry-run)"
  fi

  if [ "${#SELECTED[@]}" -gt 0 ]; then
    local addon
    for addon in "${SELECTED[@]}"; do
      contains "$addon" "${ADDONS[@]}" || die "unknown add-on: $addon"
    done
  else
    SELECTED=("${ADDONS[@]}")
  fi
}

print_plan() {
  local addon
  for addon in "${SELECTED[@]}"; do
    printf 'DRY-RUN: %s' "$addon"
    [ "$LOW_RESOURCE" = true ] && [ "$addon" = ao ] && printf ' (AO_LOW_RESOURCE=1)'
    printf '\n'
  done
}

config_file() {
  printf '%s\n' "${HOME}/.aap-demo/config"
}

was_enabled() {
  local addon="$1" config raw item
  config="$(config_file)"
  [ -f "$config" ] || return 1
  raw="$(sed -n 's/^ADDONS=//p' "$config" | tr ',' ' ')"
  for item in $raw; do
    [ "$item" = "$addon" ] || { [ "$addon" = ao ] && [ "$item" = ao-eap ]; } || continue
    return 0
  done
  return 1
}

run_verify() {
  local addon="$1"
  case "$addon" in
    mcp-server)
      kubectl rollout status deployment/aap-mcp-server -n "$AAP_NAMESPACE" --timeout=30s >/dev/null
      kubectl get route "aap-mcp-${AAP_NAMESPACE}" -n "$AAP_NAMESPACE" >/dev/null 2>&1 || \
        kubectl get ansiblemcpserver aap-mcp-server -n "$AAP_NAMESPACE" >/dev/null
      ;;
    portal)
      helm status redhat-rhaap-portal -n redhat-rhaap-portal >/dev/null 2>&1
      kubectl get route redhat-rhaap-portal -n redhat-rhaap-portal >/dev/null 2>&1 || \
        kubectl get pods -n redhat-rhaap-portal --no-headers | grep -q .
      ;;
    portal-operator)
      kubectl get automationportal portal -n automation-portal >/dev/null
      kubectl get pods -n automation-portal --no-headers | grep -q .
      ;;
    setup-pah)
      [ -s "${PAH_CONFIG_FILE:-${HOME}/.aap-demo/pah-config.yml}" ]
      ;;
    ao)
      kubectl get automationorchestrator automation-orchestrator -n automation-orchestrator \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -qx True
      kubectl get automationorchestrator automation-orchestrator -n automation-orchestrator \
        -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' | grep -qx False
      ;;
    apme-eap)
      kubectl get route redhat-rhaap-portal -n apme >/dev/null 2>&1 || \
        kubectl get pods -n apme --no-headers | grep -q .
      ;;
    local-cache)
      find "${HOME}/.aap-demo/local-cache" -mindepth 1 -maxdepth 1 -type d \
        -print -quit 2>/dev/null | grep -q .
      ;;
    product-demos|product-demo-satellite)
      kubectl get aap aap -n "$AAP_NAMESPACE" >/dev/null
      ;;
    opa)
      kubectl rollout status deployment/opa -n "$AAP_NAMESPACE" --timeout=30s >/dev/null
      ;;
    ollama)
      kubectl rollout status deployment/ollama -n aap-demo-ollama --timeout=30s >/dev/null
      kubectl get route ollama -n aap-demo-ollama >/dev/null 2>&1 || true
      ;;
    *) return 1 ;;
  esac
}

preflight_one() {
  local addon="$1"
  case "$addon" in
    setup-pah)
      if [ ! -s "${GALAXY_TOKEN_FILE:-${HOME}/.aap-demo/galaxy-token}" ]; then
        echo "SKIP: setup-pah requires ${GALAXY_TOKEN_FILE:-${HOME}/.aap-demo/galaxy-token}" >&2
        return 2
      fi
      ;;
  esac
  return 0
}

run_one() {
  local addon="$1" log rc=0
  local addon_was_enabled=false mcp_was_enabled=false ollama_was_enabled=false
  local -a addon_env=()
  log="${LOG_DIR}/${addon}.log"
  mkdir -p "$LOG_DIR"
  echo
  echo "=== ${addon} ==="

  if [ "$addon" = ao ] && [ "$LOW_RESOURCE" = true ]; then
    addon_env=(AO_LOW_RESOURCE=1 AO_IMPORT_DEMOS=0)
  elif [ "$addon" = product-demos ]; then
    addon_env=("PRODUCT_DEMOS_DOMAINS=${PRODUCT_DEMOS_DOMAINS:-linux windows network cloud openshift}")
  fi

  preflight_one "$addon"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 2 ] && return 2
    return 1
  fi

  was_enabled "$addon" && addon_was_enabled=true
  if [ "$addon" = ao ]; then
    was_enabled mcp-server && mcp_was_enabled=true
    was_enabled ollama && ollama_was_enabled=true
  fi

  echo "Command: ${addon_env[*]:+${addon_env[*]} }${AAP_DEMO} enable ${addon}"
  env "${addon_env[@]}" "$AAP_DEMO" enable "$addon" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ] && run_verify "$addon" >>"$log" 2>&1; then
    echo "PASS: ${addon}"
  else
    echo "FAIL: ${addon} (see ${log})"
    rc=1
  fi

  if [ "$KEEP" = false ] && [ "$addon_was_enabled" = false ]; then
    echo "Cleanup: ${AAP_DEMO} disable ${addon}"
    CI=true "$AAP_DEMO" disable "$addon" >>"$log" 2>&1 || {
      echo "WARN: cleanup failed for ${addon}; see ${log}" >&2
      rc=1
    }
    if [ "$addon" = ao ]; then
      if [ "$mcp_was_enabled" = false ]; then
        CI=true "$AAP_DEMO" disable mcp-server >>"$log" 2>&1 || {
          echo "WARN: cleanup failed for mcp-server dependency; see ${log}" >&2
          rc=1
        }
      fi
      if [ "$ollama_was_enabled" = false ]; then
        CI=true "$AAP_DEMO" disable ollama >>"$log" 2>&1 || {
          echo "WARN: cleanup failed for ollama dependency; see ${log}" >&2
          rc=1
        }
      fi
    fi
  else
    echo "Cleanup: preserved ${addon}"
  fi
  return "$rc"
}

main() {
  parse_args "$@"
  if [ "$DRY_RUN" = true ]; then
    print_plan
    exit 0
  fi

  command -v kubectl >/dev/null 2>&1 || die "kubectl is required"
  "$AAP_DEMO" status >/dev/null 2>&1 || die "AAP demo status check failed"
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl is not connected to a cluster"
  mkdir -p "$LOG_DIR"

  local addon rc=0 failures=0
  echo "Live add-on test logs: ${LOG_DIR}"
  for addon in "${SELECTED[@]}"; do
    run_one "$addon"
    rc=$?
    if [ "$rc" -eq 2 ]; then
      continue
    elif [ "$rc" -ne 0 ]; then
      failures=$((failures + 1))
      rc=1
      [ "$CONTINUE" = true ] || break
    fi
  done
  echo
  if [ "$failures" -eq 0 ]; then
    echo "All selected add-on smoke tests passed."
  else
    echo "${failures} add-on smoke test(s) failed."
  fi
  return "$rc"
}

main "$@"
