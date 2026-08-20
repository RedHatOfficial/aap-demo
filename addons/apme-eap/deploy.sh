#!/usr/bin/env bash
# APME Playbook Addon - Deploy Ansible Portal with Ansible Quality (APME)
# Linux/macOS: local ansible-playbook in isolated venv
# Windows (Git Bash): playbooks run as AAP Controller jobs (no local Python)
#
# ADDON_REQUIRES_AAP=true

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../includes/aap-demo-paths.sh
source "${SCRIPT_DIR}/../../includes/aap-demo-paths.sh"
ACTION="${1:-deploy}"
NAMESPACE="apme"
VARS_FILE="$HOME/.aap-demo/apme-eap-vars.yml"
GITHUB_CREDS_FILE="$HOME/.aap-demo/apme-eap-github-creds.yml"
VENV_DIR="$HOME/.aap-demo/apme-eap-venv"
PORTAL_HUB_IMAGE="${PORTAL_HUB_IMAGE:-quay.io/cferman/portal-hub-eap:latest}"

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

_use_aap_execution() {
  if [ "${APME_FORCE_LOCAL:-}" = "1" ]; then
    return 1
  fi
  if [ "${APME_USE_AAP:-}" = "1" ]; then
    return 0
  fi
  if [ "${APME_USE_AAP:-}" = "0" ]; then
    return 1
  fi
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
      return 0
      ;;
  esac
  return 1
}

_load_github_creds_from_file() {
  local creds_file="$1"
  [ -f "$creds_file" ] || return 1

  if _load_github_creds_from_file_legacy "$creds_file"; then
    return 0
  fi

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

setup_venv() {
  # Create venv with full Ansible suite + collections for local playbook execution
  local req_checksum_file="${VENV_DIR}/.requirements_checksum"
  local pip_checksum_file="${VENV_DIR}/.pip_requirements_checksum"

  if [ -d "$VENV_DIR" ] && { [ ! -x "$VENV_DIR/bin/python3" ] || [ ! -x "$VENV_DIR/bin/pip" ]; }; then
    warn "APME venv at $VENV_DIR is incomplete — recreating..."
    rm -rf "$VENV_DIR"
  fi

  if [ ! -d "$VENV_DIR" ]; then
    info "Creating Python venv with Ansible and collections..."
    python3 -m venv "$VENV_DIR"
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"

    pip install --quiet --upgrade pip
    pip install --quiet -r "${SCRIPT_DIR}/requirements.txt"
    sha256sum "${SCRIPT_DIR}/requirements.txt" >"$pip_checksum_file"

    ansible-galaxy collection install -r "${SCRIPT_DIR}/requirements.yml"
    sha256sum "${SCRIPT_DIR}/requirements.yml" >"$req_checksum_file"

    info "Venv created at $VENV_DIR (~150MB)"
  else
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"

    # Reinstall pip packages only when requirements.txt changed
    if ! sha256sum --check "$pip_checksum_file" --status 2>/dev/null; then
      info "requirements.txt changed — upgrading pip packages..."
      pip install --quiet --upgrade -r "${SCRIPT_DIR}/requirements.txt"
      sha256sum "${SCRIPT_DIR}/requirements.txt" >"$pip_checksum_file"
    else
      info "pip packages up to date (requirements.txt unchanged)"
    fi

    # Reinstall collections only when requirements.yml changed
    if ! sha256sum --check "$req_checksum_file" --status 2>/dev/null; then
      info "requirements.yml changed — reinstalling Ansible collections..."
      ansible-galaxy collection install -r "${SCRIPT_DIR}/requirements.yml" --force
      sha256sum "${SCRIPT_DIR}/requirements.yml" >"$req_checksum_file"
    else
      info "Ansible collections up to date (requirements.yml unchanged)"
    fi
  fi
}

_helm_version_ok() {
  local helm_version helm_major helm_minor
  helm_version=$(helm version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+' | sed 's/v//')
  [ -n "$helm_version" ] || return 1
  helm_major=$(echo "$helm_version" | cut -d. -f1)
  helm_minor=$(echo "$helm_version" | cut -d. -f2)
  # Require helm >= 3.10 (v4+ is also OK)
  if [ "$helm_major" -gt 3 ]; then
    return 0
  fi
  if [ "$helm_major" -eq 3 ] && [ "$helm_minor" -ge 10 ]; then
    return 0
  fi
  return 1
}

_ensure_helm() {
  # Homebrew (macOS) and common install paths — ansible playbook tasks also prepend these
  export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

  if command -v helm &>/dev/null && _helm_version_ok; then
    info "helm found: $(command -v helm) ($(helm version --short 2>/dev/null || echo 'unknown version'))"
    return 0
  fi

  if command -v helm &>/dev/null; then
    die "Helm 3.10+ required (found: $(helm version --short 2>/dev/null || echo 'unknown')). Upgrade from https://helm.sh/docs/intro/install/"
  fi

  info "helm not found — installing (required for portal Helm chart deployment)..."
  case "$(uname -s)" in
    Darwin)
      if command -v brew &>/dev/null; then
        brew install helm
      else
        die "helm not found. Install Homebrew, then: brew install helm"
      fi
      ;;
    Linux)
      if command -v dnf &>/dev/null; then
        sudo dnf install -y helm
      else
        die "helm not found and cannot auto-install. Install Helm 3.10+ from https://helm.sh/docs/intro/install/"
      fi
      ;;
    *)
      die "helm not found. Install Helm 3.10+ from https://helm.sh/docs/intro/install/"
      ;;
  esac

  if ! command -v helm &>/dev/null; then
    die "helm install completed but helm is still not on PATH"
  fi
  if ! _helm_version_ok; then
    die "Helm 3.10+ required after install (found: $(helm version --short 2>/dev/null || echo 'unknown'))"
  fi
  info "helm installed: $(command -v helm) ($(helm version --short 2>/dev/null || echo 'unknown version'))"
}

