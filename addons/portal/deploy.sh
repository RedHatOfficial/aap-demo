#!/usr/bin/env bash
# Portal Helm addon — Ansible Automation Portal via OpenShift Helm chart
# Auto-detects cluster CPU (arm64 vs amd64) and selects the correct image set.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_NAMESPACE="${AAP_NAMESPACE:-${NAMESPACE:-aap-operator}}"
PORTAL_NAMESPACE="${PORTAL_NAMESPACE:-redhat-rhaap-portal}"
ACTION="${1:-deploy}"
PORTAL_DIR="${HOME}/.aap-demo/portal"

# Helm release name and chart
RELEASE_NAME="redhat-rhaap-portal"
CHART_REPO="openshift-helm-charts/redhat-rhaap-portal"

# Default plugin version (AAP 2.7 compatible)
DEFAULT_PLUGIN_VERSION="2.2"

# OAuth app name in AAP
OAUTH_APP_NAME="${OAUTH_APP_NAME:-ansible-automation-portal}"

# ARM profile: upstream community RHDH (multi-arch) + RHEL9 PostgreSQL
DEFAULT_RHDH_REGISTRY="${DEFAULT_RHDH_REGISTRY:-quay.io}"
DEFAULT_RHDH_REPOSITORY="${DEFAULT_RHDH_REPOSITORY:-rhdh-community/rhdh}"
DEFAULT_RHDH_TAG="${DEFAULT_RHDH_TAG:-1.10}"
DEFAULT_POSTGRES_REGISTRY="${DEFAULT_POSTGRES_REGISTRY:-registry.redhat.io}"
DEFAULT_POSTGRES_REPOSITORY="${DEFAULT_POSTGRES_REPOSITORY:-rhel9/postgresql-15}"
DEFAULT_POSTGRES_TAG="${DEFAULT_POSTGRES_TAG:-9.8-1782419742}"

IS_ARM_CLUSTER=false

# ---------------------------------------------------------------------------
# Delete/Cleanup Handler
# ---------------------------------------------------------------------------

cleanup_portal_namespace() {
  local ns="$1"

  if helm list -n "$ns" 2>/dev/null | grep -q "^$RELEASE_NAME"; then
    echo "Uninstalling Helm release: $RELEASE_NAME (namespace: $ns)"
    helm uninstall "$RELEASE_NAME" -n "$ns" || true
  fi

  kubectl delete secret "$RELEASE_NAME-dynamic-plugins-registry-auth" \
    -n "$ns" &>/dev/null || true
  kubectl delete secret secrets-rhaap-portal -n "$ns" &>/dev/null || true
}

cleanup() {
  echo "Disabling portal addon..."

  cleanup_portal_namespace "$PORTAL_NAMESPACE"

  # Remove legacy install from AAP namespace (pre-dedicated-namespace deployments)
  if [ "$AAP_NAMESPACE" != "$PORTAL_NAMESPACE" ]; then
    cleanup_portal_namespace "$AAP_NAMESPACE"
  fi

  # Delete OAuth app from AAP
  if [ -f "$PORTAL_DIR/oauth_app_id" ]; then
    local app_id
    app_id=$(cat "$PORTAL_DIR/oauth_app_id")
    local aap_route
    local admin_pass

    aap_route=$(kubectl get route aap -n "$AAP_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    admin_pass=$(kubectl get secret aap-admin-password -n "$AAP_NAMESPACE" \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

    if [ -n "$aap_route" ] && [ -n "$admin_pass" ] && [ -n "$app_id" ]; then
      echo "Deleting OAuth application (ID: $app_id) from AAP"
      curl -k -u "admin:$admin_pass" \
        -X DELETE "https://$aap_route/api/gateway/v1/applications/$app_id/" \
        -H "Content-Type: application/json" &>/dev/null || true
    fi
  fi

  kubectl delete namespace "$PORTAL_NAMESPACE" --timeout=120s 2>/dev/null || true

  # Cleanup portal directory
  rm -rf "$PORTAL_DIR"

  echo "Portal addon disabled"
  exit 0
}

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  cleanup
fi

# ---------------------------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------------------------

detect_arch() {
  local arch
  arch=$(uname -m)
  if [[ "$arch" == "arm64" ]] || [[ "$arch" == "aarch64" ]]; then
    echo "arm"
  else
    echo "x86"
  fi
}

detect_cluster_arch() {
  if [ -n "${PORTAL_ARCH:-}" ]; then
    case "$PORTAL_ARCH" in
      arm | arm64 | aarch64)
        echo "arm64"
        return
        ;;
      x86 | amd64 | x86_64)
        echo "amd64"
        return
        ;;
      *)
        echo "❌ Unknown PORTAL_ARCH: $PORTAL_ARCH (use arm or x86)"
        exit 1
        ;;
    esac
  fi

  kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true
}

