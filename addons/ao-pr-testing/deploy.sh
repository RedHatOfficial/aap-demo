#!/usr/bin/env bash
# Automation Orchestrator PR testing addon.
# ADDON_REQUIRES_AAP=true
#
# This addon is intentionally separate from addons/ao. It adds the local
# OpenShift MCP server, registers it with AO, and manages one PR-driven AO
# workflow. The core AO addon remains responsible only for installing and
# wiring AO itself.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
source "$REPO_ROOT/includes/aap-demo-paths.sh"

env_value() {
  local value
  value=$(printenv "$1" 2>/dev/null || true)
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$2"
  fi
}

AAP_NAMESPACE=$(env_value AAP_DEMO_NAMESPACE aap-operator)
NAMESPACE=$AAP_NAMESPACE
AO_NAMESPACE=$(env_value AO_NAMESPACE automation-orchestrator)
MCP_NAMESPACE=$(env_value AO_PR_TESTING_MCP_NAMESPACE openshift-mcp-server)
MCP_RELEASE=$(env_value AO_PR_TESTING_MCP_RELEASE ao-pr-testing-openshift-mcp)
MCP_INTEGRATION_NAME=$(env_value AO_PR_TESTING_MCP_INTEGRATION_NAME 'aap-demo OpenShift MCP')
OPENSHIFT_CREDENTIAL_NAME=$(env_value AO_PR_TESTING_OPENSHIFT_CREDENTIAL_NAME 'aap-demo OpenShift MCP Access')
GITHUB_CREDENTIAL_NAME=$(env_value AO_PR_TESTING_GITHUB_CREDENTIAL_NAME 'aap-demo GitHub PR Comment Token')
GITHUB_CREDENTIAL_TYPE_NAME=$(env_value AO_PR_TESTING_GITHUB_CREDENTIAL_TYPE_NAME 'aap-demo GitHub PR Comment Token')
GITHUB_TOKEN=$(env_value AO_PR_TESTING_GITHUB_TOKEN '')
WORKFLOW_NAME=$(env_value AO_PR_TESTING_WORKFLOW_NAME 'aap-demo PR Validation')
EXECUTION_ENVIRONMENT_NAME=$(env_value AO_PR_TESTING_EE_NAME plaibook-ee)
EXECUTION_ENVIRONMENT_IMAGE=$(env_value AO_PR_TESTING_EE_IMAGE quay.io/cferman/plaibook-ee:latest)
PLAIBOOK_PROJECT_NAME=$(env_value AO_PR_TESTING_PLAIBOOK_PROJECT_NAME 'aap-demo Plaibook Review')
PLAIBOOK_PROJECT_URL=$(env_value AO_PR_TESTING_PLAIBOOK_PROJECT_URL https://github.com/RedHatOfficial/aap-demo.git)
PLAIBOOK_PROJECT_BRANCH=$(env_value AO_PR_TESTING_PLAIBOOK_PROJECT_BRANCH main)
PLAIBOOK_PLAYBOOK=$(env_value AO_PR_TESTING_PLAIBOOK_PLAYBOOK addons/ao-pr-testing/playbooks/plaibook-review-bridge.yml)
PLAIBOOK_SOURCE_URL=$(env_value AO_PR_TESTING_PLAIBOOK_SOURCE_URL https://github.com/aknochow/ansible-plaibook.git)
PLAIBOOK_SOURCE_BRANCH=$(env_value AO_PR_TESTING_PLAIBOOK_SOURCE_BRANCH main)
PLAIBOOK_INVENTORY_NAME=$(env_value AO_PR_TESTING_PLAIBOOK_INVENTORY_NAME 'aap-demo Plaibook Review Inventory')
PLAIBOOK_JOB_TEMPLATE_NAME=$(env_value AO_PR_TESTING_PLAIBOOK_JOB_TEMPLATE_NAME 'aap-demo | Plaibook PR Review')
PLAIBOOK_MODEL=$(env_value AO_PR_TESTING_PLAIBOOK_MODEL qwen2.5:3b)
PLAIBOOK_OPENAI_BASE_URL=$(env_value AO_PR_TESTING_PLAIBOOK_OPENAI_BASE_URL 'http://ollama.aap-demo-ollama.svc.cluster.local:11434/v1')
PLAIBOOK_OPENAI_API_KEY=$(env_value AO_PR_TESTING_PLAIBOOK_OPENAI_API_KEY ollama)
WEBHOOK_PATH=$(env_value AO_PR_TESTING_WEBHOOK_PATH aap-demo-pr-validation)
HOME_DIR=$(env_value HOME "$PWD")
GITHUB_CREDENTIALS_FILE=$(env_value AO_PR_TESTING_GITHUB_CREDENTIALS_FILE "$HOME_DIR/.aap-demo/apme-eap-github-creds.yml")
if [ -z "$GITHUB_TOKEN" ] && [ -r "$GITHUB_CREDENTIALS_FILE" ]; then
  GITHUB_TOKEN=$(
    python3 - "$GITHUB_CREDENTIALS_FILE" <<'PY'
from pathlib import Path
import sys

for line in Path(sys.argv[1]).read_text().splitlines():
    if line.lstrip().startswith("github_token:"):
        value = line.split(":", 1)[1].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        print(value)
        break
PY
  )
fi
STATE_DIR=$(env_value AO_PR_TESTING_STATE_DIR "$HOME_DIR/.aap-demo/ao-pr-testing")
CHART=$(env_value AO_PR_TESTING_CHART openshift-helm-charts/redhat-openshift-mcp-server)
OPENSHIFT_CREDENTIAL_ID=
GITHUB_CREDENTIAL_ID=
PLAIBOOK_JOB_TEMPLATE_ID=
ACTION=deploy
[ "$#" -gt 0 ] && ACTION=$1

export NAMESPACE AO_NAMESPACE
source "$REPO_ROOT/includes/addon-wire.sh"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

require_tools() {
  local tool
  for tool in curl helm jq kubectl; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: $tool"
  done
}

ao_is_ready() {
  wire_ao_deployed && wire_ao_route_host >/dev/null
}

ensure_aap_execution_environment() {
  local aap_route aap_password aap_api encoded_name existing ee_id payload result

  aap_route=$(wire_aap_route_host)
  aap_password=$(wire_aap_admin_password)
  [ -n "$aap_route" ] || die 'AAP route is missing; cannot register the PR testing execution environment'
  [ -n "$aap_password" ] || die 'AAP admin password is missing; cannot register the PR testing execution environment'
  aap_api="https://${aap_route}/api/controller/v2"
  encoded_name=$(jq -rn --arg name "$EXECUTION_ENVIRONMENT_NAME" '$name|@uri')

  existing=$(curl -sk -u "admin:${aap_password}" \
    "${aap_api}/execution_environments/?name=${encoded_name}")
  ee_id=$(printf '%s' "$existing" | jq -r '.results[0].id // empty' 2>/dev/null)
  payload=$(jq -n \
    --arg name "$EXECUTION_ENVIRONMENT_NAME" \
    --arg image "$EXECUTION_ENVIRONMENT_IMAGE" \
    '{name:$name,description:"Managed by the ao-pr-testing addon",image:$image,pull:"always"}')

  if [ -n "$ee_id" ]; then
    result=$(curl -sk -u "admin:${aap_password}" \
      -X PATCH -H 'Content-Type: application/json' \
      -d "$payload" "${aap_api}/execution_environments/${ee_id}/")
    if [ -n "$result" ] && printf '%s' "$result" | jq -e '.detail or .error or .errors' >/dev/null 2>&1; then
      printf '%s\n' "$result" | jq '.' >&2 || printf '%s\n' "$result" >&2
      die "Could not update AAP execution environment ${EXECUTION_ENVIRONMENT_NAME}"
    fi
    printf '  AAP execution environment ready: %s (%s)\n' "$EXECUTION_ENVIRONMENT_NAME" "$EXECUTION_ENVIRONMENT_IMAGE"
  else
    result=$(curl -sk -u "admin:${aap_password}" \
      -X POST -H 'Content-Type: application/json' \
      -d "$payload" "${aap_api}/execution_environments/")
    ee_id=$(printf '%s' "$result" | jq -r '.id // empty' 2>/dev/null)
    if [ -z "$ee_id" ]; then
      printf '%s\n' "$result" | jq '.' 2>/dev/null || printf '%s\n' "$result" >&2
      die "Could not register AAP execution environment ${EXECUTION_ENVIRONMENT_NAME}"
    fi
    printf '  AAP execution environment registered: %s (%s)\n' "$EXECUTION_ENVIRONMENT_NAME" "$EXECUTION_ENVIRONMENT_IMAGE"
  fi
  unset aap_password
}

ensure_plaibook_job_template() {
  local aap_route ao_route aap_token extra_vars ee_id ee_name_encoded
  local credential_args=()

  aap_route=$(wire_aap_route_host)
  ao_route=$(wire_ao_route_host)
  aap_token=$(wire_aap_gateway_token 'aap-demo plaibook provisioning' write)
  [ -n "$aap_route" ] || die 'AAP route is missing; cannot provision the plaibook job'
  [ -n "$ao_route" ] || die 'Automation Orchestrator route is missing; cannot provision the plaibook job'
  [ -n "$aap_token" ] || die 'Could not mint an AAP token for plaibook provisioning'

  ee_name_encoded=$(jq -rn --arg name "$EXECUTION_ENVIRONMENT_NAME" '$name|@uri')
  ee_id=$(curl -sk -H "Authorization: Bearer ${aap_token}" \
    "https://${aap_route}/api/controller/v2/execution_environments/?name=${ee_name_encoded}" \
    | jq -r '.results[0].id // empty')
  [ -n "$ee_id" ] || die "AAP execution environment is missing: $EXECUTION_ENVIRONMENT_NAME"

  extra_vars=$(jq -n \
    --arg base_url "$PLAIBOOK_OPENAI_BASE_URL" \
    --arg api_key "$PLAIBOOK_OPENAI_API_KEY" \
    --arg model "$PLAIBOOK_MODEL" \
    --arg source_url "$PLAIBOOK_SOURCE_URL" \
    --arg source_branch "$PLAIBOOK_SOURCE_BRANCH" \
    --arg aap_route "$aap_route" \
    --arg ao_route "$ao_route" \
    --argjson comment_enabled "$([ -n "$GITHUB_CREDENTIAL_ID" ] && printf true || printf false)" \
    '{review_type:"pr",post_results:false,review_comment_enabled:$comment_enabled,
      agent_family:"openai",openai_base_url:$base_url,
      openai_api_key:$api_key,review_openai_model:$model,use_sandbox:false,
      review_explore_enabled:false,
      review_run_ledger_host:"aap-plaibook",
      plaibook_source_url:$source_url,plaibook_source_branch:$source_branch,
      aap_route_host:$aap_route,ao_route_host:$ao_route}
    ')

  if [ -n "$GITHUB_CREDENTIAL_ID" ]; then
    credential_args=(--credential-id "$GITHUB_CREDENTIAL_ID")
  fi

  PLAIBOOK_JOB_TEMPLATE_ID=$(python3 "$SCRIPT_DIR/provision-plaibook.py" \
    --route "$aap_route" \
    --token "$aap_token" \
    --project-name "$PLAIBOOK_PROJECT_NAME" \
    --project-url "$PLAIBOOK_PROJECT_URL" \
    --project-branch "$PLAIBOOK_PROJECT_BRANCH" \
    --inventory-name "$PLAIBOOK_INVENTORY_NAME" \
    --job-template-name "$PLAIBOOK_JOB_TEMPLATE_NAME" \
    --playbook "$PLAIBOOK_PLAYBOOK" \
    --execution-environment-id "$ee_id" \
    "${credential_args[@]}" \
    --extra-vars-json "$extra_vars") \
    || die 'Could not provision the ansible-plaibook AAP job template'
  [ -n "$PLAIBOOK_JOB_TEMPLATE_ID" ] || die 'AAP did not return the plaibook job template ID'
  printf '  Plaibook AAP job template ready: %s (ID: %s)\n' "$PLAIBOOK_JOB_TEMPLATE_NAME" "$PLAIBOOK_JOB_TEMPLATE_ID"
  unset aap_token extra_vars ee_id
}

ensure_github_credential() {
  local aap_route aap_password aap_api encoded_name credential_type_id organization_id
  local existing credential_id payload result

  aap_route=$(wire_aap_route_host)
  aap_password=$(wire_aap_admin_password)
  [ -n "$aap_route" ] && [ -n "$aap_password" ] || return 0
  aap_api="https://${aap_route}/api/controller/v2"
  encoded_name=$(jq -rn --arg name "$GITHUB_CREDENTIAL_NAME" '$name|@uri')

  organization_id=$(curl -sk -u "admin:${aap_password}" \
    "${aap_api}/organizations/?name=Default&page_size=10" \
    | jq -r '.results[0].id // empty')
  credential_type_id=$(curl -sk -u "admin:${aap_password}" \
    "${aap_api}/credential_types/?name=$(jq -rn --arg name "$GITHUB_CREDENTIAL_TYPE_NAME" '$name|@uri')&page_size=10" \
    | jq -r '.results[0].id // empty')
  if [ -z "$organization_id" ]; then
    warn 'AAP Default organization is unavailable; PR comments disabled'
    unset aap_password
    return 0
  fi
  if [ -z "$credential_type_id" ]; then
    payload=$(jq -n \
      --arg name "$GITHUB_CREDENTIAL_TYPE_NAME" \
      --arg description 'Addon-owned GitHub token injector for PR review comments.' \
      '{name:$name,description:$description,kind:"cloud",inputs:{fields:[{id:"token",label:"GitHub token",type:"string",secret:true}],required:["token"]},injectors:{env:{GITHUB_TOKEN:"{{ token }}"}}}')
    result=$(curl -sk -u "admin:${aap_password}" -X POST \
      -H 'Content-Type: application/json' -d "$payload" \
      "${aap_api}/credential_types/")
    credential_type_id=$(printf '%s' "$result" | jq -r '.id // empty')
  fi
  if [ -z "$credential_type_id" ]; then
    warn 'Could not provision the addon GitHub credential type; PR comments disabled'
    unset aap_password payload result
    return 0
  fi

  existing=$(curl -sk -u "admin:${aap_password}" \
    "${aap_api}/credentials/?name=${encoded_name}&page_size=10")
  credential_id=$(printf '%s' "$existing" | jq -r '.results[0].id // empty')
  if [ -z "$GITHUB_TOKEN" ] && [ -n "$credential_id" ]; then
    GITHUB_CREDENTIAL_ID=$credential_id
    unset aap_password
    return 0
  fi
  if [ -z "$GITHUB_TOKEN" ]; then
    unset aap_password
    return 0
  fi

  payload=$(jq -n \
    --arg name "$GITHUB_CREDENTIAL_NAME" \
    --arg description 'Managed by the ao-pr-testing addon; used only to update the review comment on the target PR.' \
    --argjson credential_type "$credential_type_id" \
    --argjson organization "$organization_id" \
    --arg token "$GITHUB_TOKEN" \
    '{name:$name,description:$description,credential_type:$credential_type,organization:$organization,inputs:{token:$token}}')
  if [ -n "$credential_id" ]; then
    result=$(curl -sk -u "admin:${aap_password}" -X PATCH \
      -H 'Content-Type: application/json' -d "$payload" \
      "${aap_api}/credentials/${credential_id}/")
  else
    result=$(curl -sk -u "admin:${aap_password}" -X POST \
      -H 'Content-Type: application/json' -d "$payload" \
      "${aap_api}/credentials/")
    credential_id=$(printf '%s' "$result" | jq -r '.id // empty')
  fi
  if [ -z "$credential_id" ]; then
    warn 'Could not provision the AAP GitHub credential; PR comments disabled'
    unset aap_password GITHUB_TOKEN payload result
    return 0
  fi
  GITHUB_CREDENTIAL_ID=$credential_id
  unset aap_password GITHUB_TOKEN payload result
}

copy_pull_secret() {
  if kubectl get secret redhat-operators-pull-secret -n "$MCP_NAMESPACE" >/dev/null 2>&1; then
    return 0
  fi
  if ! kubectl get secret redhat-operators-pull-secret -n "$AAP_NAMESPACE" >/dev/null 2>&1; then
    warn "redhat-operators-pull-secret is not available; the OpenShift MCP image may not pull"
    return 0
  fi
  kubectl get secret redhat-operators-pull-secret -n "$AAP_NAMESPACE" -o json \
    | jq --arg namespace "$MCP_NAMESPACE" \
      'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields) | .metadata.namespace = $namespace' \
    | kubectl apply -f - >/dev/null
}

cluster_domain() {
  local aap_route
  aap_route=$(kubectl get route aap -n "$AAP_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [ -n "$aap_route" ] || die "AAP route not found in $AAP_NAMESPACE"
  printf '%s' "$aap_route" | cut -d. -f2-
}

deploy_openshift_mcp() {
  local domain mcp_host deployment_name route_host attempt
  domain=$(cluster_domain)
  mcp_host=$(env_value AO_PR_TESTING_MCP_HOST "ao-pr-testing-openshift-mcp.$domain")

  helm repo add openshift-helm-charts https://charts.openshift.io >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
  kubectl create namespace "$MCP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  copy_pull_secret

  printf 'Installing read-only OpenShift MCP server (%s)...\n' "$mcp_host"
  helm upgrade --install "$MCP_RELEASE" "$CHART" \
    --namespace "$MCP_NAMESPACE" \
    --create-namespace \
    --set openshift=true \
    --set-json 'config.toolsets=["core"]' \
    --set config.read_only=true \
    --set config.disable_destructive=true \
    --set-json 'config.deniedResources=[{"group":"","version":"v1","kind":"Secret"},{"group":"","version":"v1","kind":"ConfigMap"},{"group":"rbac.authorization.k8s.io","version":"v1","kind":"Role"},{"group":"rbac.authorization.k8s.io","version":"v1","kind":"RoleBinding"},{"group":"rbac.authorization.k8s.io","version":"v1","kind":"ClusterRole"},{"group":"rbac.authorization.k8s.io","version":"v1","kind":"ClusterRoleBinding"}]' \
    --set ingress.host="$mcp_host" \
    --set-json 'rbac.extraClusterRoleBindings=[{"name":"use-view-role","roleRef":{"name":"view","external":true}}]' \
    >/dev/null

  deployment_name=$(kubectl get deployment -n "$MCP_NAMESPACE" \
    -l "app.kubernetes.io/instance=$MCP_RELEASE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$deployment_name" ] || deployment_name=$MCP_RELEASE
  kubectl rollout status "deployment/$deployment_name" -n "$MCP_NAMESPACE" --timeout=180s

  route_host=
  for attempt in $(seq 1 30); do
    route_host=$(kubectl get route -n "$MCP_NAMESPACE" -l "app.kubernetes.io/instance=$MCP_RELEASE" \
      -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
    [ -n "$route_host" ] && break
    sleep 2
  done
  [ -n "$route_host" ] || die "OpenShift MCP route was not created"
  MCP_ROUTE_HOST=$route_host
  MCP_URL="https://$route_host/mcp"
  printf '  OpenShift MCP endpoint: %s\n' "$MCP_URL"
}

grant_dev_read_access() {
  local deployment service_account
  deployment=$(kubectl get deployment -n "$MCP_NAMESPACE" \
    -l "app.kubernetes.io/instance=$MCP_RELEASE" -o jsonpath='{.items[0].metadata.name}')
  service_account=$(kubectl get deployment "$deployment" -n "$MCP_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.serviceAccountName}')
  [ -n "$service_account" ] || die 'OpenShift MCP service account is missing'

  # The dev-cluster role fills the concrete gap in the default OpenShift view
  # role: route inspection. Sensitive core resources and RBAC objects remain
  # excluded by both RBAC and the MCP server configuration.
  kubectl apply -f - <<YAML >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ao-pr-testing-openshift-mcp-dev-read
rules:
- apiGroups: ["route.openshift.io"]
  resources: [routes]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ao-pr-testing-openshift-mcp-dev-read
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ao-pr-testing-openshift-mcp-dev-read
subjects:
- kind: ServiceAccount
  name: $service_account
  namespace: $MCP_NAMESPACE
YAML
  printf '  OpenShift MCP dev read access: %s\n' "$service_account"
}

allow_openshift_mcp_route() {
  local current allowed router_ip hosts_json dep patch
  router_ip=$(wire_ingress_router_ip)
  [ -n "$router_ip" ] || return 0
  hosts_json=$(wire_ao_route_hosts_json | jq --arg host "$MCP_ROUTE_HOST" '. + [$host] | unique')

  for dep in automation-orchestrator-backend automation-orchestrator-worker \
    automation-orchestrator-background-worker; do
    kubectl get deployment "$dep" -n "$AO_NAMESPACE" >/dev/null 2>&1 || continue
    current=$(kubectl get deployment "$dep" -n "$AO_NAMESPACE" \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="APP_INTEGRATION_URL_ALLOWED_HOSTS")].value}' \
      2>/dev/null || true)
    if [ -n "$current" ]; then
      allowed=$(printf '%s' "$current" | jq --arg host "$MCP_ROUTE_HOST" \
        '. + [$host] | unique')
    else
      allowed=$(jq -n --arg host "$MCP_ROUTE_HOST" '[$host]')
    fi
    wire_ao_patch_deployment_env "$dep" \
      "$([ "$dep" = automation-orchestrator-backend ] && printf true || printf false)" \
      "$allowed" || warn "Could not add $MCP_ROUTE_HOST to AO allow-list"

    patch=$(jq -n --arg ip "$router_ip" --argjson hosts "$hosts_json" \
      '{spec:{template:{spec:{hostAliases:[{ip:$ip,hostnames:$hosts}]}}}}')
    kubectl patch deployment "$dep" -n "$AO_NAMESPACE" --type=strategic \
      -p "$patch" >/dev/null 2>&1 || warn "Could not add $MCP_ROUTE_HOST to AO host aliases"
  done
  wire_ao_wait_for_workload_rollout
}

ensure_openshift_integration() {
  local integration_id config payload result
  config=$(jq -n --arg url "$MCP_URL" '{integration_type:"mcp_server",base_url:$url,allow_http:true,insecure_skip_tls_verify:true}')
  integration_id=$(wire_ao_find_integration_by_name "$MCP_INTEGRATION_NAME")

  if [ -n "$integration_id" ]; then
    payload=$(jq -n --arg name "$MCP_INTEGRATION_NAME" --argjson config "$config" '{name:$name,description:"Managed by the ao-pr-testing addon",configuration:$config,management_credential_id:null,enabled:true,scope:"global",labels:{addon:"ao-pr-testing",access:"read-only"}}')
    result=$(wire_ao_api PATCH "/integrations/$integration_id" "$payload")
  else
    payload=$(jq -n --arg name "$MCP_INTEGRATION_NAME" --argjson config "$config" '{name:$name,description:"Managed by the ao-pr-testing addon",integration_type:"mcp_server",configuration:$config,management_credential_id:null,enabled:true,scope:"global",labels:{addon:"ao-pr-testing",access:"read-only"}}')
    result=$(wire_ao_api POST /integrations "$payload")
    integration_id=$(printf '%s' "$result" | jq -r '.id // empty')
  fi

  if wire_ao_response_is_error "$result" || [ -z "$integration_id" ]; then
    printf '%s\n' "$result" | jq '.' 2>/dev/null || printf '%s\n' "$result" >&2
    die "Could not register the OpenShift MCP server with AO"
  fi
  wire_ao_api POST "/integrations/$integration_id/refresh" '{}' >/dev/null 2>&1 || true
  wire_ao_enable_all_tools "$integration_id"
  printf '%s' "$integration_id"
}

ensure_openshift_credential() {
  local deployment service_account token
  deployment=$(kubectl get deployment -n "$MCP_NAMESPACE" \
    -l "app.kubernetes.io/instance=$MCP_RELEASE" -o jsonpath='{.items[0].metadata.name}')
  service_account=$(kubectl get deployment "$deployment" -n "$MCP_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.serviceAccountName}')
  [ -n "$service_account" ] || die 'OpenShift MCP service account is missing'
  token=$(kubectl create token "$service_account" -n "$MCP_NAMESPACE" --duration=24h 2>/dev/null || true)
  [ -n "$token" ] || die 'Could not mint a short-lived token for the read-only OpenShift MCP connection'
  OPENSHIFT_CREDENTIAL_ID=$(wire_ao_ensure_bearer_credential "$OPENSHIFT_CREDENTIAL_NAME" "$token") \
    || die 'Could not store the OpenShift MCP access credential in AO'
  unset token
}

find_ollama_ids() {
  local ollama_integration
  ollama_integration=$(wire_ao_find_integration_by_name 'aap-demo Ollama')
  [ -n "$ollama_integration" ] || die 'AO Ollama integration is missing; enable AO first'
  OLLAMA_CREDENTIAL_ID=$(wire_ao_find_credential_by_name 'aap-demo Ollama')
  OLLAMA_MODEL_ID=$(wire_ao_api GET "/integrations/$ollama_integration/models?limit=50" \
    | wire_ao_list_items | jq -r --arg model "$WIRE_OLLAMA_MODEL" '[.[] | select(.model_id == $model)] | .[0].id // empty')
  [ -n "$OLLAMA_CREDENTIAL_ID" ] || die 'AO Ollama credential is missing; run aap-demo wire'
  [ -n "$OLLAMA_MODEL_ID" ] || die "AO Ollama model $WIRE_OLLAMA_MODEL is missing; run aap-demo wire"
}

warm_ollama_model() {
  [ "$(env_value AO_PR_TESTING_WARM_MODEL true)" = true ] || return 0
  printf '  Warming Ollama model: %s\n' "$WIRE_OLLAMA_MODEL"
  kubectl exec -n aap-demo-ollama deploy/ollama -- \
    ollama run "$WIRE_OLLAMA_MODEL" 'Respond with READY only.' \
    >/dev/null 2>&1 \
    || warn "Could not warm Ollama model $WIRE_OLLAMA_MODEL; AO will load it on demand"
}

find_webhook_service_account() {
  WEBHOOK_SERVICE_ACCOUNT_ID=$(wire_ao_api GET /service_accounts?limit=100 \
    | wire_ao_list_items | jq -r '[.[] | select(.name == "aap-demo webhook caller")] | .[0].id // empty')
  [ -n "$WEBHOOK_SERVICE_ACCOUNT_ID" ] || die 'AO webhook service account is missing; enable AO first'
}

ensure_webhook_credential() {
  local response client_id client_secret credential_id
  mkdir -p "$STATE_DIR"
  if [ -s "$STATE_DIR/webhook-client-id" ] && [ -s "$STATE_DIR/webhook-client-secret" ]; then
    return 0
  fi

  response=$(wire_ao_api POST "/service_accounts/$WEBHOOK_SERVICE_ACCOUNT_ID/credentials" \
    '{"credential_type":"client_credentials","grace_period_seconds":3600}')
  credential_id=$(printf '%s' "$response" | jq -r '.id // empty')
  client_id=$(printf '%s' "$response" | jq -r '.identifier // empty')
  client_secret=$(printf '%s' "$response" | jq -r '.client_secret // empty')
  [ -n "$credential_id" ] && [ -n "$client_id" ] && [ -n "$client_secret" ] \
    || die 'Could not create an AO client-credentials secret for the PR webhook'
  umask 077
  printf '%s' "$client_id" >"$STATE_DIR/webhook-client-id"
  printf '%s' "$client_secret" >"$STATE_DIR/webhook-client-secret"
  printf '%s' "$credential_id" >"$STATE_DIR/webhook-credential-id"
  unset client_secret response
}

build_workflow_definition() {
  local dollar aap_integration aap_credential
  dollar='$'
  aap_integration=$(wire_ao_find_integration_by_name "$WIRE_AAP_INTEGRATION_NAME")
  aap_credential=$(wire_ao_find_credential_by_name "$WIRE_AAP_CREDENTIAL_NAME")

  WORKFLOW_DEFINITION=$(jq -n \
    --arg name "$WORKFLOW_NAME" \
    --arg description 'PR-driven validation using a deterministic plaibook AAP bridge that publishes structured review artifacts.' \
    --arg webhook "$WEBHOOK_PATH" \
    --arg sa "$WEBHOOK_SERVICE_ACCOUNT_ID" \
    --argjson job_template "$PLAIBOOK_JOB_TEMPLATE_ID" \
    --arg trigger_repo "$dollar{trigger.repository}" \
    --arg trigger_number "$dollar{trigger.pull_request_number}" \
    '{schema_version:"2.0.0",name:$name,description:$description,triggers:[{id:"trigger_github_pr",name:"GitHub pull request webhook",type:"webhook_trigger",parameters:{webhook_path:$webhook,authorized_service_account_ids:[$sa]}},{id:"trigger_manual_pr",name:"Run PR validation manually",type:"manual_trigger",parameters:{input_schema:{type:"object",required:["repository","pull_request_number","head_sha"],properties:{repository:{type:"string",description:"GitHub owner/repository"},pull_request_number:{type:"integer"},pull_request_url:{type:"string"},head_sha:{type:"string"},base_ref:{type:"string"}}}}}],nodes:[{id:"run_plaibook_review",name:"Run deterministic plaibook PR review",type:"aap_job_template",parameters:{job_template_id:$job_template,extra_vars:{review_type:"pr",post_results:false,github_repository:$trigger_repo,github_pull_request_number:$trigger_number,review_targets_raw:("https://github.com/" + $trigger_repo + "/pull/" + $trigger_number)}}}],edges:[{from:"trigger_github_pr",to:"run_plaibook_review"},{from:"trigger_manual_pr",to:"run_plaibook_review"}]}')

  [ -n "$PLAIBOOK_JOB_TEMPLATE_ID" ] || die 'Plaibook AAP job template is not available for the PR workflow'
  [ -n "$aap_integration" ] && [ -n "$aap_credential" ] \
    || die 'AAP connection is not available for the PR workflow'
  WORKFLOW_DEFINITION=$(printf '%s' "$WORKFLOW_DEFINITION" | jq \
    --arg aap_integration "$aap_integration" \
    --arg aap_credential "$aap_credential" \
    '.nodes |= map(
       if .id == "run_plaibook_review" then
         .parameters += {integration_id:$aap_integration,credential_id:$aap_credential}
       else . end
     )')

}

ensure_workflow() {
  local project_id existing workflow_id payload result current_version validation publish
  project_id=$(wire_ao_default_project_id)
  [ -n "$project_id" ] || die 'No AO project is available for the PR validation workflow'
  existing=$(wire_ao_api GET /workflows?limit=100 | wire_ao_list_items)
  workflow_id=$(printf '%s' "$existing" | jq -r --arg name "$WORKFLOW_NAME" '[.[] | select(.name == $name)] | .[0].id // empty')
  if [ -z "$workflow_id" ]; then
    workflow_id=$(printf '%s' "$existing" | jq -r --arg name 'aap-demo Feature Smoke Test' '[.[] | select(.name == $name)] | .[0].id // empty')
  fi

  validation=$(wire_ao_api POST /workflows/validate "$(jq -n --argjson definition "$WORKFLOW_DEFINITION" '{workflow_definition:$definition}')")
  if printf '%s' "$validation" | jq -e '.valid == false or .has_errors == true or .errors != null' >/dev/null 2>&1; then
    printf '%s\n' "$validation" | jq '.' >&2
    die 'AO rejected the PR validation workflow definition'
  fi

  if [ -n "$workflow_id" ]; then
    current_version=$(printf '%s' "$existing" | jq -r --arg id "$workflow_id" '[.[] | select(.id == $id)] | .[0].current_version // 0')
    payload=$(jq -n --arg project "$project_id" --argjson definition "$WORKFLOW_DEFINITION" --argjson version "$current_version" '{name:$definition.name,project_id:$project,description:$definition.description,labels:{"aap-demo":"true",addon:"ao-pr-testing",purpose:"pull-request-validation"},workflow_definition:$definition,change_description:"Managed by the ao-pr-testing addon",expected_version:$version}')
    result=$(wire_ao_api PATCH "/workflows/$workflow_id" "$payload")
  else
    payload=$(jq -n --arg project "$project_id" --argjson definition "$WORKFLOW_DEFINITION" '{name:$definition.name,description:$definition.description,labels:{"aap-demo":"true",addon:"ao-pr-testing",purpose:"pull-request-validation"},workflow_definition:$definition,project_id:$project}')
    result=$(wire_ao_api POST /workflows "$payload")
    workflow_id=$(printf '%s' "$result" | jq -r '.id // empty')
  fi

  if wire_ao_response_is_error "$result" || [ -z "$workflow_id" ]; then
    printf '%s\n' "$result" | jq '.' 2>/dev/null || printf '%s\n' "$result" >&2
    die 'Could not create/update the AO PR validation workflow'
  fi
  current_version=$(wire_ao_api GET "/workflows/$workflow_id" | jq -r '.current_version // empty')
  [ -n "$current_version" ] || die 'AO did not return a workflow version'
  publish=$(wire_ao_api POST "/workflows/$workflow_id/versions/$current_version/publish" \
    "$(jq -n --arg description "Publish $WORKFLOW_NAME" --argjson version "$current_version" '{change_description:$description,expected_version:$version}')")
  if wire_ao_response_is_error "$publish"; then
    printf '%s\n' "$publish" | jq '.' 2>/dev/null || printf '%s\n' "$publish" >&2
    die 'Could not publish the AO PR validation workflow'
  fi

  mkdir -p "$STATE_DIR"
  jq -n --arg workflow "$workflow_id" --arg integration "$OPENSHIFT_INTEGRATION_ID" --arg host "$MCP_ROUTE_HOST" --arg webhook "$WEBHOOK_PATH" \
    '{workflow_id:$workflow,openshift_integration_id:$integration,openshift_mcp_route:$host,webhook_path:$webhook}' \
    >"$STATE_DIR/state.json"
  printf '  AO workflow ready: %s\n' "$WORKFLOW_NAME"
  printf '  Webhook path: %s\n' "$WEBHOOK_PATH"
}

cleanup_ao_resources() {
  local token workflow integration github_mcp credential openshift_credential webhook_credential
  ao_is_ready || return 0
  token=$(wire_ao_login_token || true)
  [ -n "$token" ] || return 0
  export AO_ACCESS_TOKEN="$token"
  workflow=$(wire_ao_api GET /workflows?limit=100 | wire_ao_list_items \
    | jq -r --arg name "$WORKFLOW_NAME" '[.[] | select(.name == $name and .labels.addon == "ao-pr-testing")] | .[0].id // empty')
  [ -n "$workflow" ] && wire_ao_api DELETE "/workflows/$workflow" >/dev/null 2>&1 || true
  integration=$(wire_ao_find_integration_by_name "$MCP_INTEGRATION_NAME")
  [ -n "$integration" ] && wire_ao_api DELETE "/integrations/$integration" >/dev/null 2>&1 || true
  github_mcp=$(wire_ao_find_integration_by_name 'aap-demo GitHub MCP')
  [ -n "$github_mcp" ] && wire_ao_api DELETE "/integrations/$github_mcp" >/dev/null 2>&1 || true
  credential=$(wire_ao_find_credential_by_name "$GITHUB_CREDENTIAL_NAME")
  [ -n "$credential" ] && wire_ao_api DELETE "/credentials/$credential" >/dev/null 2>&1 || true
  openshift_credential=$(wire_ao_find_credential_by_name "$OPENSHIFT_CREDENTIAL_NAME")
  [ -n "$openshift_credential" ] && wire_ao_api DELETE "/credentials/$openshift_credential" >/dev/null 2>&1 || true
  webhook_credential=$(cat "$STATE_DIR/webhook-credential-id" 2>/dev/null || true)
  if [ -n "$webhook_credential" ]; then
    wire_ao_api DELETE "/service_accounts/$WEBHOOK_SERVICE_ACCOUNT_ID/credentials/$webhook_credential" \
      >/dev/null 2>&1 || true
  fi
}

cleanup() {
  cleanup_ao_resources
  helm uninstall "$MCP_RELEASE" -n "$MCP_NAMESPACE" >/dev/null 2>&1 || true
  kubectl delete namespace "$MCP_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  rm -f "$STATE_DIR/state.json" "$STATE_DIR/github-credential-id" \
    "$STATE_DIR/webhook-client-id" "$STATE_DIR/webhook-client-secret" \
    "$STATE_DIR/webhook-credential-id"
  rmdir "$STATE_DIR" >/dev/null 2>&1 || true
  printf 'ao-pr-testing addon disabled\n'
}

require_tools
if [ "$ACTION" = '--delete' ] || [ "$ACTION" = delete ]; then
  cleanup
  exit 0
fi

kubectl cluster-info >/dev/null 2>&1 || die 'Cannot connect to the OpenShift cluster'
ao_is_ready || die 'Automation Orchestrator is not ready; enable the ao addon first'
ensure_aap_execution_environment
ensure_github_credential
ensure_plaibook_job_template
deploy_openshift_mcp
grant_dev_read_access
wire_restore_coredns_route_rewrite || warn 'CoreDNS route rewrite could not be refreshed'
wire_ao_network_access || warn 'AO integration allow-list could not be refreshed'
allow_openshift_mcp_route
AO_ACCESS_TOKEN=$(wire_ao_login_token)
export AO_ACCESS_TOKEN
OPENSHIFT_INTEGRATION_ID=$(ensure_openshift_integration)
ensure_openshift_credential
find_ollama_ids
warm_ollama_model
find_webhook_service_account
mkdir -p "$STATE_DIR"
ensure_webhook_credential
build_workflow_definition
ensure_workflow
printf 'ao-pr-testing addon enabled\n'