check_prerequisites() {
  info "Checking system prerequisites..."

  if ! command -v kubectl &>/dev/null; then
    die "kubectl not found. Please install kubectl or oc."
  fi

  if ! kubectl cluster-info &>/dev/null; then
    die "kubectl not connected to a cluster. Run 'aap-demo create' first."
  fi

  if _use_aap_execution; then
    info "Windows/AAP execution mode — playbooks run in AAP (no local Python required)"
    if ! command -v jq &>/dev/null; then
      die "jq is required. Install: winget install jqlang.jq"
    fi
    if ! command -v curl &>/dev/null; then
      die "curl is required for AAP API access"
    fi
    info "Prerequisites check complete"
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    die "python3 not found. Please install Python 3.8 or later (or set APME_USE_AAP=1 on Linux/macOS)."
  fi

  info "Using pre-built portal hub (${PORTAL_HUB_IMAGE})"
  _ensure_helm

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
  info "AAP host: $AAP_HOST"

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
  export AAP_PASSWORD
  info "AAP admin password retrieved"

  # 7. Architecture
  ARCH=$(detect_architecture)
  info "Cluster architecture: $ARCH"
}

# ---------------------------------------------------------------------------
# GitHub Token Prompt
# ---------------------------------------------------------------------------

prompt_github_token() {
  # Allow users to optionally provide GitHub App credentials for APME integration
  # Follows the pattern from setup-pah and portal addons

  # Check saved credentials file from a previous deploy
  if [ -f "$GITHUB_CREDS_FILE" ]; then
    if _load_github_creds_from_file "$GITHUB_CREDS_FILE" || _load_github_creds_from_file_legacy "$GITHUB_CREDS_FILE"; then
      if [ -n "${GITHUB_TOKEN:-}" ]; then
        info "GitHub credentials found in $GITHUB_CREDS_FILE — reusing"
        return 0
      fi
    fi
  fi

  # Check environment variables - any token skips the prompt
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    info "Using GitHub credentials from environment variables"
    # Default OAuth vars to App client credentials if not explicitly set
    GITHUB_OAUTH_CLIENT_ID="${GITHUB_OAUTH_CLIENT_ID:-${GITHUB_APP_CLIENT_ID:-}}"
    GITHUB_OAUTH_CLIENT_SECRET="${GITHUB_OAUTH_CLIENT_SECRET:-${GITHUB_APP_CLIENT_SECRET:-}}"
    return 0
  fi

  # Skip prompt if QUIET mode or non-interactive
  if [ "${QUIET:-false}" = "true" ] || [ ! -t 0 ]; then
    info "Skipping GitHub configuration (use GITHUB_TOKEN=... to provide, add GITHUB_APP_ID=... for full integration)"
    return 0
  fi

  echo ""
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "GitHub App Configuration (Optional)"
  info ""
  info "APME integrates with GitHub for repository scanning, quality analysis,"
  info "and code push operations directly from the portal."
  info ""
  info "Setup Instructions:"
  info ""
  info "STEP 1: Create GitHub App (https://github.com/settings/apps/new)"
  info "  GitHub App name: apme-portal-local"
  info "  Homepage URL: https://redhat-rhaap-portal-apme.apps.127.0.0.1.nip.io"
  info "  Callback URL: https://redhat-rhaap-portal-apme.apps.127.0.0.1.nip.io/api/auth/github/handler/frame"
  info "  Webhook: Uncheck 'Active'"
  info "  Repository permissions (REQUIRED):"
  info "    • Contents: Read and write"
  info "    • Pull requests: Read and write"
  info "    • Metadata: Read-only (automatically selected)"
  info "  Where can this app be installed?: Any account"
  info ""
  info "STEP 2: Generate client secret (in your new GitHub App settings)"
  info "  Navigate to: General → Client secrets"
  info "  Click: 'Generate a new client secret'"
  info "  Copy the secret immediately (you won't see it again!)"
  info ""
  info "STEP 3: Generate private key (in your GitHub App settings)"
  info "  Navigate to: General → Private keys"
  info "  Click: 'Generate a private key'"
  info "  Save the downloaded .pem file to: ~/.aap-demo/apme-github-app.pem"
  info ""
  info "STEP 4: Install the app on your account/organization"
  info "  Click: 'Install App' (left sidebar)"
  info "  Select: Your account or organization"
  info "  Repository access:"
  info "    • All repositories (recommended for testing), OR"
  info "    • Only select repositories (choose specific repos)"
  info "  Click: 'Install'"
  info ""
  info "STEP 5: Create Personal Access Token (https://github.com/settings/tokens/new)"
  info "  Note: APME Portal API Access"
  info "  Expiration: 90 days (or your preference)"
  info "  Scopes (REQUIRED):"
  info "    ☑ repo (Full control of private repositories)"
  info "      ☑ repo:status"
  info "      ☑ repo_deployment"
  info "      ☑ public_repo"
  info "      ☑ repo:invite"
  info "      ☑ security_events"
  info "  Click: 'Generate token' and copy it (starts with ghp_)"
  info ""
  info "You can skip this and configure later by editing: $VARS_FILE"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  read -r -p "Do you want to configure GitHub integration now? [y/N]: " configure_choice

  if [[ ! "$configure_choice" =~ ^[Yy]$ ]]; then
    info "Skipping GitHub integration. You can configure it later."
    return 0
  fi

  echo ""
  info "Enter GitHub App credentials:"
  info "  (Visit your GitHub App settings: https://github.com/settings/apps/<your-app-name>)"
  echo ""

  # GitHub App ID
  info "1. GitHub App ID"
  info "   Location: General → About → App ID (numeric, e.g., 123456)"
  read -r -p "   Enter App ID: " github_app_id_input
  if [ -z "$github_app_id_input" ]; then
    warn "App ID required for GitHub integration. Skipping."
    return 0
  fi

  # GitHub App Client ID
  echo ""
  info "2. GitHub App Client ID"
  info "   Location: General → About → Client ID (starts with Iv1. or Iv23.)"
  read -r -p "   Enter Client ID: " github_app_client_id_input
  if [ -z "$github_app_client_id_input" ]; then
    warn "App Client ID required. Skipping."
    return 0
  fi

  # GitHub App Client Secret
  echo ""
  info "3. GitHub App Client Secret"
  info "   Location: General → Client secrets → Generate/copy the secret"
  info "   (If you don't have one, click 'Generate a new client secret')"
  read -r -s -p "   Enter Client Secret (hidden): " github_app_client_secret_input
  echo ""
  if [ -z "$github_app_client_secret_input" ]; then
    warn "App Client Secret required. Skipping."
    return 0
  fi

  # GitHub App Private Key Path
  echo ""
  info "4. GitHub App Private Key"
  info "   Location: General → Private keys → Generate/download .pem file"
  info "   (If you don't have one, click 'Generate a private key' - file will download)"
  info "   Move the downloaded .pem file to: $HOME/.aap-demo/apme-github-app.pem"
  read -r -p "   Private key path [~/.aap-demo/apme-github-app.pem]: " github_app_private_key_input
  github_app_private_key_input="${github_app_private_key_input:-$HOME/.aap-demo/apme-github-app.pem}"

  # Expand ~ to full path
  github_app_private_key_input="${github_app_private_key_input/#\~/$HOME}"

  if [ ! -f "$github_app_private_key_input" ]; then
    warn "Private key file not found: $github_app_private_key_input"
    warn "Download the .pem file from GitHub App settings and move it to the path above."
    warn "Then re-run deployment or edit: $VARS_FILE"
    return 0
  fi

  # GitHub Personal Access Token
  echo ""
  info "5. GitHub Personal Access Token (PAT)"
  info "   Location: https://github.com/settings/tokens/new"
  info "   - Note: 'APME Portal API Access'"
  info "   - Expiration: 90 days (or your preference)"
  info "   - Scopes: Check 'repo' (full control of private repositories)"
  info "   - Generate token and copy it (starts with ghp_)"
  read -r -s -p "   Enter Personal Access Token (hidden): " github_token_input
  echo ""
  if [ -z "$github_token_input" ]; then
    warn "Personal Access Token required. Skipping."
    return 0
  fi

  GITHUB_APP_ID="$github_app_id_input"
  GITHUB_APP_CLIENT_ID="$github_app_client_id_input"
  GITHUB_APP_CLIENT_SECRET="$github_app_client_secret_input"
  GITHUB_APP_PRIVATE_KEY_PATH="$github_app_private_key_input"
  GITHUB_TOKEN="$github_token_input"

  GITHUB_OAUTH_CLIENT_ID="$github_app_client_id_input"
  GITHUB_OAUTH_CLIENT_SECRET="$github_app_client_secret_input"

  # Save credentials so future deploys skip the prompt
  mkdir -p "$(dirname "$GITHUB_CREDS_FILE")"
  cat >"$GITHUB_CREDS_FILE" <<CREDS
---
# GitHub credentials for APME portal (persisted across deploys)
github_token: "${GITHUB_TOKEN}"
github_app_id: "${GITHUB_APP_ID}"
github_app_client_id: "${GITHUB_APP_CLIENT_ID}"
github_app_client_secret: "${GITHUB_APP_CLIENT_SECRET}"
github_app_private_key_path: "${GITHUB_APP_PRIVATE_KEY_PATH}"
github_oauth_client_id: "${GITHUB_OAUTH_CLIENT_ID}"
github_oauth_client_secret: "${GITHUB_OAUTH_CLIENT_SECRET}"
CREDS
  chmod 600 "$GITHUB_CREDS_FILE"

  info "✓ GitHub App configured (saved to $GITHUB_CREDS_FILE)"
  info "  App ID: $GITHUB_APP_ID"
  info "  Private Key: $GITHUB_APP_PRIVATE_KEY_PATH"

  return 0
}

