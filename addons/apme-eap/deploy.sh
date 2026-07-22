#!/usr/bin/env bash
# APME Playbook Addon - Deploy Ansible Portal with Ansible Quality (APME)
# Uses official APME EAP welcome pack playbooks executed locally in isolated venv
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

# Addon contract: deploy.sh [deploy|--delete]

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

setup_venv() {
  # Create venv with full Ansible suite + collections for local playbook execution

  if [ ! -d "$VENV_DIR" ]; then
    info "Creating Python venv with Ansible and collections..."
    python3 -m venv "$VENV_DIR"
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"

    pip install --quiet --upgrade pip
    pip install --quiet -r "${SCRIPT_DIR}/requirements.txt"

    # Install Ansible collections
    ansible-galaxy collection install -r "${SCRIPT_DIR}/requirements.yml"

    info "Venv created at $VENV_DIR (~150MB)"
  else
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"

    # Upgrade dependencies if requirements changed
    info "Upgrading venv dependencies..."
    pip install --quiet --upgrade -r "${SCRIPT_DIR}/requirements.txt"
    ansible-galaxy collection install -r "${SCRIPT_DIR}/requirements.yml" --force
  fi
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

  # Check python3
  if ! command -v python3 &>/dev/null; then
    die "python3 not found. Please install Python 3.8 or later."
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

# OCI registry configuration (MicroShift doesn't have integrated registry)
# oci_registry: External URL for local skopeo push (runs outside cluster)
oci_registry: "registry.${CLUSTER_DOMAIN}/apme"
# oci_registry_internal: Internal service URL for pods to pull images
# Note: No http:// prefix - registries.conf handles the insecure flag
oci_registry_internal: "registry.aap-demo-registry.svc.cluster.local:5000/apme"
skip_plugin_push: false
apme_oci_push_force: false  # Set true to re-push plugins even if registry has them

# Architecture (informational)
# cluster_arch: ${ARCH}
EOF

  info "Vars file generated successfully"
  info "To configure GitHub integration, edit: $VARS_FILE"
}

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

deploy() {
  info "Deploying APME using official welcome pack playbooks..."

  # Set environment for kubernetes.core modules
  export K8S_AUTH_KUBECONFIG="${KUBECONFIG:-${HOME}/.crc/machines/crc/kubeconfig}"
  export ANSIBLE_ROLES_PATH="${SCRIPT_DIR}/playbooks/roles"

  # Run main deployment playbook directly
  ansible-playbook "${SCRIPT_DIR}/playbooks/deploy_apme_portal.yml" \
    -e "@${VARS_FILE}" \
    -e "@${SCRIPT_DIR}/defaults.yml"

  if [ $? -eq 0 ]; then
    info "APME deployment completed successfully"
    show_routes
  else
    error "APME deployment failed. Check playbook output above."
    exit 1
  fi
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
    info "  URL: https://${apme_route}"
    info "  Uses AAP OAuth - login via AAP credentials"
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

cleanup() {
  info "Removing APME namespace and resources..."

  # Delete namespace
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true

  # Remove generated vars file
  if [ -f "$VARS_FILE" ]; then
    rm -f "$VARS_FILE"
  fi

  info "APME cleanup complete"
  info "To fully remove the venv: rm -rf $VENV_DIR"
}

# ---------------------------------------------------------------------------
# Main Execution
# ---------------------------------------------------------------------------

case "$ACTION" in
  deploy|--deploy)
    check_prerequisites
    detect_architecture
    discover_environment
    generate_vars_file
    setup_venv
    deploy
    ;;

  --delete|delete|remove)
    cleanup
    ;;

  *)
    echo "Usage: $0 [deploy|--delete]"
    echo "  deploy   - Deploy APME using official welcome pack playbooks (local execution)"
    echo "  --delete - Remove APME namespace and resources"
    exit 1
    ;;
esac