resolve_portal_profile() {
  local cluster_arch
  cluster_arch=$(detect_cluster_arch)

  if [ -z "$cluster_arch" ]; then
    echo "⚠️  Could not detect cluster architecture; defaulting to x86 profile"
    IS_ARM_CLUSTER=false
    return
  fi

  echo "✓ Cluster architecture: $cluster_arch"

  if [[ "$cluster_arch" == "arm64" ]] || [[ "$cluster_arch" == "aarch64" ]]; then
    IS_ARM_CLUSTER=true
    echo "✓ Using ARM profile (upstream community RHDH images)"
  else
    IS_ARM_CLUSTER=false
    echo "✓ Using x86 profile (Red Hat RHDH images)"
  fi
}

check_architecture() {
  local local_arch
  local_arch=$(detect_arch)

  if [ "$IS_ARM_CLUSTER" = true ]; then
    if [ "$local_arch" = "arm" ]; then
      echo "✓ Local machine is ARM — matches cluster"
    else
      echo "ℹ️  Local machine is x86 — deploying to ARM cluster via KUBECONFIG"
    fi
    return 0
  fi

  if [ "$local_arch" = "arm" ]; then
    echo "ℹ️  Local machine is ARM (Apple Silicon) — cluster is x86_64"
    echo "   Deploy to an ARM cluster (e.g. CRC on Apple Silicon) with: aap-demo enable portal"
    echo ""
  fi

  return 0
}

