#!/usr/bin/env bash
# Portal Helm addon deployment script
# Installs Ansible Automation Portal via OpenShift Helm chart

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"
PORTAL_DIR="${HOME}/.aap-demo/portal"

# Helm release name and chart
RELEASE_NAME="redhat-rhaap-portal"
CHART_REPO="openshift-helm-charts/redhat-rhaap-portal"

# Default plugin version (AAP 2.7 compatible)
DEFAULT_PLUGIN_VERSION="2.1"

# ---------------------------------------------------------------------------
# Delete/Cleanup Handler
# ---------------------------------------------------------------------------

cleanup() {
  echo "Disabling portal addon..."

  # Delete Helm release
  if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "^$RELEASE_NAME"; then
    echo "Uninstalling Helm release: $RELEASE_NAME"
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" || true
  fi

  # Delete OAuth app from AAP
  if [ -f "$PORTAL_DIR/oauth_app_id" ]; then
    local app_id
    app_id=$(cat "$PORTAL_DIR/oauth_app_id")
    local aap_route
    local admin_pass

    aap_route=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    admin_pass=$(kubectl get secret aap-admin-password -n "$NAMESPACE" \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

    if [ -n "$aap_route" ] && [ -n "$admin_pass" ] && [ -n "$app_id" ]; then
      echo "Deleting OAuth application (ID: $app_id) from AAP"
      curl -k -u "admin:$admin_pass" \
        -X DELETE "https://$aap_route/api/gateway/v1/applications/$app_id/" \
        -H "Content-Type: application/json" &>/dev/null || true
    fi
  fi

  # Delete registry secret
  kubectl delete secret "$RELEASE_NAME-dynamic-plugins-registry-auth" \
    -n "$NAMESPACE" &>/dev/null || true

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

check_architecture() {
  if [[ "$(detect_arch)" == "arm" ]]; then
    echo "⚠️  Portal requires x86_64 architecture"
    echo "Your local machine is ARM (Apple Silicon)"
    echo ""
    echo "Options:"
    echo "1. Use portal-vm addon instead (works on ARM Mac via emulation)"
    echo "   $ aap-demo enable portal-vm"
    echo ""
    echo "2. Deploy to x86_64 OpenShift cluster (not MicroShift on this Mac)"
    echo "   Configure KUBECONFIG to point to remote x86 cluster"
    echo ""
    return 1
  fi
  return 0
}

check_prerequisites() {
  echo "Checking prerequisites..."

  # Architecture check (warning only, cluster may be x86)
  if ! check_architecture; then
    echo ""
    echo "⚠️  Proceeding anyway - cluster architecture may differ from local"
    echo ""
  fi

  # Check kubectl/oc connectivity
  if ! kubectl cluster-info &>/dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster"
    echo "Ensure oc/kubectl is configured and cluster is accessible"
    exit 1
  fi

  # Check AAP deployment
  if ! kubectl get route aap -n "$NAMESPACE" &>/dev/null; then
    echo "❌ AAP not deployed in namespace: $NAMESPACE"
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

get_aap_credentials() {
  echo "Fetching AAP credentials..."

  AAP_ROUTE=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
  if [ -z "$AAP_ROUTE" ]; then
    echo "❌ Failed to get AAP route"
    exit 1
  fi

  ADMIN_PASS=$(kubectl get secret aap-admin-password -n "$NAMESPACE" \
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

  # Check if app already exists
  local existing_app
  existing_app=$(curl -k -u "admin:$ADMIN_PASS" \
    "https://$AAP_ROUTE/api/gateway/v1/applications/?name=ansible-automation-portal" \
    -H "Content-Type: application/json" 2>/dev/null)

  local existing_count
  existing_count=$(echo "$existing_app" | jq -r '.count' 2>/dev/null || echo "0")

  if [ "$existing_count" -gt 0 ]; then
    echo "OAuth app already exists, using existing..."
    OAUTH_APP_ID=$(echo "$existing_app" | jq -r '.results[0].id')
    CLIENT_ID=$(echo "$existing_app" | jq -r '.results[0].client_id')
    CLIENT_SECRET=$(echo "$existing_app" | jq -r '.results[0].client_secret')
  else
    # Create new OAuth app with placeholder redirect URI
    local oauth_response
    oauth_response=$(curl -k -u "admin:$ADMIN_PASS" \
      -X POST "https://$AAP_ROUTE/api/gateway/v1/applications/" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"ansible-automation-portal\",
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

  # Save app ID for cleanup
  mkdir -p "$PORTAL_DIR"
  echo "$OAUTH_APP_ID" > "$PORTAL_DIR/oauth_app_id"

  echo "✓ OAuth app created (ID: $OAUTH_APP_ID)"
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
      \"scope\": \"write\",
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

  # Try to extract from existing pull secret
  if kubectl get secret pull-secret -n openshift-config &>/dev/null; then
    kubectl get secret pull-secret -n openshift-config \
      -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d > "$PORTAL_DIR/auth.json" || true

    # Check if registry.redhat.io credentials exist
    if jq -e '.auths."registry.redhat.io"' "$PORTAL_DIR/auth.json" &>/dev/null; then
      echo "✓ Using existing registry.redhat.io credentials from cluster"
      return 0
    fi
  fi

  # Check for redhat-operators-pull-secret (created by aap-demo)
  if kubectl get secret redhat-operators-pull-secret -n "$NAMESPACE" &>/dev/null; then
    kubectl get secret redhat-operators-pull-secret -n "$NAMESPACE" \
      -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d > "$PORTAL_DIR/auth.json" || true

    if jq -e '.auths."registry.redhat.io"' "$PORTAL_DIR/auth.json" &>/dev/null; then
      echo "✓ Using existing registry.redhat.io credentials from namespace"
      return 0
    fi
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

  cat > "$PORTAL_DIR/auth.json" <<EOF
{
  "auths": {
    "registry.redhat.io": {
      "auth": "$auth_string"
    }
  }
}
EOF

  echo "✓ Registry credentials configured"
}

create_registry_secret() {
  echo "Creating registry secret in OpenShift..."

  # Delete existing secret if present
  kubectl delete secret "$RELEASE_NAME-dynamic-plugins-registry-auth" \
    -n "$NAMESPACE" &>/dev/null || true

  # Create secret from auth.json
  kubectl create secret generic "$RELEASE_NAME-dynamic-plugins-registry-auth" \
    --from-file=auth.json="$PORTAL_DIR/auth.json" \
    -n "$NAMESPACE"

  echo "✓ Registry secret created"
}

get_cluster_info() {
  echo "Getting cluster information..."

  # Get cluster base URL from ingresses.config (OCP) or derive from AAP route (MicroShift)
  CLUSTER_BASE_URL=$(kubectl get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)

  if [ -z "$CLUSTER_BASE_URL" ]; then
    # MicroShift doesn't have ingresses.config, derive from AAP route
    CLUSTER_BASE_URL=$(echo "$AAP_ROUTE" | sed 's/^aap-aap-operator\.//')
  fi

  if [ -z "$CLUSTER_BASE_URL" ]; then
    echo "❌ Failed to get cluster base URL"
    exit 1
  fi

  echo "✓ Cluster base URL: $CLUSTER_BASE_URL"
}

create_helm_values() {
  echo "Creating Helm values file..."

  cat > "$PORTAL_DIR/values.yaml" <<EOF
global:
  clusterRouterBase: $CLUSTER_BASE_URL
  pluginMode: oci
  imageTagInfo: "$DEFAULT_PLUGIN_VERSION"

upstream:
  backstage:
    appConfig:
      catalog:
        providers:
          rhaap:
            orgs: "$ORG_NAME"
EOF

  echo "✓ Helm values created"
}

install_helm_chart() {
  echo "Installing Helm chart..."

  # Add Helm repo if not present
  if ! helm repo list 2>/dev/null | grep -q openshift-helm-charts; then
    echo "Adding OpenShift Helm Charts repository..."
    helm repo add openshift-helm-charts https://charts.openshift.io/
  fi

  helm repo update &>/dev/null

  # Install or upgrade
  if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "^$RELEASE_NAME"; then
    echo "Upgrading existing Helm release..."
    helm upgrade "$RELEASE_NAME" "$CHART_REPO" \
      -n "$NAMESPACE" \
      -f "$PORTAL_DIR/values.yaml"
  else
    echo "Installing Helm release..."
    helm install "$RELEASE_NAME" "$CHART_REPO" \
      -n "$NAMESPACE" \
      -f "$PORTAL_DIR/values.yaml"
  fi

  echo "✓ Helm chart installed"
}

wait_for_deployment() {
  echo "Waiting for portal deployment to be ready..."

  # Wait for deployment with timeout
  if ! kubectl wait --for=condition=available \
    deployment/"$RELEASE_NAME-backstage" \
    -n "$NAMESPACE" \
    --timeout=600s 2>/dev/null; then

    echo "⚠️  Deployment taking longer than expected"
    echo "Check status with: kubectl get pods -n $NAMESPACE"
    echo "Proceeding anyway..."
  else
    echo "✓ Deployment ready"
  fi
}

update_oauth_redirect() {
  echo "Updating OAuth redirect URI..."

  # Get portal route
  PORTAL_ROUTE=$(kubectl get route "$RELEASE_NAME-backstage" -n "$NAMESPACE" \
    -o jsonpath='{.spec.host}' 2>/dev/null)

  if [ -z "$PORTAL_ROUTE" ]; then
    echo "⚠️  Failed to get portal route"
    echo "OAuth redirect URI not updated - may need manual fix"
    return 1
  fi

  # Update OAuth app with real redirect URI
  local redirect_uri="https://$PORTAL_ROUTE/api/auth/oauth2/handler/frame"

  curl -k -u "admin:$ADMIN_PASS" \
    -X PATCH "https://$AAP_ROUTE/api/gateway/v1/applications/$OAUTH_APP_ID/" \
    -H "Content-Type: application/json" \
    -d "{\"redirect_uris\": \"$redirect_uri\"}" \
    &>/dev/null

  echo "✓ OAuth redirect URI updated: $redirect_uri"
}

display_success() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✓ Portal addon enabled successfully!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Portal URL: https://$PORTAL_ROUTE"
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
  get_aap_credentials
  select_organization
  create_oauth_app
  enable_oauth_tokens
  create_api_token
  get_registry_credentials
  create_registry_secret
  get_cluster_info
  create_helm_values
  install_helm_chart
  wait_for_deployment
  update_oauth_redirect
  display_success
}

main
