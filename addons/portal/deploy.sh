#!/usr/bin/env bash
# Portal addon — Ansible Automation Portal via OpenShift Template (portal/deploy.yaml)
# Pre-built portal hub image; APME plugins provide the Git Repositories feature.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_NAMESPACE="${AAP_NAMESPACE:-${NAMESPACE:-aap-operator}}"
PORTAL_NAMESPACE="${PORTAL_NAMESPACE:-redhat-rhaap-portal}"
ACTION="${1:-deploy}"
PORTAL_DIR="${HOME}/.aap-demo/portal"
TEMPLATE_FILE="${SCRIPT_DIR}/deploy.yaml"
PARAMS_FILE="${PORTAL_DIR}/params.env"

RELEASE_NAME="redhat-rhaap-portal"
OAUTH_APP_NAME="${OAUTH_APP_NAME:-ansible-automation-portal}"
PORTAL_HUB_IMAGE="${PORTAL_HUB_IMAGE:-quay.io/cferman/portal-hub-eap:latest}"
APME_URL="${APME_URL:-http://apme-gateway.apme.svc:8080}"

IS_ARM_CLUSTER=false
IS_MICROSHIFT=false

# ---------------------------------------------------------------------------
# Delete/Cleanup Handler
# ---------------------------------------------------------------------------

cleanup_portal_namespace() {
  local ns="$1"

  if helm list -n "$ns" 2>/dev/null | grep -q "^$RELEASE_NAME"; then
    echo "Removing legacy Helm release: $RELEASE_NAME (namespace: $ns)"
    helm uninstall "$RELEASE_NAME" -n "$ns" || true
  fi

  kubectl delete secret "$RELEASE_NAME-dynamic-plugins-registry-auth" \
    -n "$ns" &>/dev/null || true
  kubectl delete secret secrets-rhaap-portal -n "$ns" &>/dev/null || true
}

cleanup() {
  echo "Disabling portal addon..."

  cleanup_portal_namespace "$PORTAL_NAMESPACE"

  if [ "$AAP_NAMESPACE" != "$PORTAL_NAMESPACE" ]; then
    cleanup_portal_namespace "$AAP_NAMESPACE"
  fi

  if [ -f "$PORTAL_DIR/oauth_app_id" ]; then
    local app_id aap_route admin_pass
    app_id=$(cat "$PORTAL_DIR/oauth_app_id")
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
    echo "⚠️  Could not detect cluster architecture"
    IS_ARM_CLUSTER=false
    return
  fi

  echo "✓ Cluster architecture: $cluster_arch"
  if [[ "$cluster_arch" == "arm64" ]] || [[ "$cluster_arch" == "aarch64" ]]; then
    IS_ARM_CLUSTER=true
    echo "✓ ARM cluster — using pre-built portal hub image (${PORTAL_HUB_IMAGE})"
  else
    IS_ARM_CLUSTER=false
    echo "✓ x86 cluster — using pre-built portal hub image (${PORTAL_HUB_IMAGE})"
  fi
}

check_prerequisites() {
  echo "Checking prerequisites..."

  if ! kubectl cluster-info &>/dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster"
    exit 1
  fi

  if ! command -v oc &>/dev/null; then
    echo "❌ oc not found (required for OpenShift Template processing)"
    exit 1
  fi

  if ! command -v jq &>/dev/null; then
    echo "❌ jq not found — install: brew install jq"
    exit 1
  fi

  if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "❌ Portal template not found: $TEMPLATE_FILE"
    exit 1
  fi

  resolve_portal_profile

  if ! kubectl get route aap -n "$AAP_NAMESPACE" &>/dev/null; then
    echo "❌ AAP not deployed in namespace: $AAP_NAMESPACE"
    echo "Run 'aap-demo deploy' first"
    exit 1
  fi

  echo "✓ Prerequisites met"
}

cleanup_legacy_install() {
  if [ "$AAP_NAMESPACE" = "$PORTAL_NAMESPACE" ]; then
    return 0
  fi
  if helm list -n "$AAP_NAMESPACE" 2>/dev/null | grep -q "^$RELEASE_NAME"; then
    echo "Migrating legacy portal Helm release from $AAP_NAMESPACE..."
    cleanup_portal_namespace "$AAP_NAMESPACE"
  fi
}