check_prerequisites() {
  echo "Checking prerequisites..."

  # Check kubectl/oc connectivity
  if ! kubectl cluster-info &>/dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster"
    echo "Ensure oc/kubectl is configured and cluster is accessible"
    exit 1
  fi

  resolve_portal_profile
  check_architecture

  # Check AAP deployment
  if ! kubectl get route aap -n "$AAP_NAMESPACE" &>/dev/null; then
    echo "❌ AAP not deployed in namespace: $AAP_NAMESPACE"
    echo "Run 'aap-demo deploy' first"
    exit 1
  fi

  # Check Helm installed
  if ! command -v helm &>/dev/null; then
    echo "❌ Helm not found"
    echo "Install Helm 3.10+ from https://helm.sh/docs/intro/install/"
    exit 1
  fi

  # Check Helm version
  local helm_version
  helm_version=$(helm version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+' | sed 's/v//')
  local helm_major
  local helm_minor
  helm_major=$(echo "$helm_version" | cut -d. -f1)
  helm_minor=$(echo "$helm_version" | cut -d. -f2)

  if [ "$helm_major" -lt 3 ] || ([ "$helm_major" -eq 3 ] && [ "$helm_minor" -lt 10 ]); then
    echo "❌ Helm version 3.10+ required (found: v$helm_version)"
    exit 1
  fi

  # Check jq installed
  if ! command -v jq &>/dev/null; then
    echo "❌ jq not found"
    echo "Install jq for JSON parsing: brew install jq"
    exit 1
  fi

  echo "✓ Prerequisites met"
}

grant_portal_sccs() {
  if command -v oc &>/dev/null; then
    oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${PORTAL_NAMESPACE}" 2>/dev/null || true
    oc adm policy add-scc-to-group privileged "system:serviceaccounts:${PORTAL_NAMESPACE}" 2>/dev/null || true
    return
  fi

  for scc_name in anyuid privileged; do
    local crb_name="system:openshift:scc:${scc_name}:${PORTAL_NAMESPACE}"
    if ! kubectl get clusterrolebinding "$crb_name" &>/dev/null; then
      kubectl create clusterrolebinding "$crb_name" \
        --clusterrole="system:openshift:scc:${scc_name}" \
        --group="system:serviceaccounts:${PORTAL_NAMESPACE}" 2>/dev/null || true
    fi
  done
}

copy_pull_secret_to_portal_namespace() {
  if ! kubectl get secret redhat-operators-pull-secret -n "$AAP_NAMESPACE" &>/dev/null; then
    return 0
  fi

  mkdir -p "$PORTAL_DIR"
  chmod 700 "$PORTAL_DIR"
  kubectl get secret redhat-operators-pull-secret -n "$AAP_NAMESPACE" \
    -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d >"$PORTAL_DIR/pull-secret.json" || return 0
  chmod 600 "$PORTAL_DIR/pull-secret.json"

  kubectl delete secret redhat-operators-pull-secret -n "$PORTAL_NAMESPACE" 2>/dev/null || true
  kubectl create secret generic redhat-operators-pull-secret \
    --from-file=.dockerconfigjson="$PORTAL_DIR/pull-secret.json" \
    --type=kubernetes.io/dockerconfigjson \
    -n "$PORTAL_NAMESPACE" 2>/dev/null || true

  local existing_secrets
  existing_secrets=$(kubectl get serviceaccount default -n "$PORTAL_NAMESPACE" \
    -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
  if echo "$existing_secrets" | grep -q "redhat-operators-pull-secret"; then
    return 0
  fi

  local patch_json
  patch_json=$(echo "$existing_secrets redhat-operators-pull-secret" | xargs -n1 | sort -u \
    | jq -R -s 'split("\n") | map(select(length > 0)) | map({name: .}) | {imagePullSecrets: .}')
  kubectl patch serviceaccount default -n "$PORTAL_NAMESPACE" \
    -p "$patch_json" 2>/dev/null || true
}

setup_portal_namespace() {
  echo "Setting up portal namespace: $PORTAL_NAMESPACE"

  kubectl create namespace "$PORTAL_NAMESPACE" 2>/dev/null || true
  kubectl label namespace "$PORTAL_NAMESPACE" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged --overwrite 2>/dev/null || true

  grant_portal_sccs
  copy_pull_secret_to_portal_namespace

  echo "✓ Portal namespace ready"
}

cleanup_legacy_install() {
  if [ "$AAP_NAMESPACE" = "$PORTAL_NAMESPACE" ]; then
    return 0
  fi

  if helm list -n "$AAP_NAMESPACE" 2>/dev/null | grep -q "^$RELEASE_NAME"; then
    echo "Migrating portal from $AAP_NAMESPACE to $PORTAL_NAMESPACE..."
    cleanup_portal_namespace "$AAP_NAMESPACE"
  fi
}

get_aap_credentials() {
  echo "Fetching AAP credentials..."

  AAP_ROUTE=$(kubectl get route aap -n "$AAP_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
  if [ -z "$AAP_ROUTE" ]; then
    echo "❌ Failed to get AAP route"
    exit 1
  fi

  ADMIN_PASS=$(kubectl get secret aap-admin-password -n "$AAP_NAMESPACE" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  if [ -z "$ADMIN_PASS" ]; then
    echo "❌ Failed to get AAP admin password"
    exit 1
  fi

  # Test connectivity
  if ! curl -k -u "admin:$ADMIN_PASS" "https://$AAP_ROUTE/api/gateway/v1/ping/" \
    --max-time 10 &>/dev/null; then
    echo "❌ Cannot reach AAP at https://$AAP_ROUTE"
    exit 1
  fi

  echo "✓ AAP accessible at: $AAP_ROUTE"
}

select_organization() {
  echo "Selecting AAP organization..."

  # List organizations
  local orgs_json
  orgs_json=$(curl -k -u "admin:$ADMIN_PASS" \
    "https://$AAP_ROUTE/api/gateway/v1/organizations/" \
    -H "Content-Type: application/json" 2>/dev/null)

  local org_count
  org_count=$(echo "$orgs_json" | jq -r '.count' 2>/dev/null || echo "0")

  if [ "$org_count" -eq 0 ]; then
    echo "Creating default organization..."
    local create_response
    create_response=$(curl -k -u "admin:$ADMIN_PASS" \
      -X POST "https://$AAP_ROUTE/api/gateway/v1/organizations/" \
      -H "Content-Type: application/json" \
      -d '{"name": "Default", "description": "Default organization for portal"}' \
      2>/dev/null)

    ORG_ID=$(echo "$create_response" | jq -r '.id')
    ORG_NAME="Default"
  else
    # Use first organization
    ORG_ID=$(echo "$orgs_json" | jq -r '.results[0].id')
    ORG_NAME=$(echo "$orgs_json" | jq -r '.results[0].name')
  fi

  if [ -z "$ORG_ID" ] || [ "$ORG_ID" = "null" ]; then
    echo "❌ Failed to get/create organization"
    exit 1
  fi

  echo "✓ Using organization: $ORG_NAME (ID: $ORG_ID)"
}

create_oauth_app() {
  echo "Creating OAuth application in AAP..."

  mkdir -p "$PORTAL_DIR"
  chmod 700 "$PORTAL_DIR"
  local oauth_credentials_file="$PORTAL_DIR/oauth_credentials.json"

  # Check if app already exists
  local encoded_app_name
  encoded_app_name=$(jq -rn --arg n "$OAUTH_APP_NAME" '$n|@uri')
  local existing_app
  existing_app=$(curl -k -u "admin:$ADMIN_PASS" \
    "https://$AAP_ROUTE/api/gateway/v1/applications/?name=${encoded_app_name}" \
    -H "Content-Type: application/json" 2>/dev/null)

  local existing_count
  existing_count=$(echo "$existing_app" | jq -r '.count' 2>/dev/null || echo "0")

  if [ "$existing_count" -gt 0 ]; then
    OAUTH_APP_ID=$(echo "$existing_app" | jq -r '.results[0].id')
    CLIENT_ID=$(echo "$existing_app" | jq -r '.results[0].client_id')
    CLIENT_SECRET=""

    # AAP only returns client_secret at creation time — never trust GET responses
    if [ -f "$oauth_credentials_file" ]; then
      local saved_id saved_secret
      saved_id=$(jq -r '.oauth_app_id // empty' "$oauth_credentials_file")
      saved_secret=$(jq -r '.client_secret // empty' "$oauth_credentials_file")
      if [ "$saved_id" = "$OAUTH_APP_ID" ] && [ -n "$saved_secret" ]; then
        CLIENT_SECRET="$saved_secret"
        echo "Using saved OAuth client secret for existing app..."
      fi
    fi

    # No saved secret — delete and recreate the OAuth app
    if [ -z "$CLIENT_SECRET" ]; then
      echo "OAuth app exists but client secret unavailable — recreating..."
      curl -k -u "admin:$ADMIN_PASS" \
        -X DELETE "https://$AAP_ROUTE/api/gateway/v1/applications/$OAUTH_APP_ID/" \
        -H "Content-Type: application/json" &>/dev/null || true
      existing_count=0
    else
      echo "OAuth app already exists, using existing..."
    fi
  fi

  if [ "$existing_count" -eq 0 ]; then
    # Create new OAuth app with placeholder redirect URI
    local oauth_response
    oauth_response=$(curl -k -u "admin:$ADMIN_PASS" \
      -X POST "https://$AAP_ROUTE/api/gateway/v1/applications/" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"${OAUTH_APP_NAME}\",
        \"organization\": $ORG_ID,
        \"authorization_grant_type\": \"authorization-code\",
        \"client_type\": \"confidential\",
        \"redirect_uris\": \"https://example.com\"
      }" 2>/dev/null)

    OAUTH_APP_ID=$(echo "$oauth_response" | jq -r '.id')
    CLIENT_ID=$(echo "$oauth_response" | jq -r '.client_id')
    CLIENT_SECRET=$(echo "$oauth_response" | jq -r '.client_secret')
  fi

  if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" = "null" ]; then
    echo "❌ Failed to create OAuth application"
    exit 1
  fi

  if [ -z "$CLIENT_SECRET" ] || [ "$CLIENT_SECRET" = "null" ]; then
    echo "❌ Failed to obtain OAuth client secret"
    exit 1
  fi

  # Persist credentials — AAP will not return client_secret on subsequent reads
  jq -n \
    --arg oauth_app_id "$OAUTH_APP_ID" \
    --arg client_id "$CLIENT_ID" \
    --arg client_secret "$CLIENT_SECRET" \
    '{oauth_app_id: $oauth_app_id, client_id: $client_id, client_secret: $client_secret}' \
    >"$oauth_credentials_file"
  chmod 600 "$oauth_credentials_file"

  echo "$OAUTH_APP_ID" >"$PORTAL_DIR/oauth_app_id"
  chmod 600 "$PORTAL_DIR/oauth_app_id"

  echo "✓ OAuth app ready (ID: $OAUTH_APP_ID)"
}

enable_oauth_tokens() {
  echo "Enabling OAuth token creation for external users..."

  # Check current setting
  local settings
  settings=$(curl -k -u "admin:$ADMIN_PASS" \
    "https://$AAP_ROUTE/api/gateway/v1/settings/" \
    -H "Content-Type: application/json" 2>/dev/null)

  local current_value
  current_value=$(echo "$settings" | jq -r '.ALLOW_OAUTH2_FOR_EXTERNAL_USERS' 2>/dev/null || echo "false")

  if [ "$current_value" = "true" ]; then
    echo "✓ OAuth tokens already enabled"
    return
  fi

  # Enable setting
  curl -k -u "admin:$ADMIN_PASS" \
    -X PATCH "https://$AAP_ROUTE/api/gateway/v1/settings/" \
    -H "Content-Type: application/json" \
    -d '{"ALLOW_OAUTH2_FOR_EXTERNAL_USERS": true}' \
    &>/dev/null

  echo "✓ OAuth tokens enabled"
}

create_api_token() {
  echo "Generating AAP API token..."

  local token_response
  token_response=$(curl -k -u "admin:$ADMIN_PASS" \
    -X POST "https://$AAP_ROUTE/api/gateway/v1/tokens/" \
    -H "Content-Type: application/json" \
    -d "{
      \"description\": \"Portal backend catalog access\",
      \"scope\": \"read\",
      \"application\": $OAUTH_APP_ID
    }" 2>/dev/null)

  API_TOKEN=$(echo "$token_response" | jq -r '.token')

  if [ -z "$API_TOKEN" ] || [ "$API_TOKEN" = "null" ]; then
    echo "❌ Failed to generate API token"
    exit 1
  fi

  echo "✓ API token generated"
}

get_registry_credentials() {
  echo "Configuring registry credentials..."

  mkdir -p "$PORTAL_DIR"
  chmod 700 "$PORTAL_DIR"

  # Try to extract from existing pull secret
  if kubectl get secret pull-secret -n openshift-config &>/dev/null; then
    kubectl get secret pull-secret -n openshift-config \
      -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d >"$PORTAL_DIR/auth.json" || true

    # Check if registry.redhat.io credentials exist
    if jq -e '.auths."registry.redhat.io"' "$PORTAL_DIR/auth.json" &>/dev/null; then
      chmod 600 "$PORTAL_DIR/auth.json"
      echo "✓ Using existing registry.redhat.io credentials from cluster"
      return 0
    fi
  fi

  # Check for redhat-operators-pull-secret (created by aap-demo)
  if kubectl get secret redhat-operators-pull-secret -n "$AAP_NAMESPACE" &>/dev/null; then
    kubectl get secret redhat-operators-pull-secret -n "$AAP_NAMESPACE" \
      -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d >"$PORTAL_DIR/auth.json" || true

    if jq -e '.auths."registry.redhat.io"' "$PORTAL_DIR/auth.json" &>/dev/null; then
      chmod 600 "$PORTAL_DIR/auth.json"
      echo "✓ Using existing registry.redhat.io credentials from namespace"
      return 0
    fi
  fi

  # Check environment variables
  if [ -n "${REGISTRY_USERNAME:-}" ] && [ -n "${REGISTRY_PASSWORD:-}" ]; then
    local auth_string
    auth_string=$(echo -n "$REGISTRY_USERNAME:$REGISTRY_PASSWORD" | base64)
    cat >"$PORTAL_DIR/auth.json" <<ENVEOF
{
  "auths": {
    "registry.redhat.io": {
      "auth": "$auth_string"
    }
  }
}
ENVEOF
    chmod 600 "$PORTAL_DIR/auth.json"
    echo "✓ Using registry credentials from environment"
    return 0
  fi

  # Prompt user
  echo ""
  echo "Registry credentials not found. Please provide registry.redhat.io credentials:"
  read -r -p "Username: " registry_username
  read -r -s -p "Password/Token: " registry_password
  echo ""

  if [ -z "$registry_username" ] || [ -z "$registry_password" ]; then
    echo "❌ Registry credentials required"
    exit 1
  fi

  # Create auth.json
  local auth_string
  auth_string=$(echo -n "$registry_username:$registry_password" | base64)

  cat >"$PORTAL_DIR/auth.json" <<EOF
{
  "auths": {
    "registry.redhat.io": {
      "auth": "$auth_string"
    }
  }
}
EOF
  chmod 600 "$PORTAL_DIR/auth.json"

  echo "✓ Registry credentials configured"
}

create_registry_secret() {
  echo "Creating registry secret in OpenShift..."

  # Delete existing secret if present
  kubectl delete secret "$RELEASE_NAME-dynamic-plugins-registry-auth" \
    -n "$PORTAL_NAMESPACE" &>/dev/null || true

  # Create secret from auth.json
  kubectl create secret generic "$RELEASE_NAME-dynamic-plugins-registry-auth" \
    --from-file=auth.json="$PORTAL_DIR/auth.json" \
    -n "$PORTAL_NAMESPACE"

  echo "✓ Registry secret created"
}

get_cluster_info() {
  echo "Getting cluster information..."

  # Get cluster base URL from ingresses.config (OCP) or derive from AAP route (MicroShift)
  CLUSTER_BASE_URL=$(kubectl get ingresses.config/cluster -o jsonpath='{.spec.domain}' --request-timeout=5s 2>/dev/null || true)

  if [ -z "$CLUSTER_BASE_URL" ]; then
    # MicroShift doesn't have ingresses.config, derive from AAP route
    IS_MICROSHIFT=true
    CLUSTER_BASE_URL=$(echo "$AAP_ROUTE" | sed "s/^aap-${AAP_NAMESPACE}\.//")
  else
    IS_MICROSHIFT=false
  fi

  if [ -z "$CLUSTER_BASE_URL" ]; then
    echo "❌ Failed to get cluster base URL"
    exit 1
  fi

  echo "✓ Cluster base URL: $CLUSTER_BASE_URL"
}

get_aap_host_url() {
  # On MicroShift/CRC, portal backend OAuth token exchange must use http://<route>
  # (not https://) because in-cluster traffic hits the Service on port 80.
  # nip.io hostnames resolve to 127.0.0.1 inside pods, so patch_aap_route_host_alias()
  # maps the route hostname to the AAP Service ClusterIP. Browsers still reach AAP
  # over HTTPS via ingress.
  if [ "${IS_MICROSHIFT:-false}" = true ]; then
    echo "http://${AAP_ROUTE}"
  else
    echo "https://${AAP_ROUTE}"
  fi
}

patch_aap_route_host_alias() {
  if [ "${IS_MICROSHIFT:-false}" != true ]; then
    return 0
  fi

  echo "Configuring AAP route host alias for in-pod OAuth token exchange..."

  local aap_ip
  aap_ip=$(kubectl get svc aap -n "$AAP_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

  if [ -z "$aap_ip" ]; then
    echo "⚠️  Could not resolve AAP service ClusterIP; skipping host alias"
    return 1
  fi

  local current_ip
  current_ip=$(kubectl get deployment "$RELEASE_NAME" -n "$PORTAL_NAMESPACE" \
    -o jsonpath="{.spec.template.spec.hostAliases[?(@.hostnames[0]=='${AAP_ROUTE}')].ip}" 2>/dev/null)

  if [ "$current_ip" = "$aap_ip" ]; then
    echo "✓ AAP route host alias already configured ($AAP_ROUTE → $aap_ip)"
    return 0
  fi

  kubectl patch deployment "$RELEASE_NAME" -n "$PORTAL_NAMESPACE" --type=merge -p "{
    \"spec\": {
      \"template\": {
        \"spec\": {
          \"hostAliases\": [
            {\"ip\": \"$aap_ip\", \"hostnames\": [\"$AAP_ROUTE\"]}
          ]
        }
      }
    }
  }"

  if ! kubectl rollout status deployment/"$RELEASE_NAME" \
    -n "$PORTAL_NAMESPACE" \
    --timeout=600s 2>/dev/null; then
    echo "⚠️  Portal rollout after host alias patch is still in progress"
  fi

  echo "✓ AAP route host alias: $AAP_ROUTE → $aap_ip"
}

create_aap_secrets() {
  echo "Creating AAP credentials secret..."

  AAP_HOST_URL=$(get_aap_host_url)

  # Delete existing secret if present
  kubectl delete secret secrets-rhaap-portal -n "$PORTAL_NAMESPACE" &>/dev/null || true

  kubectl create secret generic secrets-rhaap-portal \
    -n "$PORTAL_NAMESPACE" \
    --from-literal=aap-host-url="$AAP_HOST_URL" \
    --from-literal=oauth-client-id="$CLIENT_ID" \
    --from-literal=oauth-client-secret="$CLIENT_SECRET" \
    --from-literal=aap-token="$API_TOKEN"

  echo "✓ AAP credentials secret created"
  echo "✓ AAP host URL: $AAP_HOST_URL"
}

create_helm_values() {
  echo "Creating Helm values file..."

  local ssl_values=""
  if [ "${IS_MICROSHIFT:-false}" = true ]; then
    if [ "${IS_ARM_CLUSTER}" = true ]; then
      ssl_values="
        ansible:
          rhaap:
            checkSSL: false
        auth:
          providers:
            rhaap:
              'production':
                checkSSL: false"
    else
      ssl_values="
      ansible:
        rhaap:
          checkSSL: false
      auth:
        providers:
          rhaap:
            'production':
              checkSSL: false"
    fi
  fi

  if [ "${IS_ARM_CLUSTER}" = true ]; then
    cat >"$PORTAL_DIR/values.yaml" <<EOF
redhat-developer-hub:
  global:
    clusterRouterBase: $CLUSTER_BASE_URL
    pluginMode: oci
    imageTagInfo: "$DEFAULT_PLUGIN_VERSION"
  upstream:
    backstage:
      image:
        registry: ${DEFAULT_RHDH_REGISTRY}
        repository: ${DEFAULT_RHDH_REPOSITORY}
        tag: "${DEFAULT_RHDH_TAG}"
      appConfig:${ssl_values}
        dynamicPlugins:
          frontend:
            default.main-menu-items:
              menuItems:
                default.home:
                  title: Home
    postgresql:
      image:
        registry: ${DEFAULT_POSTGRES_REGISTRY}
        repository: ${DEFAULT_POSTGRES_REPOSITORY}
        tag: "${DEFAULT_POSTGRES_TAG}"
EOF
    echo "✓ Helm values created (ARM profile)"
    echo "  RHDH hub: ${DEFAULT_RHDH_REGISTRY}/${DEFAULT_RHDH_REPOSITORY}:${DEFAULT_RHDH_TAG}"
    echo "  PostgreSQL: ${DEFAULT_POSTGRES_REGISTRY}/${DEFAULT_POSTGRES_REPOSITORY}:${DEFAULT_POSTGRES_TAG}"
    return
  fi

  cat >"$PORTAL_DIR/values.yaml" <<EOF
global:
  clusterRouterBase: $CLUSTER_BASE_URL
  pluginMode: oci
  imageTagInfo: "$DEFAULT_PLUGIN_VERSION"

upstream:
  backstage:
    appConfig:${ssl_values}
    dynamicPlugins:
      frontend:
        default.main-menu-items:
          menuItems:
            default.home:
              title: Home
            default.catalog:
              title: Catalog
            default.create:
              title: Create
            default.apis:
              title: APIs
            default.learning-path:
              title: Learning Paths
            default.my-group:
              title: My Group
EOF

  echo "✓ Helm values created (x86 profile)"
}

install_helm_chart() {
  echo "Installing Helm chart..."

  HELM_WAS_UPGRADE=false

  # Add Helm repo if not present
  if ! helm repo list 2>/dev/null | grep -q openshift-helm-charts; then
    echo "Adding OpenShift Helm Charts repository..."
    helm repo add openshift-helm-charts https://charts.openshift.io/
  fi

  helm repo update &>/dev/null

  if [ "${IS_ARM_CLUSTER}" = true ]; then
    # kubectl patches to dynamic-plugins conflict with helm server-side apply
    kubectl delete configmap "${RELEASE_NAME}-dynamic-plugins" \
      -n "$PORTAL_NAMESPACE" --ignore-not-found 2>/dev/null || true
  fi

  # Install or upgrade
  if helm list -n "$PORTAL_NAMESPACE" 2>/dev/null | grep -q "^$RELEASE_NAME"; then
    echo "Upgrading existing Helm release..."
    HELM_WAS_UPGRADE=true
    helm upgrade "$RELEASE_NAME" "$CHART_REPO" \
      -n "$PORTAL_NAMESPACE" \
      -f "$PORTAL_DIR/values.yaml" \
      --hide-notes
  else
    echo "Installing Helm release..."
    helm install "$RELEASE_NAME" "$CHART_REPO" \
      -n "$PORTAL_NAMESPACE" \
      -f "$PORTAL_DIR/values.yaml" \
      --hide-notes
  fi

  echo "✓ Helm chart installed"
}

# Community RHDH on ARM ships a broken quay scaffolder plugin dist — disable after Helm render.
patch_disable_quay_plugin() {
  echo "Patching dynamic-plugins configmap..."

  local cm="${RELEASE_NAME}-dynamic-plugins"
  local plugins_yaml

  plugins_yaml=$(kubectl get cm "$cm" -n "$PORTAL_NAMESPACE" \
    -o jsonpath='{.data.dynamic-plugins\.yaml}' 2>/dev/null || true)

  if [ -z "$plugins_yaml" ]; then
    echo "❌ dynamic-plugins configmap not found or empty"
    return 1
  fi

  if ! echo "$plugins_yaml" | grep -q 'ansible-automation-platform'; then
    echo "❌ AAP OCI plugins missing from dynamic-plugins configmap"
    return 1
  fi

  if echo "$plugins_yaml" | grep -B1 'scaffolder-backend-module-quay-dynamic' | grep -q '^- disabled: true'; then
    echo "✓ Quay plugin override already present"
    return 0
  fi

  plugins_yaml=$(echo "$plugins_yaml" | grep -v 'scaffolder-backend-module-quay-dynamic' | sed '/^    - disabled: true$/d')

  plugins_yaml="${plugins_yaml}"$'\n'"- disabled: true"$'\n'"  package: ./dynamic-plugins/dist/backstage-community-plugin-scaffolder-backend-module-quay-dynamic"

  kubectl create configmap "$cm" \
    --from-literal=dynamic-plugins.yaml="$plugins_yaml" \
    -n "$PORTAL_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "✓ Disabled broken quay scaffolder plugin (preserving AAP OCI plugins)"
}

reset_dynamic_plugins_pvc() {
  echo "Resetting dynamic-plugins PVC for clean plugin install..."

  kubectl get pvc -n "$PORTAL_NAMESPACE" -o name 2>/dev/null | grep dynamic-plugins \
    | while read -r pvc; do
      kubectl delete "$pvc" -n "$PORTAL_NAMESPACE" --timeout=120s 2>/dev/null || true
    done
}

restart_portal_deployment() {
  echo "Restarting portal to apply credential updates..."

  if ! kubectl rollout restart deployment/"$RELEASE_NAME" -n "$PORTAL_NAMESPACE" &>/dev/null; then
    echo "⚠️  Failed to restart portal deployment"
    return 1
  fi

  echo "✓ Portal deployment restarted"
}

wait_for_deployment() {
  echo "Waiting for portal deployment to be ready..."

  if ! kubectl rollout status deployment/"$RELEASE_NAME" \
    -n "$PORTAL_NAMESPACE" \
    --timeout=600s 2>/dev/null; then

    echo "⚠️  Deployment taking longer than expected"
    echo "Check status with: kubectl get pods -n $PORTAL_NAMESPACE"
    echo "Proceeding anyway..."
  else
    echo "✓ Deployment ready"
  fi
}

update_oauth_redirect() {
  echo "Updating OAuth redirect URI..."

  # Get portal route
  PORTAL_ROUTE=$(kubectl get route "$RELEASE_NAME" -n "$PORTAL_NAMESPACE" \
    -o jsonpath='{.spec.host}' 2>/dev/null)

  if [ -z "$PORTAL_ROUTE" ]; then
    echo "⚠️  Failed to get portal route"
    echo "OAuth redirect URI not updated - may need manual fix"
    return 1
  fi

  # Update OAuth app with real redirect URI (rhaap provider uses /api/auth/rhaap/handler/frame)
  local redirect_uri="https://$PORTAL_ROUTE/api/auth/rhaap/handler/frame"

  curl -k -u "admin:$ADMIN_PASS" \
    -X PATCH "https://$AAP_ROUTE/api/gateway/v1/applications/$OAUTH_APP_ID/" \
    -H "Content-Type: application/json" \
    -d "{\"redirect_uris\": \"$redirect_uri\"}" \
    &>/dev/null

  echo "✓ OAuth redirect URI updated: $redirect_uri"
}

verify_aap_host_url() {
  echo "Verifying AAP host URL in portal pod..."

  local aap_host_url
  aap_host_url=$(kubectl exec deployment/"$RELEASE_NAME" \
    -c backstage-backend \
    -n "$PORTAL_NAMESPACE" \
    -- printenv AAP_HOST_URL 2>/dev/null || true)

  if [ -z "$aap_host_url" ]; then
    echo "⚠️  Could not read AAP_HOST_URL from portal pod"
    return 1
  fi

  if [[ "$aap_host_url" == *".svc"* ]]; then
    echo "❌ Portal is configured with in-cluster AAP URL: $aap_host_url"
    echo "   Browser OAuth redirects require the external AAP route hostname."
    echo "   Re-run: aap-demo enable portal"
    return 1
  fi

  if [ "${IS_MICROSHIFT:-false}" = true ] && [[ "$aap_host_url" == https://* ]]; then
    echo "❌ Portal AAP URL uses HTTPS on MicroShift: $aap_host_url"
    echo "   In-cluster OAuth token exchange requires http://<aap-route> on CRC/MicroShift."
    echo "   Re-run: aap-demo enable portal"
    return 1
  fi

  echo "✓ AAP host URL: $aap_host_url"
}

verify_oauth_client() {
  echo "Verifying OAuth client credentials..."

  local http_code
  http_code=$(kubectl exec deployment/"$RELEASE_NAME" \
    -c backstage-backend \
    -n "$PORTAL_NAMESPACE" \
    -- sh -c '
      AUTH=$(printf "%s:%s" "$OAUTH_CLIENT_ID" "$OAUTH_CLIENT_SECRET" | base64 -w0)
      curl -s -o /dev/null -w "%{http_code}" -X POST "'"${AAP_HOST_URL}"'/o/token/" \
        -H "Authorization: Basic $AUTH" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=authorization_code&code=invalid&redirect_uri=https://'"${PORTAL_ROUTE}"'/api/auth/rhaap/handler/frame"
    ' 2>/dev/null || echo "000")

  if [ "$http_code" = "000" ]; then
    echo "❌ Portal pod cannot reach AAP token endpoint at ${AAP_HOST_URL}/o/token/"
    echo "   On CRC/MicroShift, nip.io resolves to 127.0.0.1 inside pods."
    echo "   Re-run: aap-demo enable portal"
    return 1
  fi

  # 400 = client auth OK, invalid grant (expected); 401 = invalid_client
  if [ "$http_code" = "401" ]; then
    echo "❌ OAuth client credentials rejected by AAP (invalid_client)"
    echo "   Re-run: aap-demo enable portal"
    return 1
  fi

  echo "✓ OAuth client credentials accepted by AAP (HTTP $http_code)"
}

display_success() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✓ Portal addon enabled successfully!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Portal URL: https://$PORTAL_ROUTE"
  if [ "${IS_ARM_CLUSTER}" = true ]; then
    echo "Profile: ARM (${DEFAULT_RHDH_REGISTRY}/${DEFAULT_RHDH_REPOSITORY}:${DEFAULT_RHDH_TAG})"
  else
    echo "Profile: x86 (Red Hat RHDH hub image from chart)"
  fi
  echo ""
  echo "Next steps:"
  echo "1. Open the portal URL in your browser"
  echo "2. Click 'Sign In'"
  echo "3. Authenticate with AAP credentials (admin / <aap-admin-password>)"
  echo "4. Browse AAP job templates in the catalog"
  echo ""
  echo "Check status: aap-demo status portal"
  echo "Disable: aap-demo disable portal"
  echo ""
}

# ---------------------------------------------------------------------------
# Main Execution
# ---------------------------------------------------------------------------

main() {
  check_prerequisites
  cleanup_legacy_install
  setup_portal_namespace
  get_aap_credentials
  select_organization
  create_oauth_app
  enable_oauth_tokens
  create_api_token
  get_registry_credentials
  create_registry_secret
  get_cluster_info
  create_aap_secrets
  create_helm_values
  install_helm_chart
  if [ "${IS_ARM_CLUSTER}" = true ]; then
    patch_disable_quay_plugin
    reset_dynamic_plugins_pvc
    restart_portal_deployment
  elif [ "${HELM_WAS_UPGRADE:-false}" = true ]; then
    restart_portal_deployment
  fi
  wait_for_deployment
  patch_aap_route_host_alias
  update_oauth_redirect
  verify_aap_host_url || echo "⚠️  AAP host URL verification failed (portal may still work)"
  verify_oauth_client || echo "⚠️  OAuth client verification failed (portal may still work)"
  display_success
}

main
