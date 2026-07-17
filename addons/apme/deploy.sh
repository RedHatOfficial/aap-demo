#!/usr/bin/env bash
# APME (Ansible Portal Managed Engine) addon
# Deploys APME Gateway via Helm (x86) or community RHDH with APME plugins (ARM/macOS).
# Portal addon provides the RHDH UI layer on x86; on ARM we deploy community RHDH directly.
# Auto-detects cluster CPU (arm64 vs amd64) and selects image profile.
#
# ARM: downloads CI-built plugin artifacts from GitHub Actions, pushes to an in-cluster
# HTTP registry, then patches the dynamic-plugins configmap to load from it.
#
# Usage:
#   ./deploy.sh          # Deploy APME
#   ./deploy.sh --delete # Remove APME

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_NAMESPACE="${AAP_NAMESPACE:-${NAMESPACE:-aap-operator}}"
APME_NAMESPACE="${APME_NAMESPACE:-apme}"
ACTION="${1:-deploy}"
APME_DIR="${HOME}/.aap-demo/apme"

# x86: APME Helm chart
APME_RELEASE_NAME="apme"
APME_CHART_REPO="apme/apme"
APME_CHART_VERSION="${APME_CHART_VERSION:-}"

# ARM: community RHDH via portal chart (same pattern as portal addon)
RHDH_RELEASE_NAME="apme-rhdh"
RHDH_CHART_REPO="openshift-helm-charts/redhat-rhaap-portal"
DEFAULT_PLUGIN_VERSION="${DEFAULT_PLUGIN_VERSION:-2.2}"

# ARM profile: upstream community RHDH (multi-arch) + RHEL9 PostgreSQL
DEFAULT_RHDH_REGISTRY="${DEFAULT_RHDH_REGISTRY:-quay.io}"
DEFAULT_RHDH_REPOSITORY="${DEFAULT_RHDH_REPOSITORY:-rhdh-community/rhdh}"
DEFAULT_RHDH_TAG="${DEFAULT_RHDH_TAG:-1.10}"
DEFAULT_POSTGRES_REGISTRY="${DEFAULT_POSTGRES_REGISTRY:-registry.redhat.io}"
DEFAULT_POSTGRES_REPOSITORY="${DEFAULT_POSTGRES_REPOSITORY:-rhel9/postgresql-15}"
DEFAULT_POSTGRES_TAG="${DEFAULT_POSTGRES_TAG:-9.8-1782419742}"

# ARM: CI artifact source (override via env vars for newer builds)
CI_REPO="${CI_REPO:-ansible/ansible-rhdh-plugins}"
CI_RUN_ID="${CI_RUN_ID:-29515254608}"
CI_ARTIFACT_ID="${CI_ARTIFACT_ID:-8382656837}"
CI_PLUGIN_IMAGE_TAG="${CI_PLUGIN_IMAGE_TAG:-1fdc190-20260716162226}"

IS_ARM_CLUSTER=false
IS_MICROSHIFT=false
CLUSTER_BASE_URL=""

OAUTH_APP_NAME="${OAUTH_APP_NAME:-aap-demo-apme}"

# Populated by get_aap_credentials / create_oauth_app / create_api_token
AAP_ROUTE=""
ADMIN_PASS=""
ORG_ID=""
OAUTH_APP_ID=""
CLIENT_ID=""
CLIENT_SECRET=""
API_TOKEN=""

# ---------------------------------------------------------------------------
# Delete handler
# ---------------------------------------------------------------------------

cleanup() {
  echo "Disabling APME addon..."

  # Remove ARM RHDH release
  if helm list -n "$APME_NAMESPACE" 2>/dev/null | grep -q "^$RHDH_RELEASE_NAME"; then
    echo "Uninstalling Helm release: $RHDH_RELEASE_NAME"
    helm uninstall "$RHDH_RELEASE_NAME" -n "$APME_NAMESPACE" || true
  fi

  # Remove x86 APME release
  if helm list -n "$APME_NAMESPACE" 2>/dev/null | grep -q "^$APME_RELEASE_NAME"; then
    echo "Uninstalling Helm release: $APME_RELEASE_NAME"
    helm uninstall "$APME_RELEASE_NAME" -n "$APME_NAMESPACE" || true
  fi

  # Remove ARM in-cluster plugin registry
  kubectl delete deployment plugin-registry -n "$APME_NAMESPACE" 2>/dev/null || true
  kubectl delete service plugin-registry -n "$APME_NAMESPACE" 2>/dev/null || true

  kubectl delete namespace "$APME_NAMESPACE" --timeout=120s 2>/dev/null || true
  rm -rf "$APME_DIR"

  echo "APME addon disabled"
  exit 0
}

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  cleanup
fi

