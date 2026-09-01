#!/usr/bin/env bash
# =============================================================================
# addon-wire.sh — Post-install wiring between aap-demo addons
# =============================================================================
# Connects product demos, Automation Orchestrator, and MCP using cluster-local
# endpoints and tokens minted from the local AAP deployment.
#
# OpenAPI reference (AO 2026.8): /api_docs/v1/openapi.json on the AO route.
# Key endpoints:
#   POST /api/v1/auth/login
#   GET/POST /api/v1/credential_types, /api/v1/credentials
#   GET/POST /api/v1/integrations, POST /api/v1/integrations/discover
#   POST /api/v1/integrations/{id}/validate, PATCH .../tools/bulk_update
#
# Usage (sourced):
#   source includes/addon-wire.sh
#   aap_demo_wire

if [ -n "${_AAP_DEMO_ADDON_WIRE_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_ADDON_WIRE_LOADED=1

_WIRE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${_WIRE_SCRIPT_DIR}/..}"
# shellcheck source=aap-demo-paths.sh
source "${_WIRE_SCRIPT_DIR}/aap-demo-paths.sh"

NAMESPACE="${NAMESPACE:-aap-operator}"
AO_NAMESPACE="${AO_NAMESPACE:-automation-orchestrator}"
AO_STATE_DIR="${AO_STATE_DIR:-${AAP_DEMO_DIR}/ao}"
WIRE_AAP_INTEGRATION_NAME="${WIRE_AAP_INTEGRATION_NAME:-aap-demo AAP}"
WIRE_MCP_INTEGRATION_NAME="${WIRE_MCP_INTEGRATION_NAME:-aap-demo MCP Server}"
WIRE_AAP_CREDENTIAL_NAME="${WIRE_AAP_CREDENTIAL_NAME:-aap-demo AAP Token}"
WIRE_MCP_CREDENTIAL_NAME="${WIRE_MCP_CREDENTIAL_NAME:-aap-demo MCP Token}"
WIRE_AAP_OAUTH_APP_NAME="${WIRE_AAP_OAUTH_APP_NAME:-Automation Orchestrator (aap-demo)}"
WIRE_AO_LIST_LIMIT="${WIRE_AO_LIST_LIMIT:-100}"
WIRE_AO_PROJECT_WAIT_ATTEMPTS="${WIRE_AO_PROJECT_WAIT_ATTEMPTS:-36}"
WIRE_AO_DEFAULT_PROJECT_NAME="${WIRE_AO_DEFAULT_PROJECT_NAME:-Default}"

export KUBECONFIG="${KUBECONFIG:-$(aap_demo_resolve_kubeconfig "${KUBECONFIG:-}")}"

wire_log() { printf '%s\n' "$*"; }
wire_warn() { printf '  ⚠ %s\n' "$*" >&2; }

# AO list endpoints use ?limit= and return .resources (not page_size / .results).
wire_ao_list_items() {
  jq -c 'if type == "array" then . else (.resources // .results // []) end' 2>/dev/null
}

wire_require_tools() {
  local tool
  for tool in kubectl curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      wire_warn "Required tool not found: $tool"
      return 1
    fi
  done
}

wire_cluster_ready() {
  kubectl cluster-info >/dev/null 2>&1
}