# ---------------------------------------------------------------------------
# Vars File Generation
# ---------------------------------------------------------------------------

generate_vars_file() {
  info "Generating playbook vars file: $VARS_FILE"

  mkdir -p "$(dirname "$VARS_FILE")"

  # Extract token for API and registry authentication.
  # CRC kubeconfig uses client certificate auth (no token field), so fall back
  # to the active oc session token.
  local openshift_token
  openshift_token=$(kubectl config view --minify --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null || echo "")
  if [ -z "$openshift_token" ]; then
    openshift_token=$(oc whoami -t 2>/dev/null || echo "")
  fi

  cat >"$VARS_FILE" <<EOF
---
# Auto-generated by aap-demo enable apme-eap
EOF
  chmod 600 "$VARS_FILE"
  cat >>"$VARS_FILE" <<EOF
# Do not edit directly - regenerated on each deploy
# Generated at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

# OpenShift (discovered from aap-demo environment)
openshift_api_url: "${OPENSHIFT_API_URL}"
openshift_project_name: ${NAMESPACE}
openshift_cluster_domain: "${CLUSTER_DOMAIN}"
openshift_validate_certs: false
# Token extracted from kubeconfig (if available)
$(if [ -n "$openshift_token" ]; then echo "openshift_token: \"${openshift_token}\""; else echo "# openshift_token not available - using KUBECONFIG"; fi)

# AAP (for OAuth app creation - external route for redirect)
aap_host: "${AAP_HOST}"
aap_username: admin
aap_password: "${AAP_PASSWORD}"

# Helm chart configuration (portal)
portal_helm_chart_repo: openshift-helm-charts
portal_helm_chart_repo_url: https://charts.openshift.io/
portal_helm_chart_name: redhat-rhaap-portal
portal_helm_chart_version: 2.2.3
portal_helm_release_name: redhat-rhaap-portal
portal_helm_install_timeout: 1800

# Helm chart configuration (APME gateway - x86 only)
apme_helm_chart_repo: apme
apme_helm_chart_repo_url: https://ansible.github.io/apme
apme_helm_chart_name: apme
apme_helm_chart_version: 0.1.2
apme_helm_release_name: apme

# AAP organization
aap_apme_prerequisites_oauth_application_name: "APME Portal OAuth"
EOF

  # GitHub secrets configuration
  if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_APP_ID:-}" ]; then
    # Full GitHub App configuration
    cat >>"$VARS_FILE" <<EOF

