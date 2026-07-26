#!/usr/bin/env bash
# Deploy EDA Playground with AAP OAuth Integration
#
# Deploys EDA Playground - an interactive web-based tool for testing and
# experimenting with Event-Driven Ansible integrations and webhooks.
#
# This script automatically creates an AAP OAuth application and configures
# EDA Playground to use AAP for authentication.
#
# Prerequisites:
#   - kubectl connected to cluster
#   - AAP deployed (aap-demo deploy)
#   - jq installed for JSON parsing
#
# Environment Variables (optional - reuse existing OAuth app):
#   EDA_OAUTH_APP_ID     OAuth application ID from AAP
#   EDA_CLIENT_ID        OAuth client ID
#   EDA_CLIENT_SECRET    OAuth client secret
#
# Usage:
#   ./deploy.sh          # Deploy EDA Playground
#   ./deploy.sh --delete # Remove EDA Playground

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-eda-playground}"
AAP_NAMESPACE="${AAP_NAMESPACE:-aap-operator}"
OAUTH_APP_NAME="${OAUTH_APP_NAME:-eda-playground}"

ACTION="${1:-deploy}"

# ---------------------------------------------------------------------------
# Cleanup Function
# ---------------------------------------------------------------------------
cleanup() {
  echo "Removing EDA Playground..."

  # Try to delete OAuth app from AAP
  local aap_route admin_pass oauth_app_id
  aap_route=$(kubectl get route aap -n "$AAP_NAMESPACE" \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)
  admin_pass=$(kubectl get secret aap-admin-password -n "$AAP_NAMESPACE" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

  if [ -n "$aap_route" ] && [ -n "$admin_pass" ]; then
    # Use environment variable if set, otherwise search by name
    if [ -n "$EDA_OAUTH_APP_ID" ]; then
      oauth_app_id="$EDA_OAUTH_APP_ID"
      echo "  Deleting OAuth application (ID: $oauth_app_id) from AAP..."
    else
      # Search for OAuth app by name
      echo "  Searching for OAuth application in AAP..."
      local encoded_app_name existing_app
      encoded_app_name=$(jq -rn --arg n "$OAUTH_APP_NAME" '$n|@uri')
      existing_app=$(curl -k -u "admin:$admin_pass" \
        "https://$aap_route/api/gateway/v1/applications/?name=${encoded_app_name}" \
        -H "Content-Type: application/json" 2>/dev/null)

      oauth_app_id=$(echo "$existing_app" | jq -r '.results[0].id // empty' 2>/dev/null)

      if [ -n "$oauth_app_id" ] && [ "$oauth_app_id" != "null" ]; then
        echo "  Found OAuth application (ID: $oauth_app_id) - deleting..."
      fi
    fi

    # Delete if we have an ID
    if [ -n "$oauth_app_id" ] && [ "$oauth_app_id" != "null" ]; then
      curl -k -u "admin:$admin_pass" \
        -X DELETE "https://$aap_route/api/gateway/v1/applications/$oauth_app_id/" \
        -H "Content-Type: application/json" &>/dev/null || true
      echo "  ✓ OAuth app deleted from AAP"
    else
      echo "  ⚠️  OAuth app not found in AAP (may have been deleted manually)"
    fi
  else
    echo "  ⚠️  Cannot connect to AAP - skipping OAuth app deletion"
  fi

  kubectl delete namespace "$NAMESPACE" 2>/dev/null || true

  echo "✓ EDA Playground removed"
  exit 0
}

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  cleanup
fi

# ---------------------------------------------------------------------------
# Prerequisites Check
# ---------------------------------------------------------------------------
check_prerequisites() {
  echo "Checking prerequisites..."

  # Check kubectl connectivity
  if ! kubectl cluster-info &>/dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster"
    exit 1
  fi

  # Check AAP deployment
  if ! kubectl get route aap -n "$AAP_NAMESPACE" &>/dev/null; then
    echo "❌ AAP not deployed in namespace: $AAP_NAMESPACE"
    echo "   Run 'aap-demo deploy' first"
    exit 1
  fi

  # Check jq installed
  if ! command -v jq &>/dev/null; then
    echo "❌ jq not found - required for JSON parsing"
    echo "   Install: brew install jq (macOS) or apt install jq (Linux)"
    exit 1
  fi

  echo "  ✓ Prerequisites met"
}

# ---------------------------------------------------------------------------
# Get AAP Credentials and Test Connectivity
# ---------------------------------------------------------------------------
get_aap_credentials() {
  echo "Fetching AAP credentials..."

  AAP_ROUTE=$(kubectl get route aap -n "$AAP_NAMESPACE" \
    -o jsonpath='{.spec.host}' 2>/dev/null)
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

  # Test AAP connectivity
  if ! curl -k -u "admin:$ADMIN_PASS" "https://$AAP_ROUTE/api/gateway/v1/ping/" \
    --max-time 10 &>/dev/null; then
    echo "❌ Cannot reach AAP at https://$AAP_ROUTE"
    exit 1
  fi

  echo "  ✓ AAP accessible at: https://$AAP_ROUTE"
}

# ---------------------------------------------------------------------------
# Select or Create AAP Organization
# ---------------------------------------------------------------------------
select_organization() {
  echo "Selecting AAP organization..."

  local orgs_json org_count
  orgs_json=$(curl -k -u "admin:$ADMIN_PASS" \
    "https://$AAP_ROUTE/api/gateway/v1/organizations/" \
    -H "Content-Type: application/json" 2>/dev/null)

  org_count=$(echo "$orgs_json" | jq -r '.count' 2>/dev/null || echo "0")

  if [ "$org_count" -eq 0 ]; then
    echo "  Creating default organization..."
    local create_response
    create_response=$(curl -k -u "admin:$ADMIN_PASS" \
      -X POST "https://$AAP_ROUTE/api/gateway/v1/organizations/" \
      -H "Content-Type: application/json" \
      -d '{"name": "Default", "description": "Default organization"}' \
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

  echo "  ✓ Using organization: ${ORG_NAME} (ID: $ORG_ID)"
}

# ---------------------------------------------------------------------------
# Create or Reuse OAuth Application
# ---------------------------------------------------------------------------
create_oauth_app() {
  echo "Configuring OAuth application..."

  # Check environment variables first
  if [ -n "$EDA_OAUTH_APP_ID" ] && [ -n "$EDA_CLIENT_ID" ] && [ -n "$EDA_CLIENT_SECRET" ]; then
    OAUTH_APP_ID="$EDA_OAUTH_APP_ID"
    CLIENT_ID="$EDA_CLIENT_ID"
    CLIENT_SECRET="$EDA_CLIENT_SECRET"
    echo "  Using OAuth credentials from environment variables..."

    # Verify the OAuth app still exists in AAP
    local existing_app
    existing_app=$(curl -k -u "admin:$ADMIN_PASS" \
      "https://$AAP_ROUTE/api/gateway/v1/applications/$OAUTH_APP_ID/" \
      -H "Content-Type: application/json" 2>/dev/null)

    if ! echo "$existing_app" | jq -e '.id' &>/dev/null; then
      echo "  OAuth app ID from environment no longer exists - creating new app..."
      OAUTH_APP_ID=""
    else
      echo "  ✓ OAuth app verified in AAP"
    fi
  fi

  # Create new OAuth app if not provided via environment
  if [ -z "$OAUTH_APP_ID" ]; then
    echo "  Creating new OAuth application in AAP..."

    local oauth_response
    oauth_response=$(curl -k -u "admin:$ADMIN_PASS" \
      -X POST "https://$AAP_ROUTE/api/gateway/v1/applications/" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"${OAUTH_APP_NAME}\",
        \"organization\": $ORG_ID,
        \"authorization_grant_type\": \"authorization-code\",
        \"client_type\": \"confidential\",
        \"redirect_uris\": \"https://example.com/auth/callback\"
      }" 2>/dev/null)

    # Extract and validate credentials
    OAUTH_APP_ID=$(echo "$oauth_response" | jq -r '.id')
    CLIENT_ID=$(echo "$oauth_response" | jq -r '.client_id')
    CLIENT_SECRET=$(echo "$oauth_response" | jq -r '.client_secret')

    if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" = "null" ]; then
      echo "❌ Failed to create OAuth application"
      echo "   Response: $oauth_response"
      exit 1
    fi

    if [ -z "$CLIENT_SECRET" ] || [ "$CLIENT_SECRET" = "null" ]; then
      echo "❌ Failed to obtain OAuth client secret"
      echo "   Response: $oauth_response"
      exit 1
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✓ OAuth application created!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "To reuse these credentials on next deployment, export them:"
    echo ""
    echo "  export EDA_OAUTH_APP_ID=\"$OAUTH_APP_ID\""
    echo "  export EDA_CLIENT_ID=\"$CLIENT_ID\""
    echo "  export EDA_CLIENT_SECRET=\"$CLIENT_SECRET\""  # pragma: allowlist secret
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Generate Session Secret
# ---------------------------------------------------------------------------
generate_session_secret() {
  echo "Generating session secret..."

  # Generate 32-character random string (matching ao-eap pattern)
  SESSION_SECRET=$(head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)

  if [ -z "$SESSION_SECRET" ] || [ ${#SESSION_SECRET} -lt 32 ]; then
    echo "❌ Failed to generate session secret"
    exit 1
  fi

  echo "  ✓ Session secret generated"
}

# ---------------------------------------------------------------------------
# Get Cluster Domain Information
# ---------------------------------------------------------------------------
get_cluster_info() {
  echo "Getting cluster domain information..."

  # Try to get cluster domain from ingresses.config (OpenShift)
  CLUSTER_DOMAIN=$(kubectl get ingresses.config/cluster \
    -o jsonpath='{.spec.domain}' --request-timeout=5s 2>/dev/null || true)

  # Fall back to deriving from AAP route (MicroShift/CRC)
  if [ -z "$CLUSTER_DOMAIN" ]; then
    IS_MICROSHIFT=true
    CLUSTER_DOMAIN=$(echo "$AAP_ROUTE" | sed "s/^aap-${AAP_NAMESPACE}\.//")
  else
    IS_MICROSHIFT=false
  fi

  if [ -z "$CLUSTER_DOMAIN" ]; then
    echo "❌ Failed to determine cluster domain"
    exit 1
  fi

  # Set cookie domain (leading dot for wildcard)
  COOKIE_DOMAIN=".${CLUSTER_DOMAIN}"

  echo "  ✓ Cluster domain: $CLUSTER_DOMAIN"
  echo "  ✓ Cookie domain: $COOKIE_DOMAIN"
  echo "  ✓ Cluster type: $([ "$IS_MICROSHIFT" = true ] && echo "MicroShift" || echo "OpenShift")"
}

# ---------------------------------------------------------------------------
# Get AAP Host URL (HTTP on MicroShift, HTTPS on OpenShift)
# ---------------------------------------------------------------------------
get_aap_host_url() {
  # On MicroShift/CRC, OAuth token exchange from pod must use http://<route>
  # Combined with hostAliases, this resolves to AAP Service ClusterIP:80
  if [ "${IS_MICROSHIFT:-false}" = true ]; then
    echo "http://${AAP_ROUTE}"
  else
    echo "https://${AAP_ROUTE}"
  fi
}

# ---------------------------------------------------------------------------
# Patch Deployment with AAP Route Host Alias
# ---------------------------------------------------------------------------
patch_aap_route_host_alias() {
  echo "Configuring AAP route host alias for in-pod connectivity..."

  # Skip on non-MicroShift clusters
  if [ "${IS_MICROSHIFT:-false}" != true ]; then
    echo "  ✓ Skipping hostAliases (not needed on OpenShift)"
    return 0
  fi

  # Get AAP Service ClusterIP
  local aap_ip
  aap_ip=$(kubectl get svc aap -n "$AAP_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

  if [ -z "$aap_ip" ]; then
    echo "  ⚠️  Could not resolve AAP service ClusterIP; skipping host alias"
    return 1
  fi

  # Check if already configured
  local current_ip
  current_ip=$(kubectl get deployment eda-playground -n "$NAMESPACE" \
    -o jsonpath="{.spec.template.spec.hostAliases[?(@.hostnames[0]=='${AAP_ROUTE}')].ip}" 2>/dev/null)

  if [ "$current_ip" = "$aap_ip" ]; then
    echo "  ✓ AAP route host alias already configured ($AAP_ROUTE → $aap_ip)"
    return 0
  fi

  # Patch deployment with hostAliases
  echo "  Patching deployment with hostAliases ($AAP_ROUTE → $aap_ip)..."
  kubectl patch deployment eda-playground -n "$NAMESPACE" --type=merge -p "{
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

  # Wait for rollout
  echo "  Waiting for deployment rollout after host alias patch..."
  if ! kubectl rollout status deployment/eda-playground \
    -n "$NAMESPACE" \
    --timeout=180s 2>/dev/null; then
    echo "  ⚠️  Rollout after host alias patch is still in progress"
    return 1
  fi

  echo "  ✓ AAP route host alias configured: $AAP_ROUTE → $aap_ip"
}

# ---------------------------------------------------------------------------
# Create OAuth Credentials Secret
# ---------------------------------------------------------------------------
create_oauth_secret() {
  echo "Creating OAuth credentials secret..."

  # Ensure namespace exists
  kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

  # Placeholder redirect URI - will be updated after route is created
  local AAP_REDIRECT_URI="https://eda-playground.${CLUSTER_DOMAIN}/auth/callback"

  # Delete existing secret if present
  kubectl delete secret eda-playground-oauth -n "$NAMESPACE" &>/dev/null || true

  # Create secret using heredoc
  kubectl create -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: eda-playground-oauth
  namespace: $NAMESPACE
  labels:
    app: eda-playground
    app.kubernetes.io/name: eda-playground
    app.kubernetes.io/component: auth
type: Opaque
stringData:
  AAP_BASE_URL: "$AAP_BASE_URL"
  AAP_CLIENT_ID: "$CLIENT_ID"
  AAP_CLIENT_SECRET: "$CLIENT_SECRET"
  AAP_REDIRECT_URI: "$AAP_REDIRECT_URI"
  COOKIE_DOMAIN: "$COOKIE_DOMAIN"
  COOKIE_SECURE: "true"
  SESSION_SECRET: "$SESSION_SECRET"
EOF

  echo "  ✓ OAuth secret created"
}

# ---------------------------------------------------------------------------
# Deploy Manifests
# ---------------------------------------------------------------------------
deploy_manifests() {
  echo "Deploying EDA Playground manifests..."

  # Create namespace
  kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

  # Grant anyuid SCC (needed for OpenShift/MicroShift)
  if command -v oc &>/dev/null; then
    oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${NAMESPACE}" \
      2>/dev/null || true
  fi

  # Apply other manifests
  kubectl apply -f "${SCRIPT_DIR}/configmap.yaml"
  kubectl apply -f "${SCRIPT_DIR}/service.yaml"
  kubectl apply -f "${SCRIPT_DIR}/deployment.yaml"

  # Apply route with dynamic hostname
  sed "s|host: eda-playground\.apps\.127\.0\.0\.1\.nip\.io|host: eda-playground.${CLUSTER_DOMAIN}|" \
    "${SCRIPT_DIR}/route.yaml" | kubectl apply -f -

  echo "  ✓ Manifests deployed"
}

# ---------------------------------------------------------------------------
# Wait for Deployment to Be Ready
# ---------------------------------------------------------------------------
wait_for_deployment() {
  echo "Waiting for deployment to be ready..."

  if ! kubectl wait --for=condition=available deployment/eda-playground \
    -n "$NAMESPACE" --timeout=180s 2>/dev/null; then
    echo "  ⚠️  Deployment taking longer than expected"
    echo "     Check: kubectl get pods -n $NAMESPACE"
    return 1
  else
    echo "  ✓ Deployment ready"
  fi
}

# ---------------------------------------------------------------------------
# Update OAuth Redirect URI
# ---------------------------------------------------------------------------
update_oauth_redirect() {
  echo "Updating OAuth redirect URI..."

  # Get actual route hostname
  EDA_ROUTE=$(kubectl get route eda-playground -n "$NAMESPACE" \
    -o jsonpath='{.spec.host}' 2>/dev/null)

  if [ -z "$EDA_ROUTE" ]; then
    echo "  ⚠️  Failed to get EDA Playground route"
    echo "     OAuth redirect URI not updated - may need manual configuration"
    return 1
  fi

  # Update OAuth app with actual redirect URI
  local redirect_uri="https://$EDA_ROUTE/auth/callback"

  curl -k -u "admin:$ADMIN_PASS" \
    -X PATCH "https://$AAP_ROUTE/api/gateway/v1/applications/$OAUTH_APP_ID/" \
    -H "Content-Type: application/json" \
    -d "{\"redirect_uris\": \"$redirect_uri\"}" \
    &>/dev/null

  echo "  ✓ OAuth redirect URI updated: $redirect_uri"
}

# ---------------------------------------------------------------------------
# Display Success Message
# ---------------------------------------------------------------------------
display_success() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✓ EDA Playground deployed with AAP OAuth!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  URL:       https://${EDA_ROUTE}"
  echo "  Namespace: ${NAMESPACE}"
  echo "  AAP:       https://${AAP_ROUTE}"
  echo ""
  echo "OAuth Configuration:"
  echo "  App ID:        $OAUTH_APP_ID"
  echo "  Client ID:     $CLIENT_ID"
  echo "  Redirect URI:  https://${EDA_ROUTE}/auth/callback"
  echo ""
  echo "Next steps:"
  echo "  1. Open https://${EDA_ROUTE} in your browser"
  echo "  2. Click 'Sign In with AAP'"
  echo "  3. Authenticate with AAP credentials (admin / <password>)"
  echo "  4. Test webhooks and EDA integrations"
  echo ""
  echo "Useful commands:"
  echo "  Status:   kubectl get pods -n ${NAMESPACE}"
  echo "  Logs:     kubectl logs -n ${NAMESPACE} -l app=eda-playground"
  echo "  Disable:  aap-demo disable eda-playground"
  echo ""
  if [ -z "$EDA_OAUTH_APP_ID" ]; then
    echo "TIP: To reuse OAuth credentials on next deployment:"
    echo "   export EDA_OAUTH_APP_ID=\"$OAUTH_APP_ID\""
    echo "   export EDA_CLIENT_ID=\"$CLIENT_ID\""
    echo "   export EDA_CLIENT_SECRET=\"$CLIENT_SECRET\""
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Main Deployment Flow
# ---------------------------------------------------------------------------
main() {
  check_prerequisites
  get_aap_credentials
  select_organization
  create_oauth_app
  generate_session_secret
  get_cluster_info

  # Set AAP_BASE_URL based on cluster type
  AAP_BASE_URL=$(get_aap_host_url)
  echo "  ✓ Using AAP base URL for pod: $AAP_BASE_URL"

  create_oauth_secret
  deploy_manifests
  wait_for_deployment || echo "  ⚠️  Continuing despite deployment timeout..."
  patch_aap_route_host_alias || echo "  ⚠️  Host alias patch failed (may still work)"
  update_oauth_redirect || echo "  ⚠️  OAuth redirect update failed (may still work)"
  display_success
}

main
