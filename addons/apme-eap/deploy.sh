#!/usr/bin/env bash
# APME Playbook Addon - Deploy Ansible Portal with Ansible Quality (APME)
# Orchestrates deployment via AAP job templates (Product Demos execution environment).
#
# ADDON_REQUIRES_AAP=true

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../includes/aap-demo-paths.sh
source "${SCRIPT_DIR}/../../includes/aap-demo-paths.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
ACTION="${1:-deploy}"
NAMESPACE="apme"
AAP_NAMESPACE="${AAP_NAMESPACE:-aap-operator}"
IS_MICROSHIFT=false
AAP_HOST_URL=""
VARS_FILE="$HOME/.aap-demo/apme-eap-vars.yml"
PARAMS_FILE="$HOME/.aap-demo/apme-eap-params.env"
TLS_DIR="$HOME/.aap-demo/apme-eap-tls"
GITHUB_CREDS_FILE="$HOME/.aap-demo/apme-eap-github-creds.yml"
VENV_DIR="$HOME/.aap-demo/apme-eap-venv"
PORTAL_HUB_IMAGE="${PORTAL_HUB_IMAGE:-quay.io/cferman/portal-hub-eap:latest}"
APME_PROJECT_NAME="${APME_PROJECT_NAME:-aap-demo-apme}"
APME_EE_NAME="${APME_EE_NAME:-Product Demos EE}"
APME_EE_IMAGE="${APME_EE_IMAGE:-quay.io/ansible-product-demos/apd-ee-26:latest}"
APME_JOB_TEMPLATE_NAME="${APME_JOB_TEMPLATE_NAME:-APME | Deploy Portal}"
APME_DEPLOY_PLAYBOOK="addons/apme-eap/playbooks/deploy_apme_portal.yml"
GALAXY_TOKEN_FILE="$HOME/.aap-demo/galaxy-token"
PAH_CONFIG_FILE="$HOME/.aap-demo/pah-config.yml"
OPENSHIFT_DEPLOY_TOKEN=""

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}INFO:${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
error() { echo -e "${RED}ERROR:${NC} $*" >&2; }
die() {
  error "$*"
  exit 1
}

_load_github_creds_from_file() {
  local creds_file="$1"
  [ -f "$creds_file" ] || return 1

  if ! python3 -c "import yaml" 2>/dev/null; then
    return 2
  fi

  while IFS='=' read -r key value; do
    [ -z "$key" ] && continue
    case "$key" in
      GITHUB_TOKEN) GITHUB_TOKEN="$value" ;;
      GITHUB_APP_ID) GITHUB_APP_ID="$value" ;;
      GITHUB_APP_CLIENT_ID) GITHUB_APP_CLIENT_ID="$value" ;;
      GITHUB_APP_CLIENT_SECRET) GITHUB_APP_CLIENT_SECRET="$value" ;;
      GITHUB_APP_PRIVATE_KEY_PATH) GITHUB_APP_PRIVATE_KEY_PATH="$value" ;;
      GITHUB_OAUTH_CLIENT_ID) GITHUB_OAUTH_CLIENT_ID="$value" ;;
      GITHUB_OAUTH_CLIENT_SECRET) GITHUB_OAUTH_CLIENT_SECRET="$value" ;;
    esac
  done < <(
    python3 - "$creds_file" <<'PY'
import sys
import yaml

with open(sys.argv[1]) as handle:
    data = yaml.safe_load(handle) or {}

# Field names only — values loaded at runtime from user creds file
mapping = {
    "github_token": "GITHUB_TOKEN",  # pragma: allowlist secret
    "github_app_id": "GITHUB_APP_ID",
    "github_app_client_id": "GITHUB_APP_CLIENT_ID",
    "github_app_client_secret": "GITHUB_APP_CLIENT_SECRET",  # pragma: allowlist secret
    "github_app_private_key_path": "GITHUB_APP_PRIVATE_KEY_PATH",  # pragma: allowlist secret
    "github_oauth_client_id": "GITHUB_OAUTH_CLIENT_ID",
    "github_oauth_client_secret": "GITHUB_OAUTH_CLIENT_SECRET",  # pragma: allowlist secret
}

for yaml_key, env_key in mapping.items():
    value = data.get(yaml_key)
    if value is not None and str(value).strip():
        print(f"{env_key}={value}")
PY
  )

  [ -n "${GITHUB_TOKEN:-}" ] && return 0
  return 1
}

