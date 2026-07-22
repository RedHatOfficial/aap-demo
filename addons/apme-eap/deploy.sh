#!/usr/bin/env bash
# APME Playbook Addon - Deploy Ansible Portal with Ansible Quality (APME)
# Uses AAP REST API to execute official APME EAP welcome pack playbooks
#
# ADDON_REQUIRES_AAP=true

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-deploy}"
NAMESPACE="apme"
VARS_FILE="$HOME/.aap-demo/apme-eap-vars.yml"
VENV_DIR="$HOME/.aap-demo/apme-eap-venv"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}INFO:${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
error() { echo -e "${RED}ERROR:${NC} $*" >&2; }
die() { error "$*"; exit 1; }

# No longer need bash API helpers - using Ansible playbooks!

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

setup_minimal_venv() {
  # Create minimal venv with Ansible for API interaction via ansible.builtin.uri
  # Much cleaner than bash+curl for REST API calls!

  if [ ! -d "$VENV_DIR" ]; then
    info "Creating Python venv with Ansible..."
    python3 -m venv "$VENV_DIR"
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
    pip install --quiet --upgrade pip
    pip install --quiet ansible-core
    info "Venv created at $VENV_DIR"
  fi

  # Activate venv for this session
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
}

check_prerequisites() {
  info "Checking system prerequisites..."

  # Check kubectl
  if ! command -v kubectl &>/dev/null; then
    die "kubectl not found. Please install kubectl or oc."
  fi

  # Check cluster connectivity
  if ! kubectl cluster-info &>/dev/null; then
    die "kubectl not connected to a cluster. Run 'aap-demo create' first."
  fi

  # Check jq for JSON parsing
  if ! command -v jq &>/dev/null; then
    die "jq not found. Install with: brew install jq (macOS) or your package manager"
  fi

  # Check python3 for YAML to JSON conversion
  if ! command -v python3 &>/dev/null; then
    die "python3 not found. Please install Python 3.8 or later."
  fi

  # Setup minimal venv with PyYAML (no Ansible - playbooks run in AAP!)
  setup_minimal_venv

  info "Checking AAP deployment..."

  # Check for AAP controller
  if ! kubectl get automationcontroller -n aap-operator &>/dev/null; then
    die "AAP not deployed. Run 'aap-demo deploy' first."
  fi

  # Ensure the in-cluster registry addon is deployed — APME uses it to store
  # plugin OCI images that the portal init container pulls at runtime.
  if ! kubectl get deployment registry -n aap-demo-registry &>/dev/null; then
    info "In-cluster registry not found — deploying registry addon..."
    bash "${SCRIPT_DIR}/../registry/deploy.sh"
  else
    info "In-cluster registry already running"
  fi

  info "Prerequisites check complete"
}

# ---------------------------------------------------------------------------
# Environment Discovery
# ---------------------------------------------------------------------------

detect_architecture() {
  local arch
  arch=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo "unknown")

  case "$arch" in
    amd64|x86_64)
      echo "x86"
      ;;
    arm64|aarch64)
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
    if [ -f "$HOME/.crc/machines/crc/kubeconfig" ]; then
      export KUBECONFIG="$HOME/.crc/machines/crc/kubeconfig"
      info "Using KUBECONFIG: $KUBECONFIG"
    else
      warn "KUBECONFIG not set and default CRC kubeconfig not found"
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
  info "AAP admin password retrieved"

  # 7. Architecture
  ARCH=$(detect_architecture)
  info "Cluster architecture: $ARCH"
}

# ---------------------------------------------------------------------------
# Vars File Generation
# ---------------------------------------------------------------------------

generate_vars_file() {
  info "Generating playbook vars file: $VARS_FILE"

  mkdir -p "$(dirname "$VARS_FILE")"

  # Extract token from kubeconfig for API authentication (optional)
  # The playbooks will use KUBECONFIG env var if token not available
  local openshift_token
  openshift_token=$(kubectl config view --minify --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null || echo "")

  cat > "$VARS_FILE" <<EOF
---
# Auto-generated by aap-demo enable apme-eap
# Do not edit directly — regenerated on each deploy
# Generated at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

# OpenShift (discovered from aap-demo environment)
openshift_api_url: "${OPENSHIFT_API_URL}"
openshift_project_name: ${NAMESPACE}
openshift_cluster_domain: "${CLUSTER_DOMAIN}"
openshift_validate_certs: false
# Token extracted from kubeconfig (if available)
$(if [ -n "$openshift_token" ]; then echo "openshift_token: \"${openshift_token}\""; else echo "# openshift_token not available - using KUBECONFIG"; fi)

# AAP (discovered from aap-operator namespace)
aap_host: "${AAP_HOST}"
aap_username: admin
aap_password: "${AAP_PASSWORD}"
aap_organization: Default

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

# GitHub secrets (manual configuration required for repository integration)
configure_github_secrets: false
# To enable GitHub integration:
# 1. Create GitHub OAuth App and GitHub App (see README.md)
# 2. Edit this file and uncomment the following lines:
# github_oauth_client_id: ""
# github_oauth_client_secret: ""
# github_app_id: ""
# github_app_client_id: ""
# github_app_client_secret: ""
# github_app_private_key_path: "/path/to/private-key.pem"
# github_token: ""
# 3. Set configure_github_secrets: true above

# OCI push configuration
apme_oci_push_force: false  # Set true to re-push plugins even if registry has them

# Architecture (informational)
# cluster_arch: ${ARCH}
EOF

  info "Vars file generated successfully"
  info "To configure GitHub integration, edit: $VARS_FILE"
}

