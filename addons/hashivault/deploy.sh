#!/usr/bin/env bash
# Deploy HashiCorp Vault for AAP Secret Management Demo
#
# Deploys HashiCorp Vault using Helm chart in dev mode and configures AAP
# integration for demonstrating runtime secret injection.
#
# Prerequisites:
#   - AAP deployed (aap-demo deploy)
#   - kubectl, helm, jq, curl available
#   - Cluster with adequate resources
#
# Usage:
#   ./deploy.sh                    # Deploy vault and configure AAP
#   ./deploy.sh --delete           # Remove vault and AAP resources
#   ./deploy.sh --delete --purge-data  # Also remove state directory
#   ./deploy.sh --force            # Force reinstall
#
# Environment Variables:
#   VAULT_CHART_VERSION    - Helm chart version (default: 0.28.0)
#   VAULT_VERSION          - Vault image version (default: 1.17.2)
#   AAP_DEMO_REPO          - Playbook repository (default: RedHatOfficial/aap-demo)
#   AAP_DEMO_BRANCH        - Playbook branch (default: main)
#   FORCE                  - Set to 1 to force reinstall
#   PURGE_DATA             - Set to 1 to remove state on disable

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source aap-demo paths helper
# shellcheck source=../../includes/aap-demo-paths.sh
source "${SCRIPT_DIR}/../../includes/aap-demo-paths.sh"

# Source vault helper functions
# shellcheck source=lib/vault-helpers.sh
source "${SCRIPT_DIR}/lib/vault-helpers.sh"

# Resolve kubeconfig
KUBECONFIG_PATH="$(aap_demo_resolve_kubeconfig "${KUBECONFIG:-}")"
export KUBECONFIG="$KUBECONFIG_PATH"

# Configuration
NAMESPACE="${NAMESPACE:-aap-operator}"
VAULT_HELM_CHART="hashicorp/vault"
VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-0.28.0}"
VAULT_VERSION="${VAULT_VERSION:-1.17.2}"
VAULT_STATE_DIR="${VAULT_STATE_DIR:-$HOME/.aap-demo/hashivault}"
VAULT_ROOT_TOKEN_FILE="${VAULT_STATE_DIR}/root-token"
VAULT_CONFIG_FILE="${VAULT_STATE_DIR}/config"

# AAP Demo repository configuration (for playbooks)
AAP_DEMO_REPO="${AAP_DEMO_REPO:-https://github.com/RedHatOfficial/aap-demo.git}"
AAP_DEMO_BRANCH="${AAP_DEMO_BRANCH:-main}"

# AAP API configuration (populated by init_aap_connection)
AAP_ROUTE=""
AAP_PASSWORD=""
AAP_API=""
AAP_USERNAME="admin"

# Parse arguments
ACTION="${1:-deploy}"
FORCE="${FORCE:-}"
PURGE_DATA="${PURGE_DATA:-}"

for _arg in "$@"; do
  case "$_arg" in
    --force) FORCE=1 ;;
    --purge-data) PURGE_DATA=1 ;;
    --delete) ACTION="delete" ;;
  esac
done

# ── Utility Functions ─────────────────────────────────────────────────────────

check_prerequisites() {
  echo "Checking prerequisites..."

  # Check cluster connectivity
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "❌ ERROR: kubectl not connected to cluster"
    echo "  Run: aap-demo create"
    exit 1
  fi

  # Check AAP is deployed
  if ! kubectl get aap aap -n "$NAMESPACE" &>/dev/null; then
    echo "❌ ERROR: AAP not deployed in namespace '$NAMESPACE'"
    echo "  Deploy AAP first: aap-demo deploy"
    exit 1
  fi

  # Check AAP is ready
  local aap_status
  aap_status=$(kubectl get aap aap -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || echo "Unknown")
  if [ "$aap_status" != "True" ]; then
    echo "❌ ERROR: AAP is not ready (status: $aap_status)"
    echo "  Wait for AAP to deploy: aap-demo status"
    exit 1
  fi

  # Check required commands
  for cmd in kubectl helm jq curl base64; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "❌ ERROR: Required command not found: $cmd"
      exit 1
    fi
  done

  echo "✓ Prerequisites satisfied"
}

ensure_state_dir() {
  if [ ! -d "$VAULT_STATE_DIR" ]; then
    mkdir -p "$VAULT_STATE_DIR"
    chmod 700 "$VAULT_STATE_DIR"
  fi
}

save_vault_config() {
  local root_token="$1"
  local vault_url="$2"

  ensure_state_dir

  # Save root token
  echo "$root_token" > "$VAULT_ROOT_TOKEN_FILE"
  chmod 600 "$VAULT_ROOT_TOKEN_FILE"

  # Save configuration
  cat > "$VAULT_CONFIG_FILE" <<EOF
VAULT_ADDR=${vault_url}
VAULT_ROOT_TOKEN=${root_token}
VAULT_NAMESPACE=${NAMESPACE}
EOF
  chmod 600 "$VAULT_CONFIG_FILE"

  echo "✓ Vault configuration saved to: $VAULT_STATE_DIR"
}