# GitHub secrets configuration (full GitHub App integration)
configure_github_secrets: true

# GitHub Personal Access Token
github_token: "${GITHUB_TOKEN}"

# GitHub OAuth configuration (for user authentication)
github_oauth_client_id: "${GITHUB_OAUTH_CLIENT_ID}"
github_oauth_client_secret: "${GITHUB_OAUTH_CLIENT_SECRET}"

# GitHub App configuration (for repository operations)
github_app_id: "${GITHUB_APP_ID}"
github_app_client_id: "${GITHUB_APP_CLIENT_ID}"
github_app_client_secret: "${GITHUB_APP_CLIENT_SECRET}"
github_app_private_key_path: "${GITHUB_APP_PRIVATE_KEY_PATH}"
EOF
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    # Token-only configuration (limited functionality)
    cat >>"$VARS_FILE" <<EOF

# GitHub secrets configuration (token-only mode)
configure_github_secrets: true
github_token: "${GITHUB_TOKEN}"

# Note: Token-only mode provides limited functionality.
# For full integration (repository push from portal), configure GitHub App:
# github_oauth_client_id: ""
# github_oauth_client_secret: ""
# github_app_id: ""
# github_app_client_id: ""
# github_app_client_secret: ""
# github_app_private_key_path: "$HOME/.aap-demo/apme-github-app.pem"
EOF
  else
    # No GitHub integration
    cat >>"$VARS_FILE" <<EOF