_generate_random_secret() {
  openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32
}

_read_params_value() {
  local key="$1"
  [ -f "$PARAMS_FILE" ] || return 1
  local line
  line=$(grep -E "^${key}=" "$PARAMS_FILE" 2>/dev/null | tail -1 || true)
  [ -n "$line" ] || return 1
  printf '%s' "${line#*=}"
}

load_pinned_secrets() {
  PORTAL_DB_PASSWORD="$(_read_params_value PORTAL_DB_PASSWORD || _generate_random_secret)"
  PORTAL_SESSION_SECRET="$(_read_params_value PORTAL_SESSION_SECRET || _generate_random_secret)"
}

get_aap_credentials() {
  echo "Fetching AAP credentials..."

  AAP_ROUTE=$(kubectl get route aap -n "$AAP_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
  [ -n "$AAP_ROUTE" ] || {
    echo "❌ Failed to get AAP route"
    exit 1
  }

  ADMIN_PASS=$(kubectl get secret aap-admin-password -n "$AAP_NAMESPACE" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  [ -n "$ADMIN_PASS" ] || {
    echo "❌ Failed to get AAP admin password"
    exit 1
  }

  if ! curl -k -u "admin:$ADMIN_PASS" "https://$AAP_ROUTE/api/gateway/v1/ping/" \
    --max-time 10 &>/dev/null; then
    echo "❌ Cannot reach AAP at https://$AAP_ROUTE"
    exit 1
  fi

  echo "✓ AAP accessible at: $AAP_ROUTE"
}

select_organization() {
  echo "Selecting AAP organization..."

  local orgs_json org_count create_response
  orgs_json=$(curl -k -u "admin:$ADMIN_PASS" \
    "https://$AAP_ROUTE/api/gateway/v1/organizations/" \
    -H "Content-Type: application/json" 2>/dev/null)

  org_count=$(echo "$orgs_json" | jq -r '.count' 2>/dev/null || echo "0")

  if [ "$org_count" -eq 0 ]; then
    echo "Creating default organization..."
    create_response=$(curl -k -u "admin:$ADMIN_PASS" \
      -X POST "https://$AAP_ROUTE/api/gateway/v1/organizations/" \
      -H "Content-Type: application/json" \
      -d '{"name": "Default", "description": "Default organization for portal"}' \
      2>/dev/null)
    ORG_ID=$(echo "$create_response" | jq -r '.id')
    ORG_NAME="Default"
  else
    ORG_ID=$(echo "$orgs_json" | jq -r '.results[0].id')
    ORG_NAME=$(echo "$orgs_json" | jq -r '.results[0].name')
  fi

  [ -n "$ORG_ID" ] && [ "$ORG_ID" != "null" ] || {
    echo "❌ Failed to get/create organization"
    exit 1
  }
  echo "✓ Using organization: $ORG_NAME (ID: $ORG_ID)"
}

create_oauth_app() {
  echo "Creating OAuth application in AAP..."

  mkdir -p "$PORTAL_DIR"
  chmod 700 "$PORTAL_DIR"
  local oauth_credentials_file="$PORTAL_DIR/oauth_credentials.json"
  local encoded_app_name existing_app existing_count oauth_response

  encoded_app_name=$(jq -rn --arg n "$OAUTH_APP_NAME" '$n|@uri')
  existing_app=$(curl -k -u "admin:$ADMIN_PASS" \
    "https://$AAP_ROUTE/api/gateway/v1/applications/?name=${encoded_app_name}" \
    -H "Content-Type: application/json" 2>/dev/null)
  existing_count=$(echo "$existing_app" | jq -r '.count' 2>/dev/null || echo "0")

  if [ "$existing_count" -gt 0 ]; then
    OAUTH_APP_ID=$(echo "$existing_app" | jq -r '.results[0].id')
    CLIENT_ID=$(echo "$existing_app" | jq -r '.results[0].client_id')
    CLIENT_SECRET=""

    if [ -f "$oauth_credentials_file" ]; then
      local saved_id saved_secret
      saved_id=$(jq -r '.oauth_app_id // empty' "$oauth_credentials_file")
      saved_secret=$(jq -r '.client_secret // empty' "$oauth_credentials_file")
      if [ "$saved_id" = "$OAUTH_APP_ID" ] && [ -n "$saved_secret" ]; then
        CLIENT_SECRET="$saved_secret"
      fi
    fi

    if [ -z "$CLIENT_SECRET" ]; then
      echo "OAuth app exists but client secret unavailable — recreating..."
      curl -k -u "admin:$ADMIN_PASS" \
        -X DELETE "https://$AAP_ROUTE/api/gateway/v1/applications/$OAUTH_APP_ID/" \
        -H "Content-Type: application/json" &>/dev/null || true
      existing_count=0
    else
      echo "OAuth app already exists, using saved credentials..."
    fi
  fi

  if [ "$existing_count" -eq 0 ]; then
    oauth_response=$(curl -k -u "admin:$ADMIN_PASS" \
      -X POST "https://$AAP_ROUTE/api/gateway/v1/applications/" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"${OAUTH_APP_NAME}\",
        \"organization\": $ORG_ID,
        \"authorization_grant_type\": \"authorization-code\",
        \"client_type\": \"confidential\",
        \"pkce_required\": false,
        \"redirect_uris\": \"https://example.com\"
      }" 2>/dev/null)
    OAUTH_APP_ID=$(echo "$oauth_response" | jq -r '.id')
    CLIENT_ID=$(echo "$oauth_response" | jq -r '.client_id')
    CLIENT_SECRET=$(echo "$oauth_response" | jq -r '.client_secret')
  fi

  [ -n "$CLIENT_ID" ] && [ "$CLIENT_ID" != "null" ] || {
    echo "❌ Failed to create OAuth application"
    exit 1
  }
  [ -n "$CLIENT_SECRET" ] && [ "$CLIENT_SECRET" != "null" ] || {
    echo "❌ Failed to obtain OAuth client secret"
    exit 1
  }

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
  local settings current_value
  settings=$(curl -k -u "admin:$ADMIN_PASS" \
    "https://$AAP_ROUTE/api/gateway/v1/settings/" \
    -H "Content-Type: application/json" 2>/dev/null)
  current_value=$(echo "$settings" | jq -r '.ALLOW_OAUTH2_FOR_EXTERNAL_USERS' 2>/dev/null || echo "false")
  if [ "$current_value" = "true" ]; then
    echo "✓ OAuth tokens already enabled"
    return
  fi
  curl -k -u "admin:$ADMIN_PASS" \
    -X PATCH "https://$AAP_ROUTE/api/gateway/v1/settings/" \
    -H "Content-Type: application/json" \
    -d '{"ALLOW_OAUTH2_FOR_EXTERNAL_USERS": true}' &>/dev/null
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
  [ -n "$API_TOKEN" ] && [ "$API_TOKEN" != "null" ] || {
    echo "❌ Failed to generate API token"
    exit 1
  }
  echo "✓ API token generated"
}

get_cluster_info() {
  echo "Getting cluster information..."
  CLUSTER_BASE_URL=$(kubectl get ingresses.config/cluster -o jsonpath='{.spec.domain}' --request-timeout=5s 2>/dev/null || true)
  if [ -z "$CLUSTER_BASE_URL" ]; then
    IS_MICROSHIFT=true
    CLUSTER_BASE_URL=$(echo "$AAP_ROUTE" | sed "s/^aap-${AAP_NAMESPACE}\.//")
  else
    IS_MICROSHIFT=false
  fi
  [ -n "$CLUSTER_BASE_URL" ] || {
    echo "❌ Failed to get cluster base URL"
    exit 1
  }
  echo "✓ Cluster base URL: $CLUSTER_BASE_URL"
}

get_aap_host_url() {
  # AAP redirects HTTP token requests to HTTPS with an empty response body.
  # Keep HTTPS for pod-to-route OAuth requests; checkSSL is disabled for the
  # local cluster certificate and patch_aap_route_host_alias handles routing.
  echo "https://${AAP_ROUTE}"
}

get_aap_public_url() {
  echo "https://${AAP_ROUTE}"
}

generate_params_file() {
  mkdir -p "$PORTAL_DIR"
  chmod 700 "$PORTAL_DIR"
  local rhaap_url rhaap_public_url
  rhaap_url=$(get_aap_host_url)
  rhaap_public_url=$(get_aap_public_url)

  cat >"$PARAMS_FILE" <<EOF
NAMESPACE=${PORTAL_NAMESPACE}
CLUSTER_ROUTER_BASE=${CLUSTER_BASE_URL}
RHAAP_URL=${rhaap_url}
RHAAP_PUBLIC_URL=${rhaap_public_url}
RHAAP_OAUTH_CLIENT_ID=${CLIENT_ID}
RHAAP_OAUTH_CLIENT_SECRET=${CLIENT_SECRET}
RHAAP_TOKEN=${API_TOKEN}
GITHUB_TOKEN=
GITHUB_OAUTH_CLIENT_ID=
GITHUB_OAUTH_CLIENT_SECRET=
PORTAL_DB_PASSWORD=${PORTAL_DB_PASSWORD}
PORTAL_SESSION_SECRET=${PORTAL_SESSION_SECRET}
PORTAL_IMAGE=${PORTAL_HUB_IMAGE}
EXCLUDE_APME_PLUGINS="${EXCLUDE_APME_PLUGINS:-false}"
APME_URL=${APME_URL}
DISABLE_SCM_AUTH=true
EOF
  chmod 600 "$PARAMS_FILE"
  echo "✓ Template params written to $PARAMS_FILE"
}

apply_portal_template() {
  echo "Applying OpenShift Template (${TEMPLATE_FILE})..."

  local processed
  if ! processed=$(oc process --local -f "$TEMPLATE_FILE" --param-file="$PARAMS_FILE" -o json 2>&1); then
    echo "❌ oc process failed: $processed"
    exit 1
  fi

  if ! echo "$processed" | oc apply -f - 2>&1; then
    echo "❌ oc apply failed"
    exit 1
  fi

  echo "✓ Portal template applied"
}

configure_apme_template() {
  if ! kubectl get apme apme -n "$PORTAL_NAMESPACE" &>/dev/null; then
    return 0
  fi

  local template_file
  template_file="${SCRIPT_DIR}/../apme-eap/playbooks/roles/openshift_apme_setup/files/apme-register-git-repository/template.yaml"
  if [ ! -f "$template_file" ]; then
    echo "⚠️  APME repository template not found: $template_file"
    return 1
  fi

  echo "Registering APME repository template in the portal catalog..."
  kubectl create configmap apme-scaffolder-templates \
    --from-file=template.yaml="$template_file" \
    -n "$PORTAL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  if ! command -v yq &>/dev/null; then
    echo "⚠️  yq not available — APME template catalog registration skipped"
    return 1
  fi

  local config patched
  config=$(kubectl get configmap portal-app-config -n "$PORTAL_NAMESPACE" \
    -o jsonpath='{.data.app-config\.local\.yaml}')
  patched=$(printf '%s' "$config" | yq '.catalog.locations = ((.catalog.locations // []) | map(select(.target != "/opt/app-root/src/configs/catalog/apme-register-git-repository/template.yaml"))) + [{"type": "file", "target": "/opt/app-root/src/configs/catalog/apme-register-git-repository/template.yaml", "rules": [{"allow": ["Template"]}]}]')
  kubectl get configmap portal-app-config -n "$PORTAL_NAMESPACE" -o json \
    | jq --arg cfg "$patched" '.data["app-config.local.yaml"] = $cfg' \
    | kubectl apply -f - >/dev/null
  echo "✓ APME repository template registered"
}

patch_catalog_org() {
  if [ "${ORG_NAME:-Default}" = "Default" ]; then
    return 0
  fi

  echo "Patching catalog org to: $ORG_NAME"
  if ! command -v python3 &>/dev/null; then
    echo "⚠️  python3 not available — catalog will sync Default org only"
    return 0
  fi

  if ! kubectl get configmap portal-app-config -n "$PORTAL_NAMESPACE" &>/dev/null; then
    echo "⚠️  portal-app-config not found — skipping org patch"
    return 0
  fi

  kubectl get configmap portal-app-config -n "$PORTAL_NAMESPACE" -o json | ORG_NAME="$ORG_NAME" python3 -c "
import json, os, sys, yaml
cm = json.load(sys.stdin)
org = os.environ['ORG_NAME']
data = yaml.safe_load(cm['data']['app-config.local.yaml'])
data.setdefault('catalog', {}).setdefault('providers', {}).setdefault('rhaap', {}).setdefault('production', {})['orgs'] = [org]
cm['data']['app-config.local.yaml'] = yaml.dump(data, default_flow_style=False, sort_keys=False, width=120)
json.dump(cm, sys.stdout)
" | kubectl apply -f - 2>/dev/null && echo "✓ Catalog org patched" || echo "⚠️  Could not patch catalog org"
}

patch_aap_route_host_alias() {
  if [ "${IS_MICROSHIFT:-false}" != true ]; then
    return 0
  fi

  echo "Configuring AAP route host alias for in-pod OAuth token exchange..."
  local aap_ip current_ip
  aap_ip=$(kubectl get svc aap -n "$AAP_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  [ -n "$aap_ip" ] || {
    echo "⚠️  Could not resolve AAP service ClusterIP"
    return 1
  }

  current_ip=$(kubectl get deployment "$RELEASE_NAME" -n "$PORTAL_NAMESPACE" \
    -o jsonpath="{.spec.template.spec.hostAliases[?(@.hostnames[0]=='${AAP_ROUTE}')].ip}" 2>/dev/null)

  kubectl patch deployment "$RELEASE_NAME" -n "$PORTAL_NAMESPACE" --type=merge -p "{
    \"spec\": {
      \"template\": {
        \"spec\": {
          \"hostAliases\": [
            {\"ip\": \"$aap_ip\", \"hostnames\": [\"$AAP_ROUTE\", \"registry.${CLUSTER_BASE_URL}\"]}
          ],
          \"containers\": [{
            \"name\": \"backstage-backend\",
            \"env\": [{\"name\": \"NODE_TLS_REJECT_UNAUTHORIZED\", \"value\": \"0\"}]
          }]
        }
      }
    }
  }" 2>/dev/null || true

  if [ "$current_ip" = "$aap_ip" ]; then
    echo "✓ AAP route host alias already configured"
  else
    echo "✓ AAP route host alias: $AAP_ROUTE → $aap_ip"
  fi
}