load_vault_config() {
  if [ -f "$VAULT_CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$VAULT_CONFIG_FILE"
    return 0
  fi
  return 1
}

init_aap_connection() {
  echo "Initializing AAP connection..."

  # Get AAP route
  AAP_ROUTE=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
  if [ -z "$AAP_ROUTE" ]; then
    echo "❌ ERROR: Failed to get AAP route"
    exit 1
  fi

  # Get AAP admin password
  AAP_PASSWORD=$(kubectl get secret aap-admin-password -n "$NAMESPACE" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  if [ -z "$AAP_PASSWORD" ]; then
    echo "❌ ERROR: Failed to get AAP admin password"
    exit 1
  fi

  # Set API endpoint
  AAP_API="https://${AAP_ROUTE}/api/controller/v2"

  echo "✓ AAP connection initialized"
  echo "  Route: $AAP_ROUTE"
  echo "  API: $AAP_API"
}

# ── Helm Deployment Functions ────────────────────────────────────────────────

deploy_vault_helm() {
  echo "Deploying HashiCorp Vault via Helm..."

  # Add hashicorp helm repository
  if ! helm repo list 2>/dev/null | grep -q "^hashicorp"; then
    echo "  Adding hashicorp Helm repository..."
    helm repo add hashicorp https://helm.releases.hashicorp.com
  fi
  helm repo update hashicorp >/dev/null 2>&1

  # Check if vault is already deployed
  if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "^vault"; then
    if [ "$FORCE" = "1" ]; then
      echo "  Vault already deployed. Force flag set, uninstalling..."
      helm uninstall vault -n "$NAMESPACE" >/dev/null 2>&1 || true
      kubectl delete pod vault-0 -n "$NAMESPACE" --force --grace-period=0 >/dev/null 2>&1 || true
      sleep 5
    else
      echo "✓ Vault already deployed (use FORCE=1 to reinstall)"
      return 0
    fi
  fi

  # Create values file for dev mode
  local values_file
  values_file=$(mktemp)
  cat > "$values_file" <<'EOF'
global:
  enabled: true
  tlsDisable: true

server:
  dev:
    enabled: true
    devRootToken: "root"

  service:
    enabled: true
    port: 8200

  dataStorage:
    enabled: false

  resources:
    requests:
      memory: "256Mi"
      cpu: "250m"
    limits:
      memory: "512Mi"
      cpu: "500m"

  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    fsGroup: 1000
EOF

  # Deploy vault
  echo "  Installing Vault chart (version ${VAULT_CHART_VERSION})..."
  if ! helm install vault "$VAULT_HELM_CHART" \
    --version "$VAULT_CHART_VERSION" \
    --namespace "$NAMESPACE" \
    --values "$values_file" \
    --wait --timeout=5m >/dev/null 2>&1; then
    echo "❌ ERROR: Helm install failed"
    rm -f "$values_file"
    exit 1
  fi

  rm -f "$values_file"
  echo "✓ Vault chart deployed (version ${VAULT_CHART_VERSION})"
}

wait_for_vault_ready() {
  echo "  Waiting for vault pod ready..."

  local timeout=120
  local elapsed=0

  while [ $elapsed -lt $timeout ]; do
    if vault_pod_ready; then
      echo "✓ Vault pod ready (vault-0)"
      return 0
    fi

    local phase
    phase=$(vault_pod_phase)
    printf "  ⏳ Vault pod phase: %s (waiting %d/%d seconds)\r" "$phase" "$elapsed" "$timeout"

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo ""
  echo "❌ ERROR: Vault pod did not become ready within ${timeout} seconds"
  kubectl describe pod vault-0 -n "$NAMESPACE" | tail -20
  exit 1
}

extract_root_token() {
  # In dev mode, root token is always "root"
  echo "root"
}

configure_vault_route() {
  echo "Configuring Vault route..."

  # Check if route already exists
  if kubectl get route vault -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "✓ Vault route already exists"
    return 0
  fi

  # Create route
  cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: vault
  namespace: ${NAMESPACE}
spec:
  port:
    targetPort: 8200
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  to:
    kind: Service
    name: vault
    weight: 100
  wildcardPolicy: None
EOF

  echo "✓ Vault route created"
}

# ── Vault Initialization Functions ───────────────────────────────────────────

initialize_vault() {
  echo "Initializing Vault..."

  # Check if KV v2 engine already exists
  if vault_kv_engine_exists "secret/"; then
    echo "✓ KV v2 secrets engine already enabled at: secret/"
    return 0
  fi

  # Enable KV v2 secrets engine
  if vault_exec secrets enable -path=secret kv-v2; then
    echo "✓ KV v2 secrets engine enabled at: secret/"
  else
    echo "⚠ WARNING: Failed to enable KV v2 engine (may already exist)"
  fi
}

create_test_secrets() {
  echo "Creating test secrets..."

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Create demo secrets
  if vault_exec kv put secret/demo \
    api_key="demo-api-key-12345" \
    database_password="demo-db-pass-67890" \
    environment="development" \
    created_at="$timestamp" >/dev/null 2>&1; then
    echo "✓ Test secrets created:"
    echo "  - secret/demo (api_key, database_password, environment, created_at)"
  else
    echo "❌ ERROR: Failed to create test secrets"
    exit 1
  fi
}

verify_secrets_created() {
  if vault_exec kv get secret/demo >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ── AAP Integration Functions ────────────────────────────────────────────────

create_hashivault_organization() {
  echo "Creating HashiVault organization..."

  local org_name="HashiVault Secrets Management"
  local org_description="Demonstration of HashiCorp Vault integration with AAP for secret management"

  # Check if organization already exists
  local existing_org
  existing_org=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/organizations/?name=${org_name// /%20}" 2>/dev/null | \
    jq -r '.results[0].id // empty')

  if [ -n "$existing_org" ]; then
    echo "✓ Organization already exists: $org_name (ID: $existing_org)"
    echo "$existing_org"
    return 0
  fi

  # Create organization
  local org_payload
  org_payload=$(jq -n \
    --arg name "$org_name" \
    --arg description "$org_description" \
    '{name: $name, description: $description}')

  local result
  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$org_payload" \
    "${AAP_API}/organizations/" 2>/dev/null)

  local org_id
  org_id=$(echo "$result" | jq -r '.id // empty')

  if [ -z "$org_id" ]; then
    echo "❌ ERROR: Failed to create organization: $org_name"
    echo "$result" | jq '.' 2>/dev/null || echo "$result"
    exit 1
  fi

  echo "✓ Organization created: $org_name (ID: $org_id)"
  echo "$org_id"
}

enable_aap_oidc_feature_flag() {
  echo "Enabling OIDC workload identity feature flag in AAP..."

  # Check if AAP CR has feature_flags field
  local has_feature_flags
  has_feature_flags=$(kubectl get aap aap -n "$NAMESPACE" -o jsonpath='{.spec.feature_flags}' 2>/dev/null)

  if [ -n "$has_feature_flags" ]; then
    echo "  Feature flags already configured in AAP CR"
    return 0
  fi

  # Patch AAP CR to add feature flag
  local patch_json='{"spec":{"feature_flags":{"FEATURE_OIDC_WORKLOAD_IDENTITY_ENABLED":true}}}'

  if kubectl patch aap aap -n "$NAMESPACE" --type=merge -p "$patch_json" >/dev/null 2>&1; then
    echo "✓ OIDC workload identity feature flag enabled in AAP CR"
  else
    echo "⚠ WARNING: Failed to patch AAP CR with feature flag"
    echo "  You may need to manually add to config/crs/aap-minimal.yaml:"
    echo "  spec:"
    echo "    feature_flags:"
    echo "      FEATURE_OIDC_WORKLOAD_IDENTITY_ENABLED: true"
  fi
}

configure_vault_jwt_auth() {
  echo "Configuring Vault JWT authentication backend..."

  # Get AAP route for OIDC discovery URL
  local aap_route
  aap_route=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
  if [ -z "$aap_route" ]; then
    echo "❌ ERROR: Failed to get AAP route"
    return 1
  fi

  local oidc_discovery_url="https://${aap_route}/o"

  # Check if JWT auth backend is already enabled
  if vault_exec auth list -format=json 2>/dev/null | jq -e '.["jwt/"]' >/dev/null 2>&1; then
    echo "  JWT auth backend already enabled"
  else
    # Enable JWT auth backend
    if vault_exec auth enable jwt >/dev/null 2>&1; then
      echo "✓ JWT auth backend enabled at: /auth/jwt"
    else
      echo "❌ ERROR: Failed to enable JWT auth backend"
      return 1
    fi
  fi

  # Configure JWT backend with OIDC discovery URL
  echo "  Configuring OIDC discovery URL: $oidc_discovery_url"
  if vault_exec write auth/jwt/config \
    oidc_discovery_url="$oidc_discovery_url" >/dev/null 2>&1; then
    echo "✓ JWT backend configured with AAP OIDC discovery URL"
  else
    echo "⚠ WARNING: Failed to configure JWT backend (may already be configured)"
  fi

  return 0
}

create_vault_policy() {
  echo "Creating Vault policy for AAP access..."

  local policy_name="aap-demo-policy"

  # Create policy that allows reading secrets
  local policy_hcl='
path "secret/data/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/*" {
  capabilities = ["read", "list"]
}

path "secret/*" {
  capabilities = ["read", "list"]
}
'

  # Write policy to vault
  if echo "$policy_hcl" | vault_exec policy write "$policy_name" - >/dev/null 2>&1; then
    echo "✓ Vault policy created: $policy_name"
  else
    echo "⚠ WARNING: Failed to create vault policy (may already exist)"
  fi
}

create_vault_jwt_role() {
  echo "Creating Vault JWT role for AAP..."

  local role_name="aap-demo-role"
  local vault_url="http://vault.${NAMESPACE}.svc.cluster.local:8200"

  # Create JWT role with bound_audiences matching Vault URL
  if vault_exec write "auth/jwt/role/${role_name}" \
    role_type=jwt \
    bound_audiences="$vault_url" \
    user_claim=sub \
    policies=aap-demo-policy >/dev/null 2>&1; then
    echo "✓ JWT role created: $role_name"
    echo "  Bound audiences: $vault_url"
    echo "  Policies: aap-demo-policy"
  else
    echo "⚠ WARNING: Failed to create JWT role (may already exist)"
  fi
}

create_hashivault_project() {
  local org_id="$1"
  echo "Creating HashiVault project..."

  local project_name="HashiVault - Playbooks"
  local scm_url="$AAP_DEMO_REPO"
  local scm_branch="$AAP_DEMO_BRANCH"

  # Check if project already exists
  local existing_project
  existing_project=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/projects/?name=${project_name// /%20}" 2>/dev/null | \
    jq -r '.results[0].id // empty')

  if [ -n "$existing_project" ]; then
    echo "✓ Project already exists: $project_name (ID: $existing_project)"
    echo "$existing_project"
    return 0
  fi

  # Create project
  local project_payload
  project_payload=$(jq -n \
    --arg name "$project_name" \
    --argjson org "$org_id" \
    --arg scm_type "git" \
    --arg scm_url "$scm_url" \
    --arg scm_branch "$scm_branch" \
    '{
      name: $name,
      organization: $org,
      scm_type: $scm_type,
      scm_url: $scm_url,
      scm_branch: $scm_branch,
      scm_update_on_launch: false
    }')

  local result
  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$project_payload" \
    "${AAP_API}/projects/" 2>/dev/null)

  local project_id
  project_id=$(echo "$result" | jq -r '.id // empty')

  if [ -z "$project_id" ]; then
    echo "❌ ERROR: Failed to create project: $project_name"
    echo "$result" | jq '.' 2>/dev/null || echo "$result"
    return 1
  fi

  echo "✓ Project created: $project_name (ID: $project_id)"

  # Trigger project sync
  echo "  Syncing project..."
  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    "${AAP_API}/projects/${project_id}/update/" >/dev/null 2>&1

  # Wait for sync to complete
  local sync_timeout=60
  local elapsed=0
  while [ $elapsed -lt $sync_timeout ]; do
    local status
    status=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/projects/${project_id}/" 2>/dev/null | \
      jq -r '.status // empty')

    if [ "$status" = "successful" ]; then
      echo "✓ Project synced successfully"
      break
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  echo "$project_id"
}

create_localhost_inventory() {
  local org_id="$1"
  echo "Creating localhost inventory..."

  local inventory_name="HashiVault Localhost"

  # Check if inventory already exists
  local existing_inventory
  existing_inventory=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/inventories/?name=${inventory_name// /%20}" 2>/dev/null | \
    jq -r '.results[0].id // empty')

  if [ -n "$existing_inventory" ]; then
    echo "✓ Inventory already exists: $inventory_name (ID: $existing_inventory)"
    echo "$existing_inventory"
    return 0
  fi

  # Create inventory
  local inventory_payload
  inventory_payload=$(jq -n \
    --arg name "$inventory_name" \
    --argjson org "$org_id" \
    '{name: $name, organization: $org}')

  local result
  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$inventory_payload" \
    "${AAP_API}/inventories/" 2>/dev/null)

  local inventory_id
  inventory_id=$(echo "$result" | jq -r '.id // empty')

  if [ -z "$inventory_id" ]; then
    echo "❌ ERROR: Failed to create inventory"
    return 1
  fi

  echo "✓ Inventory created: $inventory_name (ID: $inventory_id)"

  # Add localhost host
  local host_payload
  host_payload=$(jq -n \
    --arg name "localhost" \
    --arg variables "ansible_connection: local" \
    '{name: $name, variables: $variables}')

  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$host_payload" \
    "${AAP_API}/inventories/${inventory_id}/hosts/" >/dev/null 2>&1

  echo "  Host added: localhost"
  echo "$inventory_id"
}

lookup_builtin_oidc_credential_type() {
  echo "Looking up built-in OIDC credential type..."

  # AAP 2.7+ has built-in "HashiCorp Vault Secret Lookup" with kind "hashivault-kv-oidc"
  # Look for it by kind or by name pattern
  local type_id

  # Try to find by name containing "HashiCorp Vault" and "Secret Lookup"
  type_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/credential_types/?kind=hashivault-kv-oidc" 2>/dev/null | \
    jq -r '.results[0].id // empty')

  if [ -z "$type_id" ]; then
    # Fallback: try by name
    type_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/credential_types/" 2>/dev/null | \
      jq -r '.results[] | select(.name | contains("HashiCorp Vault")) | select(.name | contains("Secret Lookup")) | .id' | head -1)
  fi

  if [ -z "$type_id" ]; then
    echo "❌ ERROR: Could not find built-in HashiCorp Vault OIDC credential type"
    echo "  This type should be available in AAP 2.7+ with OIDC feature enabled"
    echo "  Verify feature flag is set: FEATURE_OIDC_WORKLOAD_IDENTITY_ENABLED"
    return 1
  fi

  echo "✓ Built-in OIDC credential type found (ID: $type_id)"
  echo "$type_id"
}

create_token_credential_type() {
  echo "Creating Token credential type..."

  local type_name="HashiCorp Vault Secret Lookup (Token)"

  # Check if type already exists
  local existing_type
  existing_type=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/credential_types/?name=${type_name// /%20}" 2>/dev/null | \
    jq -r '.results[0].id // empty')

  if [ -n "$existing_type" ]; then
    echo "✓ Credential type already exists: $type_name (ID: $existing_type)"
    echo "$existing_type"
    return 0
  fi

  # Create token-based credential type
  local inputs_schema
  inputs_schema=$(cat <<'EOF'
{
  "fields": [
    {
      "id": "url",
      "label": "Server URL",
      "type": "string",
      "help_text": "The URL used to communicate with HashiCorp Vault."
    },
    {
      "id": "token",
      "label": "Vault Token",
      "type": "string",
      "secret": true,
      "help_text": "Vault authentication token (root token for demo)."
    },
    {
      "id": "namespace",
      "label": "Namespace Name",
      "type": "string",
      "help_text": "Vault Enterprise namespace (leave blank for OSS)."
    },
    {
      "id": "api_version",
      "label": "API Version",
      "type": "string",
      "choices": ["v1", "v2"],
      "default": "v2",
      "help_text": "Vault KV secrets engine version."
    }
  ],
  "required": ["url", "token"]
}
EOF
)

  local injector_schema
  injector_schema=$(cat <<'EOF'
{
  "env": {
    "VAULT_ADDR": "{{ url }}",
    "VAULT_TOKEN": "{{ token }}",
    "VAULT_NAMESPACE": "{{ namespace | default('', true) }}",
    "VAULT_API_VERSION": "{{ api_version | default('v2', true) }}"
  }
}
EOF
)

  local type_payload
  type_payload=$(jq -n \
    --arg name "$type_name" \
    --arg kind "cloud" \
    --argjson inputs "$inputs_schema" \
    --argjson injectors "$injector_schema" \
    '{
      name: $name,
      kind: $kind,
      inputs: $inputs,
      injectors: $injectors
    }')

  local result
  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$type_payload" \
    "${AAP_API}/credential_types/" 2>/dev/null)

  local type_id
  type_id=$(echo "$result" | jq -r '.id // empty')

  if [ -z "$type_id" ]; then
    echo "❌ ERROR: Failed to create Token credential type"
    echo "$result" | jq '.' 2>/dev/null || echo "$result"
    return 1
  fi

  echo "✓ Token credential type created (ID: $type_id)"
  echo "$type_id"
}

create_oidc_credential() {
  local org_id="$1"
  local type_id="$2"
  echo "Creating OIDC credential instance..."

  local cred_name="HashiVault - OIDC Demo"
  local vault_url="http://vault.${NAMESPACE}.svc.cluster.local:8200"

  # Check if credential already exists
  local existing_cred
  existing_cred=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/credentials/?name=${cred_name// /%20}" 2>/dev/null | \
    jq -r '.results[0].id // empty')

  if [ -n "$existing_cred" ]; then
    echo "✓ Credential already exists: $cred_name (ID: $existing_cred)"
    echo "$existing_cred"
    return 0
  fi

  # Create credential using AAP 2.7 built-in type field names
  local cred_payload
  cred_payload=$(jq -n \
    --arg name "$cred_name" \
    --argjson org "$org_id" \
    --argjson type "$type_id" \
    --arg url "$vault_url" \
    --arg jwt_role "aap-demo-role" \
    --arg auth_path "jwt" \
    --arg api_version "v2" \
    '{
      name: $name,
      organization: $org,
      credential_type: $type,
      inputs: {
        url: $url,
        jwt_role: $jwt_role,
        default_auth_path: $auth_path,
        api_version: $api_version
      }
    }')

  local result
  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$cred_payload" \
    "${AAP_API}/credentials/" 2>/dev/null)

  local cred_id
  cred_id=$(echo "$result" | jq -r '.id // empty')

  if [ -z "$cred_id" ]; then
    echo "❌ ERROR: Failed to create OIDC credential"
    echo "$result" | jq '.' 2>/dev/null || echo "$result"
    return 1
  fi

  echo "✓ OIDC credential created (ID: $cred_id)"
  echo "  Using built-in AAP 2.7 OIDC type"
  echo "  JWT Role: aap-demo-role"
  echo "  AAP will automatically exchange JWTs for Vault tokens"
  echo "$cred_id"
}

create_token_credential() {
  local org_id="$1"
  local type_id="$2"
  echo "Creating Token credential instance..."

  local cred_name="HashiVault - Token Demo"
  local vault_url="http://vault.${NAMESPACE}.svc.cluster.local:8200"
  local root_token="root"

  # Check if credential already exists
  local existing_cred
  existing_cred=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/credentials/?name=${cred_name// /%20}" 2>/dev/null | \
    jq -r '.results[0].id // empty')

  if [ -n "$existing_cred" ]; then
    echo "✓ Credential already exists: $cred_name (ID: $existing_cred)"
    echo "$existing_cred"
    return 0
  fi

  # Create credential
  local cred_payload
  cred_payload=$(jq -n \
    --arg name "$cred_name" \
    --argjson org "$org_id" \
    --argjson type "$type_id" \
    --arg url "$vault_url" \
    --arg token "$root_token" \
    --arg api_version "v2" \
    '{
      name: $name,
      organization: $org,
      credential_type: $type,
      inputs: {
        url: $url,
        token: $token,
        namespace: "",
        api_version: $api_version
      }
    }')

  local result
  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$cred_payload" \
    "${AAP_API}/credentials/" 2>/dev/null)

  local cred_id
  cred_id=$(echo "$result" | jq -r '.id // empty')

  if [ -z "$cred_id" ]; then
    echo "❌ ERROR: Failed to create Token credential"
    echo "$result" | jq '.' 2>/dev/null || echo "$result"
    return 1
  fi

  echo "✓ Token credential created (ID: $cred_id)"
  echo "$cred_id"
}

create_job_template() {
  local name="$1"
  local description="$2"
  local playbook="$3"
  local project_id="$4"
  local inventory_id="$5"
  local org_id="$6"
  local credential_ids="$7"
  local extra_vars="${8:-{}}"

  # Check if template already exists
  local existing_template
  existing_template=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/job_templates/?name=${name// /%20}" 2>/dev/null | \
    jq -r ".results[] | select(.organization == $org_id) | .id // empty" | head -1)

  if [ -n "$existing_template" ]; then
    # Update existing template
    local update_payload
    update_payload=$(jq -n \
      --arg desc "$description" \
      --arg playbook "$playbook" \
      --argjson project_id "$project_id" \
      --argjson inventory_id "$inventory_id" \
      --arg extra_vars "$extra_vars" \
      '{
        description: $desc,
        playbook: $playbook,
        project: $project_id,
        inventory: $inventory_id,
        extra_vars: $extra_vars
      }')

    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X PATCH \
      -H "Content-Type: application/json" \
      -d "$update_payload" \
      "${AAP_API}/job_templates/${existing_template}/" \
      >/dev/null 2>&1 || true

    echo "$existing_template"
    return 0
  fi

  # Create new job template
  local template_payload
  template_payload=$(jq -n \
    --arg name "$name" \
    --arg desc "$description" \
    --arg playbook "$playbook" \
    --argjson project_id "$project_id" \
    --argjson inventory_id "$inventory_id" \
    --argjson org_id "$org_id" \
    --arg extra_vars "$extra_vars" \
    '{
      name: $name,
      description: $desc,
      job_type: "run",
      inventory: $inventory_id,
      project: $project_id,
      playbook: $playbook,
      organization: $org_id,
      extra_vars: $extra_vars,
      ask_variables_on_launch: false
    }')

  local result
  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$template_payload" \
    "${AAP_API}/job_templates/" 2>/dev/null)

  local template_id
  template_id=$(echo "$result" | jq -r '.id // empty')

  if [ -z "$template_id" ]; then
    echo "❌ ERROR: Failed to create job template: $name" >&2
    echo "$result" | jq '.' 2>/dev/null || echo "$result" >&2
    return 1
  fi

  # Attach credentials if provided
  if [ -n "$credential_ids" ]; then
    for credential_id in $credential_ids; do
      curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"id\": $credential_id}" \
        "${AAP_API}/job_templates/${template_id}/credentials/" \
        >/dev/null 2>&1 || true
    done
  fi

  echo "$template_id"
}

create_job_templates() {
  local project_id="$1"
  local inventory_id="$2"
  local org_id="$3"
  local oidc_cred_id="$4"
  local token_cred_id="$5"

  echo "Creating job templates..."

  local vault_url="http://vault.${NAMESPACE}.svc.cluster.local:8200"
  local playbook_path="addons/hashivault/playbooks"

  # OIDC Templates
  echo "  Creating OIDC-based templates..."

  create_job_template \
    "HashiVault (OIDC) | Test Connection" \
    "Test Vault connectivity using OIDC authentication" \
    "${playbook_path}/test-vault-connection.yml" \
    "$project_id" "$inventory_id" "$org_id" "" \
    "{\"vault_url\": \"$vault_url\"}" >/dev/null

  create_job_template \
    "HashiVault (OIDC) | Read Secret" \
    "Read secret from Vault using OIDC authentication" \
    "${playbook_path}/read-secret-demo.yml" \
    "$project_id" "$inventory_id" "$org_id" "$oidc_cred_id" \
    "{\"secret_path\": \"secret/data/demo\"}" >/dev/null

  create_job_template \
    "HashiVault (OIDC) | Update Secret" \
    "Update secret in Vault using OIDC authentication" \
    "${playbook_path}/update-secret-demo.yml" \
    "$project_id" "$inventory_id" "$org_id" "$oidc_cred_id" \
    "{\"secret_path\": \"secret/data/demo\"}" >/dev/null

  create_job_template \
    "HashiVault (OIDC) | Verify Runtime Injection" \
    "Re-read secret to verify runtime injection using OIDC" \
    "${playbook_path}/verify-runtime-injection.yml" \
    "$project_id" "$inventory_id" "$org_id" "$oidc_cred_id" \
    "{\"secret_path\": \"secret/data/demo\"}" >/dev/null

  # Token Templates
  echo "  Creating Token-based templates..."

  create_job_template \
    "HashiVault (Token) | Test Connection" \
    "Test Vault connectivity using Token authentication" \
    "${playbook_path}/test-vault-connection.yml" \
    "$project_id" "$inventory_id" "$org_id" "" \
    "{\"vault_url\": \"$vault_url\"}" >/dev/null

  create_job_template \
    "HashiVault (Token) | Read Secret" \
    "Read secret from Vault using Token authentication" \
    "${playbook_path}/read-secret-demo.yml" \
    "$project_id" "$inventory_id" "$org_id" "$token_cred_id" \
    "{\"secret_path\": \"secret/data/demo\"}" >/dev/null

  create_job_template \
    "HashiVault (Token) | Update Secret" \
    "Update secret in Vault using Token authentication" \
    "${playbook_path}/update-secret-demo.yml" \
    "$project_id" "$inventory_id" "$org_id" "$token_cred_id" \
    "{\"secret_path\": \"secret/data/demo\"}" >/dev/null

  create_job_template \
    "HashiVault (Token) | Verify Runtime Injection" \
    "Re-read secret to verify runtime injection using Token" \
    "${playbook_path}/verify-runtime-injection.yml" \
    "$project_id" "$inventory_id" "$org_id" "$token_cred_id" \
    "{\"secret_path\": \"secret/data/demo\"}" >/dev/null

  echo "✓ Job templates created (8 total: 4 OIDC + 4 Token)"
}

# ── Cleanup Functions ─────────────────────────────────────────────────────────

delete_vault_resources() {
  echo "Removing Vault resources..."

  # Uninstall helm chart
  if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "^vault"; then
    echo "  Uninstalling Vault Helm release..."
    helm uninstall vault -n "$NAMESPACE" >/dev/null 2>&1 || true
  fi

  # Delete route
  if kubectl get route vault -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "  Deleting Vault route..."
    kubectl delete route vault -n "$NAMESPACE" >/dev/null 2>&1 || true
  fi

  # Force delete pod if stuck
  if kubectl get pod vault-0 -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "  Forcing vault pod deletion..."
    kubectl delete pod vault-0 -n "$NAMESPACE" --force --grace-period=0 >/dev/null 2>&1 || true
  fi

  echo "✓ Vault resources removed"
}

delete_aap_resources() {
  echo "Removing AAP resources..."

  if ! init_aap_connection 2>/dev/null; then
    echo "⚠ WARNING: AAP not accessible, skipping AAP resource cleanup"
    return 0
  fi

  # Get organization ID
  local org_name="HashiVault Secrets Management"
  local org_id
  org_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/organizations/?name=${org_name// /%20}" 2>/dev/null | \
    jq -r '.results[0].id // empty')

  if [ -n "$org_id" ]; then
    echo "  Deleting organization: $org_name (ID: $org_id)..."
    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X DELETE \
      "${AAP_API}/organizations/${org_id}/" >/dev/null 2>&1 || true
    echo "✓ AAP resources removed"
  else
    echo "  Organization not found, skipping"
  fi
}

purge_vault_data() {
  echo "Purging Vault state data..."

  if [ -d "$VAULT_STATE_DIR" ]; then
    rm -rf "$VAULT_STATE_DIR"
    echo "✓ State directory removed: $VAULT_STATE_DIR"
  else
    echo "  No state directory found"
  fi
}

print_post_deploy_instructions() {
  local vault_route
  vault_route=$(kubectl get route vault -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "vault-${NAMESPACE}.apps-crc.testing")
  local aap_route
  aap_route=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)

  echo ""
  echo "══════════════════════════════════════════════════════════════════════════════"
  echo "✓ HashiVault addon enabled successfully"
  echo "══════════════════════════════════════════════════════════════════════════════"
  echo ""
  echo "Vault Web UI: https://${vault_route}"
  echo "Root Token: root"
  echo ""
  echo "AAP Web UI: https://${aap_route}"
  echo "Organization: HashiVault Secrets Management"
  echo ""
  echo "Authentication Methods Configured:"
  echo "  ✓ OIDC (Primary) - Uses AAP workload identity for dynamic JWT tokens"
  echo "  ✓ Token (Comparison) - Uses static root token for contrast"
  echo ""
  echo "Getting Started - OIDC Authentication Demo (Recommended):"
  echo ""
  echo "1. Test vault connectivity:"
  echo "   • AAP UI → Organizations → HashiVault Secrets Management → Templates"
  echo "   • Run: 'HashiVault (OIDC) | Test Connection'"
  echo "   • Verify vault is unsealed and healthy"
  echo ""
  echo "2. Read secrets using OIDC:"
  echo "   • Run: 'HashiVault (OIDC) | Read Secret'"
  echo "   • Notice: NO static token used - AAP generates short-lived JWT"
  echo "   • Observe secret values retrieved at runtime"
  echo ""
  echo "3. Update a secret:"
  echo "   • Run: 'HashiVault (OIDC) | Update Secret'"
  echo "   • Secret api_key updated with timestamp"
  echo ""
  echo "4. Verify runtime injection:"
  echo "   • Run: 'HashiVault (OIDC) | Verify Runtime Injection'"
  echo "   • Observe NEW secret value (proves runtime injection)"
  echo ""
  echo "Comparison - Token Authentication:"
  echo ""
  echo "  Run the equivalent 'HashiVault (Token) | ...' templates to see"
  echo "  the same workflow using static token authentication."
  echo ""
  echo "  Key Difference:"
  echo "  • OIDC: AAP automatically generates short-lived JWTs per job run"
  echo "  • Token: Uses static root token (less secure, but simpler)"
  echo ""
  echo "Demo Concepts Demonstrated:"
  echo "✓ OIDC workload identity (NEW in AAP 2.7!)"
  echo "✓ Short-lived credentials vs static tokens"
  echo "✓ Secrets stored in external Vault (not AAP database)"
  echo "✓ Credentials inject environment variables at job runtime"
  echo "✓ Playbooks read secrets dynamically during execution"
  echo "✓ Secret updates immediately available to next job run"
  echo "✓ No execution environment rebuild required"
  echo ""
  echo "Vault CLI Access:"
  echo "  kubectl exec -n ${NAMESPACE} vault-0 -- vault status"
  echo "  kubectl exec -n ${NAMESPACE} vault-0 -- vault kv get secret/demo"
  echo "  kubectl exec -n ${NAMESPACE} vault-0 -- vault read auth/jwt/config"
  echo "  kubectl exec -n ${NAMESPACE} vault-0 -- vault read auth/jwt/role/aap-demo-role"
  echo ""
  echo "Troubleshooting OIDC:"
  echo "  • Verify feature flag: kubectl get aap aap -n ${NAMESPACE} -o jsonpath='{.spec.feature_flags}'"
  echo "  • Check JWT auth backend: vault read auth/jwt/config"
  echo "  • Verify bound_audiences matches Vault URL exactly"
  echo "  • Review AAP job logs for JWT token issues"
  echo ""
  echo "══════════════════════════════════════════════════════════════════════════════"
}

# ── Main Execution ────────────────────────────────────────────────────────────

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Disabling HashiVault addon..."
  echo ""

  delete_aap_resources
  delete_vault_resources

  if [ "$PURGE_DATA" = "1" ]; then
    purge_vault_data
  fi

  echo ""
  echo "✓ HashiVault addon disabled successfully"
  exit 0
fi

# Deploy action
echo "Enabling HashiVault addon..."
echo ""

check_prerequisites
ensure_state_dir
deploy_vault_helm
wait_for_vault_ready
configure_vault_route

# Extract and save root token
ROOT_TOKEN=$(extract_root_token)
VAULT_URL="http://vault.${NAMESPACE}.svc.cluster.local:8200"
save_vault_config "$ROOT_TOKEN" "$VAULT_URL"

initialize_vault
create_test_secrets

if ! verify_secrets_created; then
  echo "❌ ERROR: Failed to verify test secrets"
  exit 1
fi

# Configure Vault for OIDC authentication
echo ""
echo "Configuring Vault for OIDC authentication..."
enable_aap_oidc_feature_flag
configure_vault_jwt_auth
create_vault_policy
create_vault_jwt_role

# AAP integration (Phase 4-5)
echo ""
echo "Creating AAP resources..."
init_aap_connection

org_id=$(create_hashivault_organization)
project_id=$(create_hashivault_project "$org_id")
inventory_id=$(create_localhost_inventory "$org_id")

echo ""
echo "Creating credential types and credentials..."
oidc_type_id=$(lookup_builtin_oidc_credential_type)
token_type_id=$(create_token_credential_type)

oidc_cred_id=$(create_oidc_credential "$org_id" "$oidc_type_id")
token_cred_id=$(create_token_credential "$org_id" "$token_type_id")

echo ""
create_job_templates "$project_id" "$inventory_id" "$org_id" "$oidc_cred_id" "$token_cred_id"

echo ""
echo "✓ HashiVault addon fully configured"
echo "  - Vault OIDC authentication: Enabled"
echo "  - AAP organization: Created"
echo "  - AAP project: Synced"
echo "  - Credential types: Built-in OIDC + Custom Token"
echo "  - Credentials: 2 (OIDC + Token)"
echo "  - Job templates: 8 (4 OIDC + 4 Token)"
echo ""

print_post_deploy_instructions

exit 0