# ---------------------------------------------------------------------------
# Architecture detection (mirrors portal addon pattern)
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
  if [ -n "${APME_ARCH:-}" ]; then
    case "$APME_ARCH" in
      arm | arm64 | aarch64)
        echo "arm64"
        return
        ;;
      x86 | amd64 | x86_64)
        echo "amd64"
        return
        ;;
      *)
        echo "❌ Unknown APME_ARCH: $APME_ARCH (use arm or x86)" >&2
        exit 1
        ;;
    esac
  fi

  kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true
}

resolve_apme_profile() {
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
    echo "✓ Using ARM profile (community RHDH + CI APME plugins — no APME engine/gateway on arm64)"
  else
    IS_ARM_CLUSTER=false
    echo "✓ Using x86 profile (full APME Helm chart)"
  fi
}

# ---------------------------------------------------------------------------
# Cluster URL detection (same as portal addon)
# ---------------------------------------------------------------------------

detect_cluster_base_url() {
  CLUSTER_BASE_URL=$(kubectl get ingresses.config/cluster \
    -o jsonpath='{.spec.domain}' --request-timeout=5s 2>/dev/null || true)

  if [ -z "$CLUSTER_BASE_URL" ]; then
    IS_MICROSHIFT=true
    local aap_route
    aap_route=$(kubectl get route aap -n "$AAP_NAMESPACE" \
      -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ -n "$aap_route" ]; then
      CLUSTER_BASE_URL=$(echo "$aap_route" | sed "s/^aap-${AAP_NAMESPACE}\\.//")
    fi
  else
    IS_MICROSHIFT=false
  fi

  if [ -z "$CLUSTER_BASE_URL" ]; then
    CLUSTER_BASE_URL="apps.127.0.0.1.nip.io"
    echo "⚠️  Could not detect cluster base URL; defaulting to $CLUSTER_BASE_URL"
  else
    echo "✓ Cluster base URL: $CLUSTER_BASE_URL"
  fi
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

check_prerequisites() {
  echo "Checking prerequisites..."

  if ! kubectl cluster-info &>/dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster"
    echo "Ensure oc/kubectl is configured and cluster is accessible"
    exit 1
  fi

  resolve_apme_profile
  detect_cluster_base_url

  if ! command -v helm &>/dev/null; then
    echo "❌ Helm not found"
    echo "Install Helm 3.10+ from https://helm.sh/docs/intro/install/"
    exit 1
  fi

  local helm_version
  helm_version=$(helm version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+' | sed 's/v//')
  local helm_major helm_minor
  helm_major=$(echo "$helm_version" | cut -d. -f1)
  helm_minor=$(echo "$helm_version" | cut -d. -f2)
  if [ "${helm_major:-0}" -lt 3 ] || { [ "${helm_major:-0}" -eq 3 ] && [ "${helm_minor:-0}" -lt 10 ]; }; then
    echo "❌ Helm 3.10+ required (found: v${helm_version})"
    exit 1
  fi

  if [ "${IS_ARM_CLUSTER}" = true ]; then
    if ! command -v skopeo &>/dev/null; then
      echo "❌ skopeo required for ARM plugin install"
      echo "  brew install skopeo"
      exit 1
    fi
    if ! command -v gh &>/dev/null; then
      echo "❌ gh CLI required for CI artifact download"
      echo "  brew install gh && gh auth login"
      exit 1
    fi
    if ! gh auth status &>/dev/null 2>&1; then
      echo "❌ gh CLI not authenticated"
      echo "  gh auth login"
      exit 1
    fi
  fi

  echo "✓ Prerequisites met"
}

# ---------------------------------------------------------------------------
# Namespace setup (mirrors portal addon pattern)
# ---------------------------------------------------------------------------

grant_apme_sccs() {
  if command -v oc &>/dev/null; then
    oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${APME_NAMESPACE}" 2>/dev/null || true
    oc adm policy add-scc-to-group privileged "system:serviceaccounts:${APME_NAMESPACE}" 2>/dev/null || true
    return
  fi

  for scc_name in anyuid privileged; do
    local crb_name="system:openshift:scc:${scc_name}:${APME_NAMESPACE}"
    if ! kubectl get clusterrolebinding "$crb_name" &>/dev/null; then
      kubectl create clusterrolebinding "$crb_name" \
        --clusterrole="system:openshift:scc:${scc_name}" \
        --group="system:serviceaccounts:${APME_NAMESPACE}" 2>/dev/null || true
    fi
  done
}

copy_pull_secret_to_apme_namespace() {
  if ! kubectl get secret redhat-operators-pull-secret -n "$AAP_NAMESPACE" &>/dev/null; then
    return 0
  fi

  mkdir -p "$APME_DIR"
  chmod 700 "$APME_DIR"
  kubectl get secret redhat-operators-pull-secret -n "$AAP_NAMESPACE" \
    -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d >"$APME_DIR/pull-secret.json" || return 0
  chmod 600 "$APME_DIR/pull-secret.json"

  kubectl delete secret redhat-operators-pull-secret -n "$APME_NAMESPACE" 2>/dev/null || true
  kubectl create secret generic redhat-operators-pull-secret \
    --from-file=.dockerconfigjson="$APME_DIR/pull-secret.json" \
    --type=kubernetes.io/dockerconfigjson \
    -n "$APME_NAMESPACE" 2>/dev/null || true
}

setup_apme_namespace() {
  echo "Setting up APME namespace: $APME_NAMESPACE"

  kubectl create namespace "$APME_NAMESPACE" 2>/dev/null || true
  kubectl label namespace "$APME_NAMESPACE" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged --overwrite 2>/dev/null || true

  grant_apme_sccs
  copy_pull_secret_to_apme_namespace

  echo "✓ APME namespace ready"
}

# ---------------------------------------------------------------------------
# AAP credentials (mirrors portal addon)
# ---------------------------------------------------------------------------

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

  if ! curl -k -u "admin:$ADMIN_PASS" "https://$AAP_ROUTE/api/gateway/v1/ping/" \
    --max-time 10 &>/dev/null; then
    echo "❌ Cannot reach AAP at https://$AAP_ROUTE"
    exit 1
  fi

  echo "✓ AAP accessible at: $AAP_ROUTE"
}

select_organization() {
  echo "Selecting AAP organization..."

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
      -d '{"name": "Default", "description": "Default organization for APME"}' \
      2>/dev/null)
    ORG_ID=$(echo "$create_response" | jq -r '.id')
    ORG_NAME="Default"
  else
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

  mkdir -p "$APME_DIR"
  chmod 700 "$APME_DIR"
  local oauth_credentials_file="$APME_DIR/oauth_credentials.json"

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

    if [ -f "$oauth_credentials_file" ]; then
      local saved_id saved_secret
      saved_id=$(jq -r '.oauth_app_id // empty' "$oauth_credentials_file")
      saved_secret=$(jq -r '.client_secret // empty' "$oauth_credentials_file")
      if [ "$saved_id" = "$OAUTH_APP_ID" ] && [ -n "$saved_secret" ]; then
        CLIENT_SECRET="$saved_secret"
        echo "Using saved OAuth client secret for existing app..."
      fi
    fi

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

  jq -n \
    --arg oauth_app_id "$OAUTH_APP_ID" \
    --arg client_id "$CLIENT_ID" \
    --arg client_secret "$CLIENT_SECRET" \
    '{oauth_app_id: $oauth_app_id, client_id: $client_id, client_secret: $client_secret}' \
    >"$oauth_credentials_file"
  chmod 600 "$oauth_credentials_file"

  echo "$OAUTH_APP_ID" >"$APME_DIR/oauth_app_id"
  chmod 600 "$APME_DIR/oauth_app_id"

  echo "✓ OAuth app ready (ID: $OAUTH_APP_ID)"
}