wire_is_microshift() {
  if kubectl get ingresses.config/cluster -o jsonpath='{.spec.domain}' --request-timeout=5s >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

wire_aap_deployed() {
  kubectl get aap -n "$NAMESPACE" >/dev/null 2>&1
}

wire_ao_deployed() {
  kubectl get namespace "$AO_NAMESPACE" >/dev/null 2>&1 \
    && kubectl get deployment automation-orchestrator-backend -n "$AO_NAMESPACE" >/dev/null 2>&1
}

wire_mcp_deployed() {
  kubectl get ansiblemcpserver aap-mcp-server -n "$NAMESPACE" >/dev/null 2>&1 \
    || kubectl get deployment aap-mcp-server -n "$NAMESPACE" >/dev/null 2>&1
}

wire_apd_installed() {
  kubectl get aap -n "$NAMESPACE" >/dev/null 2>&1 || return 1
  # shellcheck source=../addons/product-demos-base/lib.sh
  source "${REPO_ROOT}/addons/product-demos-base/lib.sh"
  apd_init_aap_connection >/dev/null 2>&1 || return 1
  [ -n "$(apd_apd_org_id 2>/dev/null || true)" ]
}

wire_aap_route_host() {
  local route
  route=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -z "$route" ]; then
    route=$(kubectl get route -n "$NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
  fi
  printf '%s' "$route"
}

wire_aap_in_cluster_url() {
  printf 'http://aap.%s.svc.cluster.local' "$NAMESPACE"
}

wire_aap_route_url() {
  local route
  route=$(wire_aap_route_host)
  if [ -z "$route" ]; then
    return 1
  fi
  printf 'https://%s' "$route"
}

# AO rejects base_url values that resolve to private/reserved addresses (e.g. *.svc.cluster.local).
# Use the cluster route hostname; CoreDNS rewrite (ADR-007) routes pod traffic via ingress.
wire_aap_url_for_ao() {
  wire_aap_route_url || wire_aap_in_cluster_url
}

wire_mcp_in_cluster_url() {
  local svc="${1:-aap-mcp-server}"
  printf 'http://%s.%s.svc.cluster.local/mcp' "$svc" "$NAMESPACE"
}

wire_mcp_route_host() {
  kubectl get route -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null \
    | grep -E 'mcp|aap-mcp' | head -1
}

wire_mcp_url_for_ao() {
  local route host
  route=$(wire_mcp_route_host)
  if [ -n "$route" ]; then
    printf 'https://%s/mcp' "$route"
    return 0
  fi
  host="aap-mcp-${NAMESPACE}.apps.127.0.0.1.nip.io"
  if kubectl get route -n "$NAMESPACE" -o jsonpath='{.items[*].spec.host}' 2>/dev/null | grep -qF "$host"; then
    printf 'https://%s/mcp' "$host"
    return 0
  fi
  wire_mcp_in_cluster_url
}

wire_aap_admin_password() {
  kubectl get secret aap-admin-password -n "$NAMESPACE" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d
}

wire_aap_gateway_token() {
  local description="${1:-aap-demo wire}"
  local scope="${2:-write}"
  local route pass token_response

  route=$(wire_aap_route_host)
  pass=$(wire_aap_admin_password)
  if [ -z "$route" ] || [ -z "$pass" ]; then
    return 1
  fi

  token_response=$(curl -sk -u "admin:${pass}" \
    -X POST "https://${route}/api/gateway/v1/tokens/" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg desc "$description" --arg scope "$scope" \
      '{description: $desc, scope: $scope}')" 2>&1)

  echo "$token_response" | jq -r '.token // empty' 2>/dev/null
}

wire_ao_route_host() {
  local route
  route=$(kubectl get route -n "$AO_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
  if [ -z "$route" ]; then
    return 1
  fi
  printf '%s' "$route"
}

wire_ao_wait_for_route() {
  local attempt
  for attempt in $(seq 1 12); do
    if wire_ao_route_host >/dev/null; then
      return 0
    fi
    if [ "$attempt" -lt 12 ]; then
      sleep 5
    fi
  done
  wire_warn "Automation Orchestrator route not ready after 60s"
  return 1
}

# Mirrors ansible/product-demos infrastructure/ao/network-access.yml: allow-list hostnames
# for co-located AAP/MCP integration base_urls that resolve to private addresses on MicroShift.
wire_ao_integration_allowed_hosts_json() {
  local h
  {
    h=$(wire_aap_route_host) && [ -n "$h" ] && printf '%s\n' "$h"
    h=$(wire_ao_route_host) && [ -n "$h" ] && printf '%s\n' "$h"
    printf 'aap.%s.svc.cluster.local\n' "$NAMESPACE"
    printf 'aap-mcp-server.%s.svc.cluster.local\n' "$NAMESPACE"
    h=$(wire_mcp_route_host) && [ -n "$h" ] && printf '%s\n' "$h"
  } | awk 'NF && !seen[$0]++' | jq -R . | jq -s -c .
}

wire_ao_network_access_current() {
  local expected="$1"
  local current
  current=$(kubectl get deployment automation-orchestrator-backend -n "$AO_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="APP_INTEGRATION_URL_ALLOWED_HOSTS")].value}' \
    2>/dev/null || true)
  [ -n "$current" ] \
    && [ "$(echo "$current" | jq -c 'sort' 2>/dev/null)" = "$(echo "$expected" | jq -c 'sort' 2>/dev/null)" ]
}

wire_ao_patch_deployment_env() {
  local deployment="$1"
  local with_oidc="$2"
  local allowed_json="$3"
  local cname env_json patch

  cname=$(kubectl get deployment "$deployment" -n "$AO_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null) || return 1

  if [ "$with_oidc" = true ]; then
    env_json=$(jq -n \
      --argjson allowed "$allowed_json" \
      '[{name: "APP_INTEGRATION_URL_ALLOWED_HOSTS", value: ($allowed | tojson)},
        {name: "APP_OIDC_ALLOW_PRIVATE_NETWORKS", value: "true"}]')
  else
    env_json=$(jq -n \
      --argjson allowed "$allowed_json" \
      '[{name: "APP_INTEGRATION_URL_ALLOWED_HOSTS", value: ($allowed | tojson)}]')
  fi

  patch=$(jq -n \
    --arg cname "$cname" \
    --argjson env "$env_json" \
    '{spec: {template: {spec: {containers: [{name: $cname, env: $env}]}}}}')

  kubectl patch deployment "$deployment" -n "$AO_NAMESPACE" --type=strategic -p "$patch" >/dev/null 2>&1
}

wire_ao_restart_remaining_ao_deployments() {
  local stamp dep
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for dep in automation-orchestrator-redis automation-orchestrator-temporal automation-orchestrator-ui; do
    kubectl patch deployment "$dep" -n "$AO_NAMESPACE" --type=strategic \
      -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"kubectl.kubernetes.io/restartedAt\":\"${stamp}\"}}}}}" \
      >/dev/null 2>&1 || true
  done
}

wire_ao_wait_for_workload_rollout() {
  local dep
  for dep in automation-orchestrator-backend automation-orchestrator-worker \
    automation-orchestrator-background-worker; do
    kubectl rollout status "deployment/${dep}" -n "$AO_NAMESPACE" --timeout=300s >/dev/null 2>&1 || true
  done
}

wire_ao_network_access() {
  local allowed_json host_count dep patched=0

  if ! wire_ao_deployed || ! wire_aap_deployed; then
    return 0
  fi

  allowed_json=$(wire_ao_integration_allowed_hosts_json)
  if [ -z "$allowed_json" ] || [ "$allowed_json" = "[]" ]; then
    wire_warn "Could not build AO integration allow-list hostnames"
    return 1
  fi

  if wire_ao_network_access_current "$allowed_json"; then
    wire_log "  ✓ AO integration allow-list already configured"
    return 0
  fi

  wire_log "Configuring Automation Orchestrator integration URL allow-list..."

  for dep in automation-orchestrator-backend automation-orchestrator-worker \
    automation-orchestrator-background-worker; do
    kubectl get deployment "$dep" -n "$AO_NAMESPACE" >/dev/null 2>&1 || continue
    if wire_ao_patch_deployment_env "$dep" \
      "$([ "$dep" = automation-orchestrator-backend ] && printf true || printf false)" \
      "$allowed_json"; then
      patched=1
    fi
  done

  if [ "$patched" -eq 0 ]; then
    wire_warn "Could not patch AO deployments for integration allow-list"
    return 1
  fi

  wire_ao_wait_for_workload_rollout
  wire_ao_restart_remaining_ao_deployments
  host_count=$(echo "$allowed_json" | jq 'length' 2>/dev/null || echo "?")
  wire_log "  ✓ AO integration allow-list applied (${host_count} hostnames)"
}

wire_ao_admin_password() {
  local secret pass
  for secret in automation-orchestrator-initial-admin-password \
    automation-orchestrator-admin-password; do
    pass=$(kubectl get secret -n "$AO_NAMESPACE" "$secret" \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
    if [ -n "$pass" ]; then
      printf '%s' "$pass"
      return 0
    fi
  done
  secret=$(kubectl get secret -n "$AO_NAMESPACE" -o name 2>/dev/null \
    | grep -i 'admin-password' | head -1 | sed 's|secret/||')
  if [ -z "$secret" ]; then
    return 1
  fi
  kubectl get secret -n "$AO_NAMESPACE" "$secret" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d
}

wire_ao_api_base() {
  local route
  route=$(wire_ao_route_host)
  if [ -z "$route" ]; then
    return 1
  fi
  printf 'https://%s/api/v1' "$route"
}

wire_ao_login_token() {
  local api_base pass login_json token

  if [ -n "${_WIRE_AO_ACCESS_TOKEN:-}" ]; then
    printf '%s' "$_WIRE_AO_ACCESS_TOKEN"
    return 0
  fi

  api_base=$(wire_ao_api_base) || return 1
  pass=$(wire_ao_admin_password)
  if [ -z "$pass" ]; then
    return 1
  fi

  login_json=$(jq -n --arg user admin --arg pass "$pass" \
    '{username: $user, password: $pass}')

  token=$(curl -sk -X POST "${api_base}/auth/login" \
    -H "Content-Type: application/json" \
    -d "$login_json" 2>/dev/null | jq -r '.access_token // empty')
  if [ -n "$token" ]; then
    _WIRE_AO_ACCESS_TOKEN="$token"
  fi
  printf '%s' "$token"
}

wire_ao_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local token api_base

  token="${AO_ACCESS_TOKEN:-$(wire_ao_login_token)}"
  api_base=$(wire_ao_api_base) || return 1
  if [ -z "$token" ]; then
    wire_warn "Could not authenticate to Automation Orchestrator API"
    return 1
  fi

  if [ -n "$data" ]; then
    curl -sk -X "$method" "${api_base}${path}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    curl -sk -X "$method" "${api_base}${path}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json"
  fi
}

wire_ao_invalidate_login_token() {
  unset _WIRE_AO_ACCESS_TOKEN _WIRE_AO_DEFAULT_PROJECT_ID AO_ACCESS_TOKEN
}

wire_ao_projects_from_response() {
  local response="$1"
  echo "$response" | wire_ao_list_items \
    | jq -r '[.[] | select(.id != null)]' 2>/dev/null
}

wire_ao_pick_project_id() {
  local projects_json="$1"
  echo "$projects_json" | jq -r '
    ([.[] | select(.is_default == true)] | .[0].id)
    // (.[0].id // empty)' 2>/dev/null
}

wire_ao_create_default_project() {
  local result project_id payload

  payload=$(jq -n \
    --arg name "$WIRE_AO_DEFAULT_PROJECT_NAME" \
    --arg desc "Default project (auto-created by aap-demo)" \
    '{name: $name, description: $desc, is_default: true}')

  result=$(wire_ao_api POST "/projects" "$payload" 2>/dev/null)
  if wire_ao_response_is_error "$result"; then
    result=$(wire_ao_api POST "/projects" \
      "$(jq -n --arg name "$WIRE_AO_DEFAULT_PROJECT_NAME" \
        '{name: $name, is_default: true}')" 2>/dev/null)
  fi
  if wire_ao_response_is_error "$result"; then
    return 1
  fi
  project_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)
  if [ -n "$project_id" ]; then
    printf '%s' "$project_id"
    return 0
  fi
  return 1
}

wire_ao_wait_for_default_project() {
  local attempt projects_json projects_response project_id last_error=""

  for attempt in $(seq 1 "$WIRE_AO_PROJECT_WAIT_ATTEMPTS"); do
    wire_ao_invalidate_login_token
    if ! wire_ao_login_token >/dev/null; then
      [ "$attempt" -lt "$WIRE_AO_PROJECT_WAIT_ATTEMPTS" ] && sleep 5
      continue
    fi

    projects_response=$(wire_ao_api GET "/projects?limit=${WIRE_AO_LIST_LIMIT}" 2>/dev/null || true)
    if wire_ao_response_is_error "$projects_response"; then
      last_error=$(echo "$projects_response" | jq -r '.title // .detail // .code // empty' 2>/dev/null)
      [ "$attempt" -lt "$WIRE_AO_PROJECT_WAIT_ATTEMPTS" ] && sleep 5
      continue
    fi

    projects_json=$(wire_ao_projects_from_response "$projects_response")
    project_id=$(wire_ao_pick_project_id "$projects_json")
    if [ -n "$project_id" ]; then
      printf '%s' "$project_id"
      return 0
    fi

    [ "$attempt" -lt "$WIRE_AO_PROJECT_WAIT_ATTEMPTS" ] && sleep 5
  done

  if [ -n "$last_error" ]; then
    wire_warn "AO projects API not ready (${last_error})"
  fi
  return 1
}

wire_ao_default_project_id() {
  local project_id

  if [ -n "${_WIRE_AO_DEFAULT_PROJECT_ID:-}" ]; then
    printf '%s' "$_WIRE_AO_DEFAULT_PROJECT_ID"
    return 0
  fi

  wire_log "  Resolving AO default project..."
  project_id=$(wire_ao_wait_for_default_project) && [ -n "$project_id" ] && {
    _WIRE_AO_DEFAULT_PROJECT_ID="$project_id"
    printf '%s' "$project_id"
    return 0
  }

  project_id=$(wire_ao_create_default_project) || true
  if [ -n "$project_id" ]; then
    wire_log "  ✓ Created AO default project (${WIRE_AO_DEFAULT_PROJECT_NAME})"
    _WIRE_AO_DEFAULT_PROJECT_ID="$project_id"
    printf '%s' "$project_id"
    return 0
  fi

  return 1
}

wire_ao_response_is_error() {
  local result="$1"
  [ -z "$result" ] && return 0
  echo "$result" | jq -e 'select(.code != null)' >/dev/null 2>&1
}

wire_ao_find_credential_type_by_name() {
  local type_name="$1"
  local types items_json type_id field_ids

  types=$(wire_ao_api GET "/credential_types?limit=${WIRE_AO_LIST_LIMIT}" 2>/dev/null)
  items_json=$(echo "$types" | wire_ao_list_items)
  type_id=$(echo "$items_json" | jq -r --arg name "$type_name" '
    [.[] | select(.name == $name) | .id][0] // empty' 2>/dev/null)
  if [ -z "$type_id" ]; then
    return 1
  fi

  AO_CREDENTIAL_TYPE_ID="$type_id"
  AO_CREDENTIAL_FIELD_IDS="$(echo "$items_json" | jq -c --arg id "$type_id" '
    .[] | select(.id == $id) | (.inputs.fields // []) | map(.id)' 2>/dev/null)"
}

wire_ao_find_credential_by_name() {
  local name="$1"
  local encoded
  encoded=$(jq -rn --arg n "$name" '$n|@uri')
  wire_ao_api GET "/credentials?name=${encoded}&limit=${WIRE_AO_LIST_LIMIT}" 2>/dev/null \
    | wire_ao_list_items \
    | jq -r --arg n "$name" '[.[] | select(.name == $n)] | .[0].id // empty' 2>/dev/null
}

wire_ao_get_credential_record() {
  local name="$1"
  local encoded
  encoded=$(jq -rn --arg n "$name" '$n|@uri')
  wire_ao_api GET "/credentials?name=${encoded}&limit=${WIRE_AO_LIST_LIMIT}" 2>/dev/null \
    | wire_ao_list_items \
    | jq -c --arg n "$name" '[.[] | select(.name == $n)] | .[0] // empty' 2>/dev/null
}

wire_ao_ensure_credential() {
  local cred_name="$1"
  local type_name="$2"
  local inputs_json="$3"
  local project_id type_id cred_id cred_record existing_type_id payload result

  project_id=$(wire_ao_default_project_id)
  if [ -z "$project_id" ]; then
    wire_warn "No AO project found for credential ${cred_name}"
    wire_warn "  AO may still be starting after a rollout — wait 1–2 minutes and run: aap-demo wire"
    wire_warn "  Check backend logs: kubectl logs -n ${AO_NAMESPACE} deploy/automation-orchestrator-backend --tail=50"
    return 1
  fi

  if ! wire_ao_find_credential_type_by_name "$type_name"; then
    wire_warn "Could not resolve AO credential type: ${type_name}"
    return 1
  fi
  type_id="${AO_CREDENTIAL_TYPE_ID:-}"
  if [ -z "$type_id" ]; then
    wire_warn "Could not resolve AO credential type: ${type_name}"
    return 1
  fi

  cred_record=$(wire_ao_get_credential_record "$cred_name")
  cred_id=$(echo "$cred_record" | jq -r '.id // empty' 2>/dev/null)
  existing_type_id=$(echo "$cred_record" | jq -r '.credential_type_id // empty' 2>/dev/null)
  if [ -n "$cred_id" ] && [ -n "$existing_type_id" ] && [ "$existing_type_id" != "$type_id" ]; then
    wire_ao_api DELETE "/credentials/${cred_id}" >/dev/null 2>&1 || true
    cred_id=""
  fi

  payload=$(jq -n \
    --arg name "$cred_name" \
    --arg type_id "$type_id" \
    --arg project_id "$project_id" \
    --arg desc "Auto-wired by aap-demo" \
    --argjson inputs "$inputs_json" \
    '{
      name: $name,
      description: $desc,
      credential_type_id: $type_id,
      project_id: $project_id,
      inputs: $inputs
    }')

  if [ -n "$cred_id" ]; then
    result=$(wire_ao_api PATCH "/credentials/${cred_id}" \
      "$(jq -n \
        --arg name "$cred_name" \
        --arg desc "Auto-wired by aap-demo" \
        --argjson inputs "$inputs_json" \
        '{name: $name, description: $desc, inputs: $inputs}')" 2>/dev/null)
    if wire_ao_response_is_error "$result"; then
      wire_warn "Failed to update AO credential: ${cred_name}"
      echo "$result" | jq '.' 2>/dev/null || echo "$result" >&2
      return 1
    fi
  else
    result=$(wire_ao_api POST "/credentials" "$payload" 2>/dev/null)
    cred_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)
  fi

  if [ -z "$cred_id" ]; then
    wire_warn "Failed to create/update AO credential: ${cred_name}"
    echo "$result" | jq '.' 2>/dev/null || echo "$result" >&2
    return 1
  fi

  printf '%s' "$cred_id"
}

wire_ao_ensure_aap_credential() {
  local cred_name="$1"
  local token="$2"
  wire_ao_ensure_credential "$cred_name" "Ansible Automation Platform" \
    "$(jq -n --arg token "$token" '{oauth_token: $token}')"
}

wire_ao_ensure_bearer_credential() {
  local cred_name="$1"
  local token="$2"
  wire_ao_ensure_credential "$cred_name" "HTTP Bearer Token" \
    "$(jq -n --arg token "$token" '{token: $token}')"
}

wire_ao_find_integration_by_name() {
  local name="$1"
  wire_ao_api GET "/integrations?limit=${WIRE_AO_LIST_LIMIT}" 2>/dev/null \
    | wire_ao_list_items \
    | jq -r --arg n "$name" '[.[] | select(.name == $n)] | .[0].id // empty' 2>/dev/null
}

wire_ao_integration_config_json() {
  local integration_type="$1"
  local base_url="$2"
  jq -n \
    --arg type "$integration_type" \
    --arg url "$base_url" \
    '{
      integration_type: $type,
      base_url: $url,
      allow_http: true,
      insecure_skip_tls_verify: true
    }'
}

wire_ao_validate_integration() {
  local integration_id="$1"
  local integration_type="$2"
  local base_url="$3"
  local credential_id="$4"
  local payload

  payload=$(jq -n \
    --arg type "$integration_type" \
    --argjson config "$(wire_ao_integration_config_json "$integration_type" "$base_url")" \
    --arg cred "$credential_id" \
    '{
      integration_type: $type,
      configuration: $config,
      credential_id: $cred
    }')

  wire_ao_api POST "/integrations/${integration_id}/validate" "$payload" >/dev/null 2>&1 \
    || wire_ao_api POST "/integrations/discover" "$payload" >/dev/null 2>&1 \
    || true
}

wire_ao_enable_all_tools() {
  local integration_id="$1"
  local tools tool_ids_json chunk

  tools=$(wire_ao_api GET "/integrations/${integration_id}/tools?limit=${WIRE_AO_LIST_LIMIT}" 2>/dev/null)
  tool_ids_json=$(echo "$tools" | wire_ao_list_items | jq -c '[.[]? | .id]' 2>/dev/null)
  if [ -z "$tool_ids_json" ] || [ "$tool_ids_json" = "[]" ]; then
    wire_ao_api POST "/integrations/${integration_id}/refresh" '{}' >/dev/null 2>&1 || true
    sleep 3
    tools=$(wire_ao_api GET "/integrations/${integration_id}/tools?limit=${WIRE_AO_LIST_LIMIT}" 2>/dev/null)
    tool_ids_json=$(echo "$tools" | wire_ao_list_items | jq -c '[.[]? | .id]' 2>/dev/null)
  fi

  if [ -z "$tool_ids_json" ] || [ "$tool_ids_json" = "[]" ]; then
    wire_warn "No MCP tools discovered for integration ${integration_id}"
    return 0
  fi

  echo "$tool_ids_json" | jq -c 'range(0; length; 50) as $i | .[$i:$i+50]' | while read -r chunk; do
    wire_ao_api PATCH "/integrations/${integration_id}/tools/bulk_update" \
      "$(jq -n --argjson ids "$chunk" '{tool_ids: $ids, enabled: true}')" >/dev/null 2>&1 || true
  done
}

wire_ao_ensure_integration() {
  local name="$1"
  local integration_type="$2"
  local base_url="$3"
  local credential_id="$4"
  local discover_tools="${5:-false}"
  local integration_id payload result discovered_tools_json

  integration_id=$(wire_ao_find_integration_by_name "$name")
  local config_json
  config_json=$(wire_ao_integration_config_json "$integration_type" "$base_url")

  if [ -n "$integration_id" ]; then
    payload=$(jq -n \
      --arg name "$name" \
      --arg cred "$credential_id" \
      --arg desc "Auto-wired by aap-demo" \
      --argjson config "$config_json" \
      '{
        name: $name,
        description: $desc,
        configuration: $config,
        management_credential_id: $cred,
        enabled: true,
        scope: "global"
      }')
    result=$(wire_ao_api PATCH "/integrations/${integration_id}" "$payload" 2>/dev/null)
    if wire_ao_response_is_error "$result"; then
      wire_warn "Failed to update AO integration: ${name}"
      echo "$result" | jq '.' 2>/dev/null || echo "$result" >&2
      return 1
    fi
  else
    payload=$(jq -n \
      --arg name "$name" \
      --arg type "$integration_type" \
      --arg cred "$credential_id" \
      --arg desc "Auto-wired by aap-demo" \
      --argjson config "$config_json" \
      '{
        name: $name,
        description: $desc,
        integration_type: $type,
        configuration: $config,
        management_credential_id: $cred,
        enabled: true,
        scope: "global"
      }')
    if [ "$discover_tools" = true ]; then
      discovered_tools_json=$(wire_ao_api POST "/integrations/discover" \
        "$(jq -n \
          --arg type "$integration_type" \
          --arg cred "$credential_id" \
          --argjson config "$config_json" \
          '{integration_type: $type, configuration: $config, credential_id: $cred}')" 2>/dev/null \
        | jq '[.discovered_tools[]? | {name: .name, description: (.description // ""), enabled: true}]' 2>/dev/null)
      if [ -n "$discovered_tools_json" ] && [ "$discovered_tools_json" != "[]" ] && [ "$discovered_tools_json" != "null" ]; then
        payload=$(echo "$payload" | jq --argjson tools "$discovered_tools_json" '. + {discovered_tools: $tools}')
      fi
    fi
    result=$(wire_ao_api POST "/integrations" "$payload" 2>/dev/null)
    integration_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)
  fi

  if [ -z "$integration_id" ]; then
    wire_warn "Failed to create/update AO integration: ${name}"
    echo "$result" | jq '.' 2>/dev/null || echo "$result" >&2
    return 1
  fi

  wire_ao_validate_integration "$integration_id" "$integration_type" "$base_url" "$credential_id"
  if [ "$discover_tools" = true ]; then
    wire_ao_enable_all_tools "$integration_id"
  fi

  wire_log "  ✓ AO integration configured: ${name}"
  printf '%s' "$integration_id"
}

wire_apd_openshift() {
  if ! wire_apd_installed; then
    return 0
  fi
  wire_log "Wiring APD OpenShift credential for local cluster..."
  apd_ensure_openshift_credential || wire_warn "APD OpenShift credential wiring skipped"
}

wire_apd_aap_credential() {
  if ! wire_apd_installed; then
    return 0
  fi
  wire_log "Wiring APD AAP callback credential..."
  apd_ensure_aap_credential || wire_warn "APD AAP credential wiring skipped"
}

wire_apd_galaxy_if_present() {
  local token_file="${GALAXY_TOKEN_FILE:-${AAP_DEMO_DIR}/galaxy-token}"
  if ! wire_apd_installed; then
    return 0
  fi
  if [ ! -f "$token_file" ]; then
    return 0
  fi
  wire_log "Wiring APD Automation Hub credentials from ${token_file}..."
  apd_configure_galaxy_credentials "$token_file" || wire_warn "APD Galaxy credential wiring skipped"
}

wire_ao_aap() {
  local aap_url token cred_id

  if ! wire_aap_deployed || ! wire_ao_deployed; then
    return 0
  fi

  wire_log "Wiring Automation Orchestrator → AAP integration..."
  aap_url=$(wire_aap_url_for_ao)
  token=$(wire_aap_gateway_token "aap-demo AO integration" write)
  if [ -z "$token" ]; then
    wire_warn "Could not mint AAP token for AO integration"
    return 1
  fi

  cred_id=$(wire_ao_ensure_aap_credential "$WIRE_AAP_CREDENTIAL_NAME" "$token") || return 1
  wire_ao_ensure_integration "$WIRE_AAP_INTEGRATION_NAME" \
    "ansible_automation_platform" "$aap_url" "$cred_id" false || return 1
}

wire_ao_mcp() {
  local mcp_url token cred_id

  if ! wire_ao_deployed; then
    return 0
  fi
  if ! wire_mcp_deployed; then
    wire_warn "mcp-server is required for Automation Orchestrator but is not deployed"
    wire_warn "  Run: aap-demo enable ao (installs mcp-server automatically)"
    return 1
  fi

  wire_log "Wiring Automation Orchestrator → MCP server integration..."
  mcp_url=$(wire_mcp_url_for_ao)
  token=$(wire_aap_gateway_token "aap-demo AO MCP integration" write)
  if [ -z "$token" ]; then
    wire_warn "Could not mint AAP token for MCP integration"
    return 1
  fi

  cred_id=$(wire_ao_ensure_bearer_credential "$WIRE_MCP_CREDENTIAL_NAME" "$token") || return 1
  wire_ao_ensure_integration "$WIRE_MCP_INTEGRATION_NAME" \
    "mcp_server" "$mcp_url" "$cred_id" true || return 1
}

aap_demo_wire() {
  wire_require_tools || return 1
  if ! wire_cluster_ready; then
    wire_warn "Cluster not reachable; skipping addon wiring"
    return 1
  fi

  wire_ao_invalidate_login_token

  wire_log ""
  wire_log "Addon wiring (cluster-local endpoints)..."
  wire_log ""

  wire_apd_aap_credential
  wire_apd_galaxy_if_present
  wire_apd_openshift
  wire_ao_network_access || wire_warn "AO integration allow-list configuration skipped"
  if wire_ao_deployed; then
    wire_ao_wait_for_route || return 1
    wire_ao_aap || return 1
    wire_ao_mcp || return 1
  fi

  wire_log ""
  wire_log "✓ Addon wiring complete"
  wire_log ""
}