rollout_portal() {
  kubectl rollout restart deployment/"$RELEASE_NAME" -n "$PORTAL_NAMESPACE" &>/dev/null || true
}

wait_for_deployment() {
  echo "Waiting for portal deployment to be ready..."
  if kubectl rollout status deployment/"$RELEASE_NAME" \
    -n "$PORTAL_NAMESPACE" --timeout=600s 2>/dev/null; then
    echo "✓ Deployment ready"
  else
    echo "⚠️  Deployment still rolling out — check: kubectl get pods -n $PORTAL_NAMESPACE"
  fi
}

verify_oauth_redirect() {
  echo "Updating OAuth redirect URI..."
  PORTAL_ROUTE=$(kubectl get route "$RELEASE_NAME" -n "$PORTAL_NAMESPACE" \
    -o jsonpath='{.spec.host}' 2>/dev/null)
  [ -n "$PORTAL_ROUTE" ] || {
    echo "⚠️  Failed to get portal route"
    return 1
  }

  local redirect_uri="https://$PORTAL_ROUTE/api/auth/rhaap/handler/frame?env=production"
  curl -k -u "admin:$ADMIN_PASS" \
    -X PATCH "https://$AAP_ROUTE/api/gateway/v1/applications/$OAUTH_APP_ID/" \
    -H "Content-Type: application/json" \
    -d "{\"redirect_uris\": \"$redirect_uri\", \"pkce_required\": false}" &>/dev/null
  echo "✓ OAuth redirect URI updated: $redirect_uri"

  local registered_uri
  registered_uri=$(curl -sk -u "admin:$ADMIN_PASS" \
    "https://$AAP_ROUTE/api/gateway/v1/applications/$OAUTH_APP_ID/" \
    | jq -r '.redirect_uris // empty' 2>/dev/null)
  if [ -n "$registered_uri" ] && [ "$registered_uri" != "$redirect_uri" ]; then
    echo "⚠️  AAP OAuth redirect URI mismatch"
    echo "    Expected: $redirect_uri"
    echo "    In AAP:   $registered_uri"
    return 1
  fi
  echo "✓ AAP OAuth redirect URI verified"
}