# GitHub secrets configuration
configure_github_secrets: false
# To enable GitHub integration, provide credentials during deployment or edit this file.
#
# Option 1: Token-only (basic scanning, no portal push)
# github_token: "ghp_..."
# configure_github_secrets: true
#
# Option 2: Full GitHub App (includes portal push, PR creation)
# github_token: "ghp_..."
# github_oauth_client_id: "Iv1...."
# github_oauth_client_secret: "..."
# github_app_id: "123456"
# github_app_client_id: "Iv1...."
# github_app_client_secret: "..."
# github_app_private_key_path: "$HOME/.aap-demo/apme-github-app.pem"
# configure_github_secrets: true
#
# Setup guide: https://github.com/settings/apps/new
EOF
  fi

  cat >>"$VARS_FILE" <<EOF

# Portal hub image (APME plugins baked in at build time)
portal_hub_image: "${PORTAL_HUB_IMAGE}"

# setup-pah / Automation Hub (reads ~/.aap-demo/galaxy-token and pah-config.yml)
apme_pah_run_setup_pah: true
apme_pah_seed_apme_galaxy_servers: true
apme_pah_collections_enabled: auto
apme_pah_aap_namespace: "${AAP_NAMESPACE:-aap-operator}"

# Architecture (informational)
# cluster_arch: ${ARCH}
EOF

  info "Vars file generated successfully"
  info "To configure GitHub integration, edit: $VARS_FILE"
}

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