_load_github_creds_from_file_legacy() {
  local creds_file="$1"
  local existing_token val var env_name
  existing_token=$(grep -E '^github_token:' "$creds_file" 2>/dev/null | sed 's/^github_token:[[:space:]]*//' | tr -d '"' || echo "")
  [ -n "$existing_token" ] || return 1
  GITHUB_TOKEN="$existing_token"
  for var in github_app_id github_app_client_id github_app_client_secret github_app_private_key_path github_oauth_client_id github_oauth_client_secret; do
    val=$(grep -E "^${var}:" "$creds_file" 2>/dev/null | sed "s/^${var}:[[:space:]]*//" | tr -d '"' || echo "")
    if [ -n "$val" ]; then
      env_name=$(echo "$var" | tr '[:lower:]' '[:upper:]')
      printf -v "$env_name" '%s' "$val"
    fi
  done
  return 0
}

_pod_watcher() {
  local ns="$1" interval="${2:-30}"
  sleep 15
  while true; do
    local pods
    pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null || true)
    if [ -n "$pods" ]; then
      local total ready
      total=$(echo "$pods" | wc -l | tr -d ' ')
      ready=$(echo "$pods" | grep -c 'Running\|Completed' || true)
      echo -e "\n${GREEN}[pod-status $(date +%H:%M:%S)]${NC} ${ns}: ${ready}/${total} pods running"
      echo "$pods" | grep -v 'Running\|Completed' | while IFS= read -r line; do
        [ -n "$line" ] && echo -e "  ${YELLOW}${line}${NC}"
      done
    fi
    sleep "$interval"
  done
}

_watcher_pid=""
_stop_pod_watcher() {
  [ -n "$_watcher_pid" ] || return 0
  kill "$_watcher_pid" 2>/dev/null || true
  wait "$_watcher_pid" 2>/dev/null || true
  _watcher_pid=""
}

# Addon contract: deploy.sh [deploy|--delete]

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

setup_minimal_venv() {
  # Minimal venv for optional local bootstrap playbooks (ansible-core only)
  if [ -d "$VENV_DIR" ] && { [ ! -x "$VENV_DIR/bin/python3" ] || [ ! -x "$VENV_DIR/bin/pip" ]; }; then
    warn "APME venv at $VENV_DIR is incomplete — recreating..."
    rm -rf "$VENV_DIR"
  fi

  if [ ! -d "$VENV_DIR" ]; then
    info "Creating minimal Python venv (ansible-core)..."
    python3 -m venv "$VENV_DIR"
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
    pip install --quiet --upgrade pip
    pip install --quiet 'ansible-core>=2.15' PyYAML
    info "Minimal venv created at $VENV_DIR (~50MB)"
  else
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
  fi
}

check_prerequisites() {
  info "Checking system prerequisites..."

  if ! command -v kubectl &>/dev/null; then
    die "kubectl not found. Please install kubectl or oc."
  fi

  if ! kubectl cluster-info &>/dev/null; then
    die "kubectl not connected to a cluster. Run 'aap-demo create' first."
  fi

  if ! command -v python3 &>/dev/null; then
    die "python3 not found. Please install Python 3.8 or later."
  fi

  if ! command -v curl &>/dev/null; then
    die "curl not found. Required for AAP REST API orchestration."
  fi

  if ! command -v jq &>/dev/null; then
    die "jq not found. Install: brew install jq (macOS) or sudo dnf install jq (RHEL/Fedora)"
  fi

  info "Using pre-built portal hub (${PORTAL_HUB_IMAGE})"
  info "Deployment runs in AAP via Product Demos EE (${APME_EE_IMAGE})"

  info "Prerequisites check complete"
}

# ---------------------------------------------------------------------------
# Environment Discovery
# ---------------------------------------------------------------------------

detect_architecture() {
  local arch
  arch=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo "unknown")

  case "$arch" in
    amd64 | x86_64)
      echo "x86"
      ;;
    arm64 | aarch64)
      echo "arm"
      ;;
    *)
      die "Unknown architecture: $arch"
      ;;
  esac
}