verify_aap_host_url() {
  echo "Verifying AAP URLs in portal pod..."
  local aap_host_url aap_public_url
  aap_host_url=$(kubectl exec deployment/"$RELEASE_NAME" -c backstage-backend -n "$PORTAL_NAMESPACE" \
    -- printenv AAP_HOST_URL 2>/dev/null || true)
  aap_public_url=$(kubectl exec deployment/"$RELEASE_NAME" -c backstage-backend -n "$PORTAL_NAMESPACE" \
    -- printenv AAP_PUBLIC_URL 2>/dev/null || true)
  [ -n "$aap_host_url" ] || {
    echo "⚠️  Could not read AAP_HOST_URL from portal pod"
    return 1
  }
  [ -n "$aap_public_url" ] || {
    echo "⚠️  Could not read AAP_PUBLIC_URL from portal pod"
    return 1
  }
  if [[ "$aap_host_url" == *".svc"* ]]; then
    echo "❌ Portal backend URL is in-cluster: $aap_host_url"
    return 1
  fi
  if [[ "$aap_host_url" != https://* ]]; then
    echo "❌ Portal backend URL must use https:// for OAuth token exchange (got $aap_host_url)"
    return 1
  fi
  if [[ "$aap_public_url" != https://* ]]; then
    echo "❌ Portal OAuth popup URL must be https:// (got $aap_public_url)"
    return 1
  fi
  echo "✓ AAP backend URL: $aap_host_url"
  echo "✓ AAP OAuth popup URL: $aap_public_url"
}

verify_oauth_client() {
  echo "Verifying OAuth client credentials..."
  local http_code aap_url
  aap_url=$(get_aap_public_url)
  http_code=$(kubectl exec deployment/"$RELEASE_NAME" -c backstage-backend -n "$PORTAL_NAMESPACE" \
    -- sh -c "
      AUTH=\$(printf '%s:%s' \"\$OAUTH_CLIENT_ID\" \"\$OAUTH_CLIENT_SECRET\" | base64 -w0)
      curl -sk -o /dev/null -w '%{http_code}' -X POST '${aap_url}/o/token/' \
        -H \"Authorization: Basic \$AUTH\" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d 'grant_type=authorization_code&code=invalid&redirect_uri=https://${PORTAL_ROUTE}/api/auth/rhaap/handler/frame?env=production'
    " 2>/dev/null || echo "000")

  if [ "$http_code" = "401" ]; then
    echo "❌ OAuth client credentials rejected by AAP"
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
  echo "Install: OpenShift Template (addons/portal/deploy.yaml)"
  echo "Image: ${PORTAL_HUB_IMAGE}"
  if [ "${EXCLUDE_APME_PLUGINS:-false}" = "true" ]; then
    echo "APME plugins: excluded (Git Repositories unavailable)"
  else
    echo "APME plugins: enabled (Git Repositories available)"
  fi
  echo ""
  echo "Next steps:"
  echo "1. Open the portal URL in your browser"
  echo "2. Click 'Sign In' and authenticate with AAP credentials"
  echo "3. Browse AAP job templates in the catalog"
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
  load_pinned_secrets
  get_aap_credentials
  select_organization
  create_oauth_app
  enable_oauth_tokens
  create_api_token
  get_cluster_info
  generate_params_file
  apply_portal_template
  configure_apme_template
  patch_catalog_org
  rollout_portal
  wait_for_deployment
  patch_aap_route_host_alias
  verify_oauth_redirect
  rollout_portal
  wait_for_deployment
  verify_aap_host_url || echo "⚠️  AAP host URL verification failed"
  verify_oauth_client || echo "⚠️  OAuth client verification failed"
  display_success
}

main