deploy_via_aap() {
  # shellcheck source=lib/aap-deploy.sh
  source "${SCRIPT_DIR}/lib/aap-deploy.sh"

  export AAP_PASSWORD AAP_USERNAME="${AAP_USERNAME:-admin}"
  export AAP_NAMESPACE="${AAP_NAMESPACE:-aap-operator}"

  if [ -n "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ] && [ -f "${GITHUB_APP_PRIVATE_KEY_PATH}" ]; then
    warn "Full GitHub App mode uses a local private key path that is not available inside AAP."
    warn "Use token-only GitHub mode on Windows, or set APME_FORCE_LOCAL=1 with Python installed."
  fi

  info "Deploying APME via AAP Controller job..."
  info "(pod status updates every 30s while the job runs)"

  _pod_watcher "$NAMESPACE" 30 &
  _watcher_pid=$!
  trap '_stop_pod_watcher' EXIT

  apme_deploy_via_aap "$VARS_FILE" "${SCRIPT_DIR}/defaults.yml"

  _stop_pod_watcher
  trap - EXIT

  info "APME deployment completed successfully"
  show_routes
}

deploy_local() {
  info "Deploying APME using official welcome pack playbooks (local execution)..."
  info "(pod status updates every 30s during helm installs)"

  # Set environment for kubernetes.core modules
  export K8S_AUTH_KUBECONFIG="${KUBECONFIG:-$(aap_demo_resolve_kubeconfig)}"
  export ANSIBLE_ROLES_PATH="${SCRIPT_DIR}/playbooks/roles"

  _pod_watcher "$NAMESPACE" 30 &
  _watcher_pid=$!
  trap '_stop_pod_watcher' EXIT

  ansible-playbook "${SCRIPT_DIR}/playbooks/deploy_apme_portal.yml" \
    -e "@${SCRIPT_DIR}/defaults.yml" \
    -e "@${VARS_FILE}"

  _stop_pod_watcher
  trap - EXIT

  info "APME deployment completed successfully"
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
    ARCH=$(detect_architecture)
    discover_environment
    prompt_github_token
    generate_vars_file
    if _use_aap_execution; then
      deploy_via_aap
    else
      setup_venv
      deploy_local
    fi
    ;;

  --delete | delete | remove)
    cleanup "$@"
    ;;

  *)
    echo "Usage: $0 [deploy|--delete [--purge-creds]]"
    echo "  deploy              - Deploy APME (local ansible-playbook on Linux/macOS; AAP job on Windows)"
    echo "  --delete            - Remove APME namespace and resources (preserve GitHub creds by default)"
    echo "  --delete --purge-creds - Also remove ~/.aap-demo/apme-eap-github-creds.yml and private key"
    echo ""
    echo "Environment:"
    echo "  APME_USE_AAP=1       - Run playbooks as AAP Controller jobs (no local Python)"
    echo "  APME_FORCE_LOCAL=1   - Force local venv execution even on Windows"
    echo "  APME_PROJECT_SCM_URL - Git URL for AAP project (default: origin remote)"
    exit 1
    ;;
esac