enable_oauth_tokens() {
  echo "Enabling OAuth token creation for external users..."

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
      \"description\": \"APME backend catalog access\",
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

get_aap_host_url() {
  if [ "${IS_MICROSHIFT:-false}" = true ]; then
    # nip.io route resolves to 127.0.0.1 inside pods — use internal cluster service
    local svc_name
    svc_name=$(kubectl get route aap -n "$AAP_NAMESPACE" \
      -o jsonpath='{.spec.to.name}' 2>/dev/null || echo "aap")
    echo "http://${svc_name}.${AAP_NAMESPACE}.svc"
  else
    echo "https://${AAP_ROUTE}"
  fi
}

create_aap_secrets() {
  echo "Creating AAP credentials secret..."

  local aap_host_url
  aap_host_url=$(get_aap_host_url)

  kubectl delete secret secrets-rhaap-portal -n "$APME_NAMESPACE" &>/dev/null || true

  kubectl create secret generic secrets-rhaap-portal \
    -n "$APME_NAMESPACE" \
    --from-literal=aap-host-url="$aap_host_url" \
    --from-literal=oauth-client-id="$CLIENT_ID" \
    --from-literal=oauth-client-secret="$CLIENT_SECRET" \
    --from-literal=aap-token="$API_TOKEN"

  echo "✓ AAP credentials secret created"
  echo "✓ AAP host URL: $aap_host_url"
}

# ---------------------------------------------------------------------------
# Placeholder secrets (required by RHDH Helm chart — real values optional)
# ---------------------------------------------------------------------------

create_placeholder_secrets() {
  # secrets-scm — SCM OAuth tokens for remediate/PR flows
  if ! kubectl get secret secrets-scm -n "$APME_NAMESPACE" &>/dev/null; then
    kubectl create secret generic secrets-scm \
      -n "$APME_NAMESPACE" \
      --from-literal=github-oauth-client-id="${APME_GITHUB_OAUTH_CLIENT_ID:-placeholder}" \
      --from-literal=github-oauth-client-secret="${APME_GITHUB_OAUTH_CLIENT_SECRET:-placeholder}" \
      --from-literal=gitlab-oauth-client-id="${APME_GITLAB_OAUTH_CLIENT_ID:-placeholder}" \
      --from-literal=gitlab-oauth-client-secret="${APME_GITLAB_OAUTH_CLIENT_SECRET:-placeholder}" \
      --from-literal=github-token="${APME_GITHUB_TOKEN:-placeholder}" \
      --from-literal=gitlab-token="${APME_GITLAB_TOKEN:-placeholder}" \
      --from-literal=github-app-id="${APME_GITHUB_APP_ID:-placeholder}" \
      --from-literal=github-app-client-id="${APME_GITHUB_APP_CLIENT_ID:-placeholder}" \
      --from-literal=github-app-client-secret="${APME_GITHUB_APP_CLIENT_SECRET:-placeholder}" \
      --from-literal=github-app-private-key="${APME_GITHUB_APP_PRIVATE_KEY:-placeholder}"
    echo "  ✓ Created secrets-scm (placeholder values — set APME_GITHUB_* / APME_GITLAB_* env vars for real values)"
  else
    echo "  ✓ secrets-scm exists"
  fi
}

# ---------------------------------------------------------------------------
# Helm values
# ---------------------------------------------------------------------------

create_helm_values() {
  echo "Creating Helm values file..."
  mkdir -p "$APME_DIR"

  if [ "${IS_ARM_CLUSTER}" = true ]; then
    # ARM: community RHDH with APME appConfig (no engine/gateway — no arm64 images)
    cat >"$APME_DIR/values.yaml" <<EOF
redhat-developer-hub:
  global:
    clusterRouterBase: ${CLUSTER_BASE_URL}
    pluginMode: oci
    imageTagInfo: "${DEFAULT_PLUGIN_VERSION}"
  upstream:
    backstage:
      image:
        registry: ${DEFAULT_RHDH_REGISTRY}
        repository: ${DEFAULT_RHDH_REPOSITORY}
        tag: "${DEFAULT_RHDH_TAG}"
      appConfig:
        ansible:
          rhaap:
            checkSSL: false
          apme:
            enabled: true
            baseUrl: "${APME_BASE_URL:-https://apme-gateway-${APME_NAMESPACE}.${CLUSTER_BASE_URL}}"
            checkSSL: false
            mockMode: true
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
    echo "✓ Helm values created (ARM profile — community RHDH)"
    echo "  RHDH: ${DEFAULT_RHDH_REGISTRY}/${DEFAULT_RHDH_REPOSITORY}:${DEFAULT_RHDH_TAG}"
    return
  fi

  # x86: full APME Helm chart, portal provides the RHDH UI layer
  cat >"$APME_DIR/values.yaml" <<EOF
ui:
  enabled: false
EOF
  echo "✓ Helm values created (x86 profile — full APME chart)"
}

# ---------------------------------------------------------------------------
# Helm install / upgrade
# ---------------------------------------------------------------------------

install_helm_chart() {
  echo "Installing APME Helm chart..."

  if [ "${IS_ARM_CLUSTER}" = true ]; then
    # ARM: use portal chart with community RHDH image
    local release="$RHDH_RELEASE_NAME"
    local chart="$RHDH_CHART_REPO"

    if ! helm repo list 2>/dev/null | grep -q "^openshift-helm-charts"; then
      echo "Adding OpenShift Helm Charts repository..."
      helm repo add openshift-helm-charts https://charts.openshift.io/
    fi
    timeout 30 helm repo update &>/dev/null || true

    # kubectl patches to dynamic-plugins conflict with helm server-side apply
    kubectl delete configmap "${release}-dynamic-plugins" \
      -n "$APME_NAMESPACE" --ignore-not-found 2>/dev/null || true

    # --wait is intentionally omitted on ARM: RHDH needs the in-cluster plugin registry
    # to complete init-container startup, but that registry is deployed after helm returns.
    # Readiness is enforced by wait_for_apme (kubectl rollout status) after registry setup.
    # Long-term fix: embed in-cluster registry URL in values.yaml so helm install --wait works.
    if helm list -n "$APME_NAMESPACE" 2>/dev/null | grep -q "^${release}"; then
      echo "Upgrading existing Helm release..."
      helm upgrade "$release" "$chart" \
        -n "$APME_NAMESPACE" \
        -f "$APME_DIR/values.yaml" \
        --hide-notes
    else
      echo "Installing Helm release..."
      helm install "$release" "$chart" \
        -n "$APME_NAMESPACE" \
        -f "$APME_DIR/values.yaml" \
        --hide-notes
    fi
  else
    # x86: APME Helm chart
    local release="$APME_RELEASE_NAME"
    local chart="$APME_CHART_REPO"

    if ! helm repo list 2>/dev/null | grep -q "^apme"; then
      echo "Adding APME Helm repository..."
      helm repo add apme https://ansible.github.io/apme
    fi
    timeout 30 helm repo update &>/dev/null || true

    if helm list -n "$APME_NAMESPACE" 2>/dev/null | grep -q "^${release}"; then
      echo "Upgrading existing Helm release..."
      helm upgrade "$release" "$chart" \
        -n "$APME_NAMESPACE" \
        -f "$APME_DIR/values.yaml" \
        ${APME_CHART_VERSION:+--version "$APME_CHART_VERSION"} \
        --timeout=300s --wait \
        --hide-notes
    else
      echo "Installing Helm release..."
      helm install "$release" "$chart" \
        -n "$APME_NAMESPACE" \
        -f "$APME_DIR/values.yaml" \
        ${APME_CHART_VERSION:+--version "$APME_CHART_VERSION"} \
        --timeout=300s --wait \
        --hide-notes
    fi
  fi

  echo "✓ APME Helm chart installed"
}

# ---------------------------------------------------------------------------
# ARM: CI plugin download → in-cluster registry → configmap patch
# ---------------------------------------------------------------------------

download_ci_plugins() {
  echo "Downloading CI plugin artifacts..."

  local cache_file="${APME_DIR}/plugins-oci.tar.gz"
  local cache_id_file="${APME_DIR}/plugins-artifact-id"

  if [ -f "$cache_file" ] && [ -f "$cache_id_file" ]; then
    if [ "$(cat "$cache_id_file" 2>/dev/null)" = "$CI_ARTIFACT_ID" ]; then
      echo "✓ CI plugins cached (artifact ${CI_ARTIFACT_ID}, $(du -h "$cache_file" | cut -f1))"
      return 0
    fi
  fi

  echo "  Downloading artifact ${CI_ARTIFACT_ID} from ${CI_REPO}..."
  echo "  (run ${CI_RUN_ID} — override with CI_ARTIFACT_ID env var)"

  local tmp_dir="${APME_DIR}/artifact-$$"
  local tmp_dl="${APME_DIR}/artifact-$$.dl"
  mkdir -p "$APME_DIR" "$tmp_dir"

  # Get download URL and token separately — curl handles redirect properly for binary
  local download_url gh_token
  download_url=$(gh api "/repos/${CI_REPO}/actions/artifacts/${CI_ARTIFACT_ID}" \
    --jq '.archive_download_url' 2>/dev/null || true)
  gh_token=$(gh auth token 2>/dev/null || true)

  if [ -z "$download_url" ] || [ -z "$gh_token" ]; then
    echo "❌ Could not get download URL or auth token for artifact ${CI_ARTIFACT_ID}"
    echo "  Check: gh auth status"
    rm -rf "$tmp_dir" "$tmp_dl"
    exit 1
  fi

  echo "  Fetching ${download_url}..."
  if ! curl -fsSL \
      -H "Authorization: Bearer ${gh_token}" \
      -H "Accept: application/vnd.github+json" \
      "$download_url" \
      -o "$tmp_dl"; then
    echo "❌ Download failed"
    rm -rf "$tmp_dir" "$tmp_dl"
    exit 1
  fi

  # GitHub wraps artifacts in zip. Detect and handle both zip-wrapped and direct tar.gz.
  local oci_file=""
  local file_type file_size
  file_type=$(file "$tmp_dl" 2>/dev/null)
  file_size=$(du -h "$tmp_dl" 2>/dev/null | cut -f1)
  echo "  Downloaded: ${file_size} — ${file_type}"

  # Check gzip BEFORE zip — "gzip" contains substring "zip", order matters
  if echo "$file_type" | grep -qiE "gzip|tar"; then
    oci_file="$tmp_dl"
  elif echo "$file_type" | grep -qi "zip"; then
    echo "  Extracting zip..."
    if ! unzip -o "$tmp_dl" -d "$tmp_dir" 2>&1; then
      echo "❌ Failed to extract artifact zip"
      rm -rf "$tmp_dir" "$tmp_dl"
      exit 1
    fi
    oci_file=$(find "$tmp_dir" -name "*.tar.gz" | head -1)
    echo "  Extracted: ${oci_file:-none found}"
  fi

  if [ -z "$oci_file" ]; then
    echo "❌ Unexpected artifact format: ${file_type}"
    echo "  Contents: $(find "$tmp_dir" -type f 2>/dev/null | head -10)"
    rm -rf "$tmp_dir" "$tmp_dl"
    exit 1
  fi

  if ! cp "$oci_file" "$cache_file"; then
    echo "❌ Failed to cache plugin artifact to ${cache_file}" >&2
    rm -rf "$tmp_dir" "$tmp_dl"
    exit 1
  fi
  echo "$CI_ARTIFACT_ID" > "$cache_id_file"
  rm -rf "$tmp_dir" "$tmp_dl"

  echo "✓ CI plugins downloaded ($(du -h "$cache_file" | cut -f1))"
}

deploy_plugin_registry() {
  echo "Deploying in-cluster plugin registry..."

  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: plugin-registry
  namespace: ${APME_NAMESPACE}
  labels:
    app: plugin-registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: plugin-registry
  template:
    metadata:
      labels:
        app: plugin-registry
    spec:
      containers:
      - name: registry
        image: docker.io/library/registry:2
        ports:
        - containerPort: 5000
        env:
        - name: REGISTRY_STORAGE_DELETE_ENABLED
          value: "true"
---
apiVersion: v1
kind: Service
metadata:
  name: plugin-registry
  namespace: ${APME_NAMESPACE}
spec:
  selector:
    app: plugin-registry
  ports:
  - port: 5000
    targetPort: 5000
  type: ClusterIP
EOF

  echo "  Waiting for registry pod..."
  kubectl rollout status deployment/plugin-registry -n "$APME_NAMESPACE" --timeout=120s
  echo "✓ Plugin registry running"
}

push_plugins_to_registry() {
  echo "Pushing CI plugins to in-cluster registry..."

  local cache_file="${APME_DIR}/plugins-oci.tar.gz"
  local pf_port=15000

  kubectl port-forward svc/plugin-registry "${pf_port}:5000" -n "$APME_NAMESPACE" &
  local pf_pid=$!
  trap 'kill "$pf_pid" 2>/dev/null || true; exit 1' INT TERM

  local attempts=0
  while ! curl -sf "http://localhost:${pf_port}/v2/" &>/dev/null; do
    sleep 1
    attempts=$((attempts + 1))
    if [ $attempts -ge 20 ]; then
      echo "❌ Port-forward to plugin registry timed out"
      kill "$pf_pid" 2>/dev/null || true
      exit 1
    fi
  done

  echo "  Pushing OCI image ($(du -h "$cache_file" | cut -f1))..."

  local push_ok=false
  if skopeo copy \
      "oci-archive:${cache_file}" \
      "docker://localhost:${pf_port}/apme-plugins:${CI_PLUGIN_IMAGE_TAG}" \
      --dest-tls-verify=false 2>&1; then
    push_ok=true
  elif skopeo copy \
      "oci-archive:${cache_file}:${CI_PLUGIN_IMAGE_TAG}" \
      "docker://localhost:${pf_port}/apme-plugins:${CI_PLUGIN_IMAGE_TAG}" \
      --dest-tls-verify=false 2>&1; then
    push_ok=true
  fi

  kill "$pf_pid" 2>/dev/null || true
  trap - INT TERM

  if [ "$push_ok" = false ]; then
    echo "❌ Failed to push plugins to in-cluster registry"
    exit 1
  fi

  echo "✓ Plugins pushed to plugin-registry.${APME_NAMESPACE}.svc:5000"
}

create_plugin_registry_secret() {
  echo "Creating registry auth secret for init container..."

  local secret_name="${RHDH_RELEASE_NAME}-dynamic-plugins-registry-auth"
  local registry_host="plugin-registry.${APME_NAMESPACE}.svc:5000"

  # This secret is mounted at $HOME/.config/containers/ inside the
  # install-dynamic-plugins init container. skopeo reads registries.conf
  # from there to trust the insecure in-cluster HTTP registry.
  kubectl create secret generic "$secret_name" \
    --from-literal=registries.conf="$(printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "$registry_host")" \
    -n "$APME_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "✓ Registry auth secret created (insecure HTTP for ${registry_host})"
}

patch_plugin_configmap() {
  echo "Patching dynamic-plugins configmap..."

  local cm="${RHDH_RELEASE_NAME}-dynamic-plugins"
  local registry_host="plugin-registry.${APME_NAMESPACE}.svc:5000"
  local registry_img="oci://${registry_host}/apme-plugins:${CI_PLUGIN_IMAGE_TAG}!"
  local old_img="oci://registry.redhat.io/ansible-automation-platform/automation-portal:${DEFAULT_PLUGIN_VERSION}!"

  local plugins_yaml
  plugins_yaml=$(kubectl get cm "$cm" -n "$APME_NAMESPACE" \
    -o jsonpath='{.data.dynamic-plugins\.yaml}' 2>/dev/null || true)

  if [ -z "$plugins_yaml" ]; then
    echo "⚠️  dynamic-plugins configmap not found — skipping patch"
    return 0
  fi

  # Replace all registry.redhat.io OCI plugin references with in-cluster registry
  local escaped_old_img
  escaped_old_img=$(printf '%s' "$old_img" | sed 's/\./\\./g')
  plugins_yaml=$(printf '%s' "$plugins_yaml" | \
    sed "s|${escaped_old_img}|${registry_img}|g")

  # Helper: append a YAML block with guaranteed leading newline
  _append_plugin() {
    local block="$1"
    # Ensure plugins_yaml ends with exactly one newline before appending
    plugins_yaml="${plugins_yaml%$'\n'}"$'\n'"${block}"$'\n'
  }

  # Disable plugins from dynamic-plugins.default.yaml that require paths not in community RHDH image
  local quay_pkg="./dynamic-plugins/dist/backstage-community-plugin-scaffolder-backend-module-quay-dynamic"
  if ! printf '%s' "$plugins_yaml" | grep -qF "$quay_pkg"; then
    _append_plugin "- disabled: true"$'\n'"  package: '${quay_pkg}'"
    echo "  ✓ Disabled quay scaffolder plugin (not in community RHDH image)"
  fi

  # Append new APME-specific plugins if not already present
  for plugin in \
      "ansible-backstage-plugin-catalog-backend-module-apme" \
      "ansible-plugin-backstage-apme"; do
    local pkg="${registry_img}${plugin}"
    if ! printf '%s' "$plugins_yaml" | grep -qF "$pkg"; then
      _append_plugin "- disabled: false"$'\n'"  integrity: ''"$'\n'"  package: '${pkg}'"
    fi
  done

  kubectl create configmap "$cm" \
    --from-literal="dynamic-plugins.yaml=${plugins_yaml}" \
    -n "$APME_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "✓ Plugin configmap updated — 6 CI plugins via ${registry_host}"
}


label_dynamic_plugins_pvc() {
  local pvc_names
  pvc_names=$(kubectl get pvc -n "$APME_NAMESPACE" --no-headers -o custom-columns=":metadata.name" \
    2>/dev/null | grep dynamic-plugins || true)

  if [ -z "$pvc_names" ]; then
    return 0
  fi

  while IFS= read -r pvc_name; do
    if kubectl label pvc "$pvc_name" -n "$APME_NAMESPACE" \
        "apme.io/artifact-id=${CI_ARTIFACT_ID}" --overwrite 2>&1; then
      echo "✓ Labeled PVC $pvc_name with artifact ${CI_ARTIFACT_ID}"
    else
      echo "⚠️  Failed to label PVC $pvc_name"
    fi
  done <<< "$pvc_names"
}

restart_rhdh_deployment() {
  echo "Restarting RHDH deployment to apply patches..."

  local deploy="${RHDH_RELEASE_NAME}-rhaap-portal"

  if ! kubectl rollout restart deployment/"$deploy" -n "$APME_NAMESPACE" &>/dev/null; then
    echo "⚠️  Failed to restart RHDH deployment"
    return 1
  fi

  echo "✓ RHDH deployment restarted"
}

# ---------------------------------------------------------------------------
# OAuth redirect URI (mirrors portal addon — patches after route exists)
# ---------------------------------------------------------------------------

update_oauth_redirect() {
  if [ "${IS_ARM_CLUSTER}" != true ]; then
    return 0
  fi

  echo "Updating OAuth redirect URI..."

  local rhdh_route
  rhdh_route=$(kubectl get route "${RHDH_RELEASE_NAME}-rhaap-portal" \
    -n "$APME_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)

  if [ -z "$rhdh_route" ]; then
    rhdh_route=$(kubectl get route -n "$APME_NAMESPACE" \
      -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
  fi

  if [ -z "$rhdh_route" ]; then
    echo "⚠️  Failed to get RHDH route — OAuth redirect URI not updated"
    echo "   Manual fix: set redirect_uris to https://<rhdh-route>/api/auth/rhaap/handler/frame"
    return 1
  fi

  local redirect_uri="https://$rhdh_route/api/auth/rhaap/handler/frame"

  curl -k -u "admin:$ADMIN_PASS" \
    -X PATCH "https://$AAP_ROUTE/api/gateway/v1/applications/$OAUTH_APP_ID/" \
    -H "Content-Type: application/json" \
    -d "{\"redirect_uris\": \"$redirect_uri\"}" \
    &>/dev/null

  echo "✓ OAuth redirect URI updated: $redirect_uri"
}

# ---------------------------------------------------------------------------
# Wait for readiness
# ---------------------------------------------------------------------------

wait_for_apme() {
  if [ "${IS_ARM_CLUSTER}" = true ]; then
    echo "Waiting for RHDH (APME plugins) to become ready..."
    local deploy="${RHDH_RELEASE_NAME}-rhaap-portal"

    # Stream init container logs so plugin-by-plugin progress is visible
    kubectl logs -n "$APME_NAMESPACE" \
      -l "app.kubernetes.io/name=${RHDH_RELEASE_NAME}" \
      -c install-dynamic-plugins --follow 2>/dev/null &
    local log_pid=$!

    if ! kubectl rollout status deployment/"$deploy" \
        -n "$APME_NAMESPACE" --timeout=360s; then
      echo "⚠️  RHDH deployment not ready after 360s — check: kubectl get pods -n $APME_NAMESPACE"
    else
      echo "✓ APME ready"
    fi
    kill "$log_pid" 2>/dev/null || true
    return 0
  fi

  # x86: wait for gateway rollout
  echo "Waiting for APME gateway to become ready..."
  local label="app.kubernetes.io/component=gateway"
  local deploy
  deploy=$(kubectl get deployment -n "$APME_NAMESPACE" -l "$label" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [ -n "$deploy" ]; then
    if ! kubectl rollout status deployment/"$deploy" \
        -n "$APME_NAMESPACE" --timeout=300s; then
      echo "⚠️  APME not ready after 300s — continuing"
      echo "   Check status: kubectl get pods -n $APME_NAMESPACE"
    else
      echo "✓ APME ready"
    fi
  else
    echo "⚠️  No gateway deployment found — check: kubectl get deployments -n $APME_NAMESPACE"
  fi
}

# ---------------------------------------------------------------------------
# Success output
# ---------------------------------------------------------------------------

display_success() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [ "${IS_ARM_CLUSTER}" = true ]; then
    local rhdh_route
    rhdh_route="https://$(kubectl get route -n "$APME_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "${RHDH_RELEASE_NAME}-rhaap-portal-${APME_NAMESPACE}.${CLUSTER_BASE_URL}")"
    echo "✅ APME deployed (ARM profile — community RHDH + CI APME plugins)"
    echo ""
    echo "  RHDH URL: $rhdh_route"
    echo ""
    echo "  Plugins loaded from CI artifacts (artifact ${CI_ARTIFACT_ID}):"
    echo "    - ansible-plugin-scaffolder-backend-module-backstage-rhaap"
    echo "    - ansible-backstage-plugin-catalog-backend-module-rhaap"
    echo "    - ansible-plugin-backstage-self-service"
    echo "    - ansible-backstage-plugin-auth-backend-module-rhaap-provider"
    echo "    - ansible-backstage-plugin-catalog-backend-module-apme"
    echo "    - ansible-plugin-backstage-apme"
    echo ""
    echo "  To use newer CI artifacts, re-run with:"
    echo "    CI_ARTIFACT_ID=<id> aap-demo enable apme"
    echo ""
    echo "  Status:   kubectl get pods -n $APME_NAMESPACE"
    echo "  Logs:     kubectl logs -n $APME_NAMESPACE -l app.kubernetes.io/name=${RHDH_RELEASE_NAME}"
    echo "  Init:     kubectl logs -n $APME_NAMESPACE -l app.kubernetes.io/name=${RHDH_RELEASE_NAME} -c install-dynamic-plugins"
  else
    local gateway_url="http://apme-gateway.${APME_NAMESPACE}.svc:8080"
    echo "✅ APME deployed successfully!"
    echo ""
    echo "  Gateway URL (cluster-internal): $gateway_url"
    echo ""
    echo "  Portal Integration"
    echo ""
    echo "  Add these values to your portal Helm release:"
    echo ""
    echo "  redhat-developer-hub:"
    echo "    upstream:"
    echo "      backstage:"
    echo "        extraEnvVars:"
    echo "          - name: APME_BASE_URL"
    echo "            value: $gateway_url"
    echo "        appConfig:"
    echo "          ansible:"
    echo "            apme:"
    echo "              enabled: true"
    echo "              baseUrl: \${APME_BASE_URL}"
    echo "              checkSSL: false"
    echo "              mockMode: false"
    echo ""
    echo "  Dynamic plugins (manual step — obtain from CI artifacts):"
    echo "    - ansible-backstage-plugin-catalog-backend-module-apme"
    echo "    - ansible-plugin-backstage-apme"
    echo ""
    echo "  See: https://github.com/ansible/apme (Step 2: Install RHDH plugins)"
    echo ""
    echo "  Status:   kubectl get pods -n $APME_NAMESPACE"
    echo "  Logs:     kubectl logs -n $APME_NAMESPACE -l app.kubernetes.io/component=gateway"
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  check_prerequisites
  setup_apme_namespace
  get_aap_credentials
  select_organization
  create_oauth_app
  enable_oauth_tokens
  create_api_token
  create_aap_secrets
  create_placeholder_secrets
  create_helm_values
  # Start CI plugin download in background — no cluster dependency, runs in parallel with Helm
  local download_pid=""
  if [ "${IS_ARM_CLUSTER}" = true ]; then
    download_ci_plugins &
    download_pid=$!
  fi
  install_helm_chart
  if [ "${IS_ARM_CLUSTER}" = true ]; then
    wait "$download_pid"
    deploy_plugin_registry
    push_plugins_to_registry
    create_plugin_registry_secret
    patch_plugin_configmap
    restart_rhdh_deployment
  fi
  wait_for_apme
  if [ "${IS_ARM_CLUSTER}" = true ]; then
    label_dynamic_plugins_pvc
  fi
  update_oauth_redirect
  display_success
}

main