# ---------------------------------------------------------------------------
# Deploy via AAP API (using Ansible playbooks)
# ---------------------------------------------------------------------------

ensure_aap_token() {
  # Check if token already exists
  local api_token
  api_token=$(kubectl get secret aap-api-token -n aap-operator -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")

  if [ -n "$api_token" ]; then
    info "Using existing API token from secret" >&2
    echo "$api_token"
    return 0
  fi

  # Token doesn't exist - create it automatically
  info "API token not found. Creating new token..." >&2

  # Get AAP gateway admin password (not controller password!)
  local admin_password
  admin_password=$(kubectl get secret aap-admin-password -n aap-operator -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")

  if [ -z "$admin_password" ]; then
    error "Could not retrieve AAP admin password"
    exit 1
  fi

  # Export credentials for playbook
  export AAP_USERNAME="admin"
  export AAP_PASSWORD="$admin_password"

  # Run playbook to create token (redirect output to stderr to keep stdout clean)
  ansible-playbook "${SCRIPT_DIR}/playbooks/create_aap_token.yml" >&2

  if [ $? -ne 0 ]; then
    error "Failed to create API token"
    exit 1
  fi

  # Retrieve newly created token
  api_token=$(kubectl get secret aap-api-token -n aap-operator -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")

  if [ -z "$api_token" ]; then
    error "Token creation succeeded but could not retrieve token from secret"
    exit 1
  fi

  echo "$api_token"
}

deploy() {
  info "Deploying APME via AAP REST API (using Ansible)..."

  # Get AAP configuration
  local aap_route
  aap_route=$(kubectl get route -n aap-operator -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

  if [ -z "$aap_route" ]; then
    die "AAP route not found. Is AAP deployed?"
  fi

  local aap_host="https://$aap_route"

  # Export for token creation playbook
  export AAP_HOST="$aap_host"

  local aap_token
  aap_token=$(ensure_aap_token)

  # Export for Ansible playbooks
  export AAP_HOST="$aap_host"
  export AAP_TOKEN="$aap_token"
  export APME_VARS_FILE="$VARS_FILE"

  # Step 1: Setup AAP resources (Project, Inventory, Job Template)
  info "Setting up AAP resources (Project, Inventory, Job Template)..."
  ansible-playbook "${SCRIPT_DIR}/playbooks/setup_aap_resources.yml" -v

  if [ $? -ne 0 ]; then
    error "Failed to setup AAP resources"
    exit 1
  fi

  # Step 2: Launch APME deployment job
  info ""
  info "Launching APME deployment job in AAP..."
  ansible-playbook "${SCRIPT_DIR}/playbooks/launch_apme_deployment.yml" -v

  if [ $? -eq 0 ]; then
    # Get APME portal route if it exists
    local apme_route
    apme_route=$(kubectl get route -n "$NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "APME deployed successfully via AAP!"
    info ""

    if [ -n "$apme_route" ]; then
      info "APME Portal Access:"
      info "  URL: https://${apme_route}"
      info "  Uses AAP OAuth - login via AAP credentials"
      info ""
    fi

    info "AAP Controller Access:"
    info "  URL: ${aap_host}"
    info "  Username: admin"
    info "  Password: (stored in secret aap-admin-password)"
    info ""
    info "Next steps:"
    info "  1. Verify deployment: kubectl get pods -n $NAMESPACE"
    info "  2. View job in AAP: ${aap_host}/#/jobs/playbook/"
    info ""
    info "To check status: aap-demo status"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  else
    error "Deployment failed. Check AAP UI for job details: ${aap_host}/#/jobs/"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Delete
# ---------------------------------------------------------------------------

delete() {
  info "Uninstalling APME..."

  if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    info "Deleting namespace: $NAMESPACE"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    info "Namespace deleted"
  else
    warn "Namespace $NAMESPACE does not exist (already deleted?)"
  fi

  if [ -f "$VARS_FILE" ]; then
    info "Removing vars file: $VARS_FILE"
    rm -f "$VARS_FILE"
  fi

  # Optionally remove venv
  if [ -d "$VENV_DIR" ]; then
    info "Minimal venv still exists at: $VENV_DIR"
    info "To remove: rm -rf $VENV_DIR"
  fi

  info "APME uninstalled successfully"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  if [ "$ACTION" = "--delete" ]; then
    delete
  else
    check_prerequisites
    discover_environment
    generate_vars_file
    deploy
  fi
}

main