discover_environment() {
  info "Discovering aap-demo environment..."

  # 1. KUBECONFIG
  if [ -z "${KUBECONFIG:-}" ]; then
    KUBECONFIG="$(aap_demo_resolve_kubeconfig)"
    export KUBECONFIG
    if [ -f "$KUBECONFIG" ]; then
      info "Using KUBECONFIG: $KUBECONFIG"
    else
      warn "KUBECONFIG not set and aap-demo kubeconfig not found at $AAP_DEMO_KUBECONFIG"
    fi
  fi

  # 2. OpenShift API URL
  OPENSHIFT_API_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
  if [ -z "$OPENSHIFT_API_URL" ]; then
    die "Could not determine OpenShift API URL from kubeconfig"
  fi
  info "OpenShift API: $OPENSHIFT_API_URL"

  # 3. Cluster domain (from console route or any route)
  CLUSTER_DOMAIN=$(kubectl get route -n openshift-console console -o jsonpath='{.spec.host}' 2>/dev/null | sed 's/^console-openshift-console\.//' || echo "")
  if [ -z "$CLUSTER_DOMAIN" ]; then
    # Fallback: try to get from AAP route
    CLUSTER_DOMAIN=$(kubectl get route -n aap-operator -o jsonpath='{.items[0].spec.host}' 2>/dev/null | sed 's/^[^.]*\.//' || echo "apps.crc.testing")
  fi
  info "Cluster domain: $CLUSTER_DOMAIN"

  # 4. AAP route
  AAP_ROUTE=$(kubectl get route -n aap-operator -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  if [ -z "$AAP_ROUTE" ]; then
    die "AAP route not found. Deploy AAP first with 'aap-demo deploy'"
  fi
  AAP_HOST="https://${AAP_ROUTE}"

  # MicroShift lacks ingresses.config — portal backend OAuth needs http:// in-cluster
  if [ -z "$(kubectl get ingresses.config/cluster -o jsonpath='{.spec.domain}' --request-timeout=5s 2>/dev/null || true)" ]; then
    IS_MICROSHIFT=true
    AAP_HOST_URL="http://${AAP_ROUTE}"
  else
    IS_MICROSHIFT=false
    AAP_HOST_URL="${AAP_HOST}"
  fi

  info "AAP host: $AAP_HOST"
  if [ "$IS_MICROSHIFT" = true ]; then
    info "AAP in-cluster host URL (portal OAuth): $AAP_HOST_URL"
  fi

  # 5. AAP CR name
  AAP_CR_NAME=$(kubectl get aap -n aap-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -z "$AAP_CR_NAME" ]; then
    die "AAP CR not found in aap-operator namespace"
  fi

  # 6. AAP admin password
  AAP_PASSWORD=$(kubectl get secret -n aap-operator "${AAP_CR_NAME}-admin-password" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
  if [ -z "$AAP_PASSWORD" ]; then
    die "Could not retrieve AAP admin password from secret"
  fi
  info "AAP admin password retrieved"

  # 7. Architecture
  ARCH=$(detect_architecture)
  info "Cluster architecture: $ARCH"
}

# ---------------------------------------------------------------------------
# Host pre-steps (setup-pah, credential discovery)
# ---------------------------------------------------------------------------

_has_pah_credentials() {
  [ -f "$GALAXY_TOKEN_FILE" ] || [ -f "$PAH_CONFIG_FILE" ]
}

run_setup_pah_prestep() {
  if ! _has_pah_credentials; then
    info "No galaxy-token or pah-config.yml — skipping setup-pah pre-step"
    APME_PAH_HAS_GALAXY_TOKEN=false
    APME_PAH_HAS_PAH_CONFIG=false
    return 0
  fi

  APME_PAH_HAS_GALAXY_TOKEN=false
  APME_PAH_HAS_PAH_CONFIG=false
  [ -f "$GALAXY_TOKEN_FILE" ] && APME_PAH_HAS_GALAXY_TOKEN=true
  [ -f "$PAH_CONFIG_FILE" ] && APME_PAH_HAS_PAH_CONFIG=true

  info "Running setup-pah on host (before AAP job)..."
  NAMESPACE="$AAP_NAMESPACE" \
    GALAXY_TOKEN_FILE="$GALAXY_TOKEN_FILE" \
    PAH_CONFIG_FILE="$PAH_CONFIG_FILE" \
    KUBECONFIG="${KUBECONFIG:-$(aap_demo_resolve_kubeconfig)}" \
    bash "${SCRIPT_DIR}/../setup-pah/deploy.sh"
}

prepare_github_key_content() {
  GITHUB_APP_PRIVATE_KEY_CONTENT=""
  if [ -n "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ] && [ -f "${GITHUB_APP_PRIVATE_KEY_PATH}" ]; then
    GITHUB_APP_PRIVATE_KEY_CONTENT=$(cat "${GITHUB_APP_PRIVATE_KEY_PATH}")
  fi
}

generate_openshift_deploy_token() {
  info "Generating OpenShift service account token for AAP job..."
  OPENSHIFT_DEPLOY_TOKEN=$(apme_create_openshift_deploy_token)
  if [ -z "$OPENSHIFT_DEPLOY_TOKEN" ]; then
    die "Failed to generate OpenShift deploy token"
  fi
  info "OpenShift deploy token generated"
}

# ---------------------------------------------------------------------------
# GitHub Token Prompt
# ---------------------------------------------------------------------------

_has_github_app_creds() {
  [ -n "${GITHUB_TOKEN:-}" ] \
    && [ -n "${GITHUB_APP_ID:-}" ] \
    && [ -n "${GITHUB_APP_CLIENT_ID:-}" ] \
    && [ -n "${GITHUB_APP_CLIENT_SECRET:-}" ] \
    && { [ -n "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ] && [ -f "${GITHUB_APP_PRIVATE_KEY_PATH}" ]; }
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

_load_pinned_secrets() {
  APME_PORTAL_DB_PASSWORD="$(_read_params_value PORTAL_DB_PASSWORD || _generate_random_secret)"
  APME_PORTAL_SESSION_SECRET="$(_read_params_value PORTAL_SESSION_SECRET || _generate_random_secret)"
  APME_ABBENAY_TOKEN="$(_read_params_value ABBENAY_TOKEN || _generate_random_secret)"
}

_load_route_tls_creds() {
  APME_ROUTE_TLS_ENABLED=false
  APME_ROUTE_TLS_TERMINATION="${ROUTE_TLS_TERMINATION:-edge}"
  APME_ROUTE_TLS_CERTIFICATE=""
  APME_ROUTE_TLS_KEY=""
  APME_ROUTE_TLS_CA_CERTIFICATE=""
  APME_ROUTE_TLS_DEST_CA_CERTIFICATE=""

  local cert_file="${ROUTE_TLS_CERT_PATH:-$TLS_DIR/tls.crt}"
  local key_file="${ROUTE_TLS_KEY_PATH:-$TLS_DIR/tls.key}"
  local ca_file="${ROUTE_TLS_CA_CERT_PATH:-$TLS_DIR/ca.crt}"
  local dest_ca_file="${ROUTE_TLS_DEST_CA_PATH:-$TLS_DIR/dest-ca.crt}"

  cert_file="${cert_file/#\~/$HOME}"
  key_file="${key_file/#\~/$HOME}"
  ca_file="${ca_file/#\~/$HOME}"
  dest_ca_file="${dest_ca_file/#\~/$HOME}"

  if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
    APME_ROUTE_TLS_ENABLED=true
    APME_ROUTE_TLS_CERTIFICATE=$(cat "$cert_file")
    APME_ROUTE_TLS_KEY=$(cat "$key_file")
    [ -f "$ca_file" ] && APME_ROUTE_TLS_CA_CERTIFICATE=$(cat "$ca_file")
    [ -f "$dest_ca_file" ] && APME_ROUTE_TLS_DEST_CA_CERTIFICATE=$(cat "$dest_ca_file")
    info "Custom Route TLS certificates loaded from ${TLS_DIR}/"
  fi
}

generate_params_file() {
  mkdir -p "$(dirname "$PARAMS_FILE")"
  cat >"$PARAMS_FILE" <<EOF
NAMESPACE=${NAMESPACE}
CLUSTER_ROUTER_BASE=${CLUSTER_DOMAIN}
RHAAP_URL=
RHAAP_OAUTH_CLIENT_ID=
RHAAP_OAUTH_CLIENT_SECRET=
RHAAP_TOKEN=
GITHUB_TOKEN=${GITHUB_TOKEN:-}
GITHUB_OAUTH_CLIENT_ID=${GITHUB_OAUTH_CLIENT_ID:-}
GITHUB_OAUTH_CLIENT_SECRET=${GITHUB_OAUTH_CLIENT_SECRET:-}
PORTAL_DB_PASSWORD=${APME_PORTAL_DB_PASSWORD}
PORTAL_SESSION_SECRET=${APME_PORTAL_SESSION_SECRET}
ABBENAY_TOKEN=${APME_ABBENAY_TOKEN}
PORTAL_IMAGE=${PORTAL_HUB_IMAGE}
EOF
  chmod 600 "$PARAMS_FILE"
}

prompt_github_token() {
  if [ -f "$GITHUB_CREDS_FILE" ]; then
    if _load_github_creds_from_file "$GITHUB_CREDS_FILE" || _load_github_creds_from_file_legacy "$GITHUB_CREDS_FILE"; then
      if [ -n "${GITHUB_TOKEN:-}" ]; then
        info "GitHub credentials found in $GITHUB_CREDS_FILE — reusing"
        return 0
      fi
    fi
  fi

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    info "Using GitHub credentials from environment variables"
    GITHUB_OAUTH_CLIENT_ID="${GITHUB_OAUTH_CLIENT_ID:-${GITHUB_APP_CLIENT_ID:-}}"
    GITHUB_OAUTH_CLIENT_SECRET="${GITHUB_OAUTH_CLIENT_SECRET:-${GITHUB_APP_CLIENT_SECRET:-}}"
    return 0
  fi

  if [ "${QUIET:-false}" = "true" ] || [ ! -t 0 ]; then
    info "Skipping GitHub configuration (set GITHUB_TOKEN=... or edit $VARS_FILE)"
    return 0
  fi

  echo ""
  info "GitHub integration (optional) — PAT for repo scans; OAuth for ScmAuth UI"
  info "GitHub App (push/PR) is documented in README Advanced section — not prompted here."
  read -r -p "Configure GitHub PAT now? [y/N]: " configure_choice
  if [[ ! "$configure_choice" =~ ^[Yy]$ ]]; then
    return 0
  fi

  read -r -s -p "GitHub PAT (repo scope): " github_token_input
  echo ""
  [ -z "$github_token_input" ] && return 0
  GITHUB_TOKEN="$github_token_input"

  read -r -p "GitHub OAuth client ID (optional, for ScmAuth): " github_oauth_id_input
  if [ -n "$github_oauth_id_input" ]; then
    GITHUB_OAUTH_CLIENT_ID="$github_oauth_id_input"
    read -r -s -p "GitHub OAuth client secret: " github_oauth_secret_input
    echo ""
    GITHUB_OAUTH_CLIENT_SECRET="$github_oauth_secret_input"
  fi

  mkdir -p "$(dirname "$GITHUB_CREDS_FILE")"
  cat >"$GITHUB_CREDS_FILE" <<CREDS
---
github_token: "${GITHUB_TOKEN}"
github_oauth_client_id: "${GITHUB_OAUTH_CLIENT_ID:-}"
github_oauth_client_secret: "${GITHUB_OAUTH_CLIENT_SECRET:-}"
CREDS
  chmod 600 "$GITHUB_CREDS_FILE"
  info "GitHub PAT/OAuth saved to $GITHUB_CREDS_FILE"
}

# ---------------------------------------------------------------------------
# Vars File Generation
# ---------------------------------------------------------------------------

generate_vars_file() {
  info "Generating playbook vars file: $VARS_FILE"
  _load_pinned_secrets
  _load_route_tls_creds
  generate_params_file

  mkdir -p "$(dirname "$VARS_FILE")"

  local configure_github_app=false
  if _has_github_app_creds; then
    configure_github_app=true
  fi

  cat >"$VARS_FILE" <<EOF
---
# Auto-generated by aap-demo enable apme-eap
# Generated at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

openshift_api_url: "${OPENSHIFT_API_URL}"
openshift_project_name: ${NAMESPACE}
openshift_cluster_domain: "${CLUSTER_DOMAIN}"
openshift_validate_certs: false

is_microshift: $([ "$IS_MICROSHIFT" = true ] && echo true || echo false)
aap_host: "${AAP_HOST}"
aap_host_url: "${AAP_HOST_URL}"
aap_username: admin
aap_password: "${AAP_PASSWORD}"

portal_helm_release_name: redhat-rhaap-portal
aap_apme_prerequisites_oauth_application_name: "APME Portal OAuth"

apme_skip_openshift_secret_creation: true
apme_template_release_name: redhat-rhaap-portal

apme_portal_db_password: "${APME_PORTAL_DB_PASSWORD}"
apme_portal_session_secret: "${APME_PORTAL_SESSION_SECRET}"
apme_abbenay_token: "${APME_ABBENAY_TOKEN}"

portal_hub_image: "${PORTAL_HUB_IMAGE}"

github_token: "${GITHUB_TOKEN:-}"
github_oauth_client_id: "${GITHUB_OAUTH_CLIENT_ID:-}"
github_oauth_client_secret: "${GITHUB_OAUTH_CLIENT_SECRET:-}"

configure_github_app_secrets: ${configure_github_app}
EOF

  if [ "$configure_github_app" = true ]; then
    cat >>"$VARS_FILE" <<EOF
github_app_id: "${GITHUB_APP_ID}"
github_app_client_id: "${GITHUB_APP_CLIENT_ID}"
github_app_client_secret: "${GITHUB_APP_CLIENT_SECRET}"
github_app_private_key_path: "${GITHUB_APP_PRIVATE_KEY_PATH}"
EOF
  fi

  cat >>"$VARS_FILE" <<EOF

apme_pah_run_setup_pah: false
apme_pah_seed_apme_galaxy_servers: true
apme_pah_collections_enabled: auto
apme_pah_aap_namespace: "${AAP_NAMESPACE}"
apme_pah_has_galaxy_token: $([ "${APME_PAH_HAS_GALAXY_TOKEN:-false}" = true ] && echo true || echo false)
apme_pah_has_pah_config: $([ "${APME_PAH_HAS_PAH_CONFIG:-false}" = true ] && echo true || echo false)

apme_route_tls_enabled: $([ "$APME_ROUTE_TLS_ENABLED" = true ] && echo true || echo false)
apme_route_tls_termination: "${APME_ROUTE_TLS_TERMINATION}"
EOF

  if [ "$APME_ROUTE_TLS_ENABLED" = true ]; then
    cat >>"$VARS_FILE" <<'TLSHDR'

apme_route_tls_certificate: |
TLSHDR
    sed 's/^/  /' <<<"${APME_ROUTE_TLS_CERTIFICATE}" >>"$VARS_FILE"
    cat >>"$VARS_FILE" <<'TLSHDR'
apme_route_tls_key: |
TLSHDR
    sed 's/^/  /' <<<"${APME_ROUTE_TLS_KEY}" >>"$VARS_FILE"
    if [ -n "${APME_ROUTE_TLS_CA_CERTIFICATE:-}" ]; then
      cat >>"$VARS_FILE" <<'TLSHDR'

apme_route_tls_ca_certificate: |
TLSHDR
      sed 's/^/  /' <<<"${APME_ROUTE_TLS_CA_CERTIFICATE}" >>"$VARS_FILE"
    fi
    if [ -n "${APME_ROUTE_TLS_DEST_CA_CERTIFICATE:-}" ]; then
      cat >>"$VARS_FILE" <<'TLSHDR'

apme_route_tls_destination_ca_certificate: |
TLSHDR
      sed 's/^/  /' <<<"${APME_ROUTE_TLS_DEST_CA_CERTIFICATE}" >>"$VARS_FILE"
    fi
  fi

  if [ -n "${GITHUB_APP_PRIVATE_KEY_CONTENT:-}" ]; then
    cat >>"$VARS_FILE" <<'KEYHDR'

github_app_private_key_content: |
KEYHDR
    sed 's/^/  /' <<<"${GITHUB_APP_PRIVATE_KEY_CONTENT}" >>"$VARS_FILE"
  fi

  chmod 600 "$VARS_FILE"
  info "Params file: $PARAMS_FILE"
  info "Vars file generated successfully"
}

# ---------------------------------------------------------------------------
# Post-deploy OAuth verification (MicroShift / CRC)
# ---------------------------------------------------------------------------

APME_PORTAL_DEPLOYMENT="${APME_PORTAL_DEPLOYMENT:-redhat-rhaap-portal}"

verify_apme_aap_host_url() {
  info "Verifying AAP host URL in portal pod..."

  local aap_host_url
  aap_host_url=$(kubectl exec "deployment/${APME_PORTAL_DEPLOYMENT}" \
    -c backstage-backend \
    -n "$NAMESPACE" \
    -- printenv AAP_HOST_URL 2>/dev/null || true)

  if [ -z "$aap_host_url" ]; then
    warn "Could not read AAP_HOST_URL from portal pod"
    return 1
  fi

  if [[ "$aap_host_url" == *".svc"* ]]; then
    error "Portal is configured with in-cluster AAP URL: $aap_host_url"
    error "Browser OAuth redirects require the external AAP route hostname."
    error "Re-run: aap-demo enable apme-eap"
    return 1
  fi

  if [ "${IS_MICROSHIFT:-false}" = true ] && [[ "$aap_host_url" == https://* ]]; then
    error "Portal AAP URL uses HTTPS on MicroShift: $aap_host_url"
    error "In-cluster OAuth token exchange requires http://<aap-route> on CRC/MicroShift."
    error "Re-run: aap-demo enable apme-eap"
    return 1
  fi

  info "AAP host URL: $aap_host_url"
  return 0
}

verify_apme_host_alias() {
  if [ "${IS_MICROSHIFT:-false}" != true ]; then
    return 0
  fi

  info "Verifying AAP route host alias in portal pod..."

  local aap_ip resolved_ip
  aap_ip=$(kubectl get svc aap -n "$AAP_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  if [ -z "$aap_ip" ]; then
    warn "Could not resolve AAP service ClusterIP; skipping host alias check"
    return 1
  fi

  resolved_ip=$(kubectl exec "deployment/${APME_PORTAL_DEPLOYMENT}" \
    -c backstage-backend \
    -n "$NAMESPACE" \
    -- getent hosts "$AAP_ROUTE" 2>/dev/null | awk '{print $1}' | head -1 || true)

  if [ -z "$resolved_ip" ]; then
    error "Portal pod cannot resolve AAP route hostname: ${AAP_ROUTE}"
    error "hostAliases may be missing — in-pod OAuth token exchange will fail."
    error "Re-run: aap-demo enable apme-eap"
    return 1
  fi

  if [ "$resolved_ip" = "127.0.0.1" ] || [ "$resolved_ip" = "::1" ]; then
    error "AAP route ${AAP_ROUTE} resolves to ${resolved_ip} inside portal pod"
    error "Expected AAP Service ClusterIP (${aap_ip}). Re-run: aap-demo enable apme-eap"
    return 1
  fi

  if [ "$resolved_ip" != "$aap_ip" ]; then
    warn "AAP route resolves to ${resolved_ip} (expected Service ClusterIP ${aap_ip})"
    return 1
  fi

  info "AAP route host alias: ${AAP_ROUTE} → ${resolved_ip}"
  return 0
}

verify_apme_oauth_reachability() {
  if [ "${IS_MICROSHIFT:-false}" != true ]; then
    return 0
  fi

  info "Verifying OAuth token endpoint reachability from portal pod..."

  local apme_route http_code
  apme_route=$(kubectl get route -n "$NAMESPACE" "${APME_PORTAL_DEPLOYMENT}" \
    -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

  http_code=$(kubectl exec "deployment/${APME_PORTAL_DEPLOYMENT}" \
    -c backstage-backend \
    -n "$NAMESPACE" \
    -- sh -c '
      AUTH=$(printf "%s:%s" "$OAUTH_CLIENT_ID" "$OAUTH_CLIENT_SECRET" | base64 -w0 2>/dev/null || printf "%s:%s" "$OAUTH_CLIENT_ID" "$OAUTH_CLIENT_SECRET" | base64)
      curl -s -o /dev/null -w "%{http_code}" -X POST "'"${AAP_HOST_URL}"'/o/token/" \
        -H "Authorization: Basic $AUTH" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=authorization_code&code=invalid&redirect_uri=https://'"${apme_route}"'/api/auth/rhaap/handler/frame"
    ' 2>/dev/null || echo "000")

  if [ "$http_code" = "000" ]; then
    error "Portal pod cannot reach AAP token endpoint at ${AAP_HOST_URL}/o/token/"
    error "On CRC/MicroShift, route hostnames may not resolve inside pods without hostAliases."
    error "Re-run: aap-demo enable apme-eap"
    return 1
  fi

  if [ "$http_code" = "401" ]; then
    error "OAuth client credentials rejected by AAP (invalid_client)"
    error "Re-run: aap-demo enable apme-eap"
    return 1
  fi

  info "OAuth token endpoint reachable (HTTP ${http_code})"
  return 0
}

verify_apme_oauth() {
  local rc=0
  verify_apme_aap_host_url || rc=1
  verify_apme_host_alias || rc=1
  verify_apme_oauth_reachability || rc=1
  return "$rc"
}

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

deploy() {
  info "Deploying APME via AAP job template (${APME_JOB_TEMPLATE_NAME})..."
  info "(pod status updates every 30s during template apply)"

  apme_init_aap_connection || die "Failed to initialize AAP connection"
  if ! apme_configure_microshift_job_networking; then
    warn "MicroShift job pod networking not configured — AAP job OAuth prerequisites may fail"
  fi

  apme_ensure_aap_resources || die "Failed to configure AAP resources"

  _pod_watcher "$NAMESPACE" 30 &
  _watcher_pid=$!
  trap '_stop_pod_watcher' EXIT

  local job_id
  job_id=$(apme_launch_job_template "${APME_JOB_TEMPLATE_ID}") || die "Failed to launch AAP job"
  apme_monitor_job "$job_id" "APME portal deploy" 120 || die "APME deployment job failed"

  _stop_pod_watcher
  trap - EXIT

  info "APME deployment completed successfully"
  local apme_route
  apme_route=$(kubectl get route -n "$NAMESPACE" redhat-rhaap-portal -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  apme_wait_for_portal_route "$apme_route" 180 || warn "Portal may still be starting — retry the URL in a minute"
  if ! verify_apme_oauth; then
    warn "OAuth verification failed — portal sign-in may not work until you re-run: aap-demo enable apme-eap"
  fi
  show_routes
}

show_routes() {
  local apme_route
  apme_route=$(kubectl get route -n "$NAMESPACE" redhat-rhaap-portal -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

  info ""
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "APME Portal deployed successfully!"
  info ""

  if [ -n "$apme_route" ]; then
    info "Portal Access:"
    info "  URL:      https://${apme_route}"
    info "  Username: admin"
    info "  Password: ${AAP_PASSWORD}"
    info ""
    info "  (Uses AAP OAuth - login with AAP admin credentials shown above)"
  else
    warn "Portal route not found yet - may still be deploying"
  fi

  info ""
  info "Verify deployment:"
  info "  kubectl get pods -n $NAMESPACE"
  info "  kubectl get route -n $NAMESPACE"
  info ""
  info "To check status: aap-demo status"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

_purge_apme_local_credentials() {
  local key_path="${GITHUB_APP_PRIVATE_KEY_PATH:-$HOME/.aap-demo/apme-github-app.pem}"

  if [ -f "$GITHUB_CREDS_FILE" ]; then
    rm -f "$GITHUB_CREDS_FILE"
    info "Removed $GITHUB_CREDS_FILE"
  fi
  if [ -n "${key_path:-}" ] && [ -f "$key_path" ]; then
    rm -f "$key_path"
    info "Removed $key_path"
  fi
}

_should_purge_apme_credentials() {
  if [ "${APME_PURGE_CREDS:-}" = "true" ] || [ "${APME_PURGE_CREDS:-}" = "1" ]; then
    return 0
  fi
  for _arg in "$@"; do
    [ "$_arg" = "--purge-creds" ] && return 0
  done
  if [ -t 0 ] && [ "${CI:-}" != "true" ]; then
    local reply=""
    read -r -p "Remove saved GitHub credentials and private key? [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]]
    return $?
  fi
  return 1
}

cleanup() {
  info "Removing APME namespace and resources..."

  # Delete namespace
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true

  # Remove generated vars file
  if [ -f "$VARS_FILE" ]; then
    rm -f "$VARS_FILE"
  fi
  if [ -f "$PARAMS_FILE" ]; then
    rm -f "$PARAMS_FILE"
  fi

  if _should_purge_apme_credentials "$@"; then
    _purge_apme_local_credentials
  else
    info "Preserved GitHub credentials (set APME_PURGE_CREDS=true or use --purge-creds to remove)"
  fi

  info "APME cleanup complete"
  info "To fully remove the venv: rm -rf $VENV_DIR"
}

# ---------------------------------------------------------------------------
# Main Execution
# ---------------------------------------------------------------------------

case "$ACTION" in
  deploy | --deploy)
    check_prerequisites
    detect_architecture
    discover_environment
    prompt_github_token
    prepare_github_key_content
    run_setup_pah_prestep
    generate_openshift_deploy_token
    generate_vars_file
    setup_minimal_venv
    deploy
    ;;

  --delete | delete | remove)
    cleanup "$@"
    ;;

  *)
    echo "Usage: $0 [deploy|--delete [--purge-creds]]"
    echo "  deploy              - Deploy APME via AAP job template (Product Demos EE)"
    echo "  --delete            - Remove APME namespace and resources (preserve GitHub creds by default)"
    echo "  --delete --purge-creds - Also remove ~/.aap-demo/apme-eap-github-creds.yml and private key"
    exit 1
    ;;
esac
