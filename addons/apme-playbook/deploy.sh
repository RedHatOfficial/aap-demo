#!/usr/bin/env bash
# APME Playbook Addon - Deploy Ansible Portal with Ansible Quality (APME)
# Uses official APME EAP welcome pack playbooks adapted for aap-demo
#
# ADDON_REQUIRES_AAP=true

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-deploy}"
NAMESPACE="apme"
VARS_FILE="$HOME/.aap-demo/apme-playbook-vars.yml"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}INFO:${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
error() { echo -e "${RED}ERROR:${NC} $*" >&2; }
die() { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

check_prerequisites() {
  info "Checking prerequisites..."

  # Check kubectl
  if ! command -v kubectl &>/dev/null; then
    die "kubectl not found. Please install kubectl or oc."
  fi

  # Check cluster connectivity
  if ! kubectl cluster-info &>/dev/null; then
    die "kubectl not connected to a cluster. Run 'aap-demo create' first."
  fi

  # Check ansible-playbook
  if ! command -v ansible-playbook &>/dev/null; then
    die "ansible-playbook not found. Install with: pip install ansible"
  fi

  # Check Ansible version
  local ansible_version
  ansible_version=$(ansible-playbook --version | head -1 | awk '{print $2}')
  info "Found ansible-playbook $ansible_version"

  # Check Ansible collections
  if ! ansible-galaxy collection list | grep -q "kubernetes.core"; then
    warn "kubernetes.core collection not found"
    info "Installing required collections..."
    ansible-galaxy collection install -r "$SCRIPT_DIR/requirements.yml"
  fi

  if ! ansible-galaxy collection list | grep -q "community.okd"; then
    warn "community.okd collection not found"
    info "Installing required collections..."
    ansible-galaxy collection install -r "$SCRIPT_DIR/requirements.yml"
  fi

  # Check helm
  if ! command -v helm &>/dev/null; then
    die "helm not found. Install with: brew install helm (macOS) or see https://helm.sh/docs/intro/install/"
  fi

  # Check skopeo
  if ! command -v skopeo &>/dev/null; then
    die "skopeo not found. Install with: brew install skopeo (macOS)"
  fi

  # Check oc (optional, but recommended)
  if ! command -v oc &>/dev/null; then
    warn "oc CLI not found (kubectl will be used instead)"
  fi

  info "All prerequisites satisfied"
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
  AAP_PASSWORD=$(kubectl get secret -n aap-operator "${AAP_CR_NAME}" -o jsonpath='{.data.admin_password}' 2>/dev/null | base64 -d || echo "")
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

  cat > "$VARS_FILE" <<EOF
---
# Auto-generated by aap-demo enable apme-playbook
# Do not edit directly — regenerated on each deploy
# Generated at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

# OpenShift (discovered from aap-demo environment)
openshift_api_url: "${OPENSHIFT_API_URL}"
openshift_project_name: ${NAMESPACE}
openshift_cluster_domain: "${CLUSTER_DOMAIN}"
openshift_validate_certs: false

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
# Deploy
# ---------------------------------------------------------------------------

deploy() {
  info "Deploying APME via Ansible playbooks..."

  cd "$SCRIPT_DIR"

  # Run the playbook
  ansible-playbook playbooks/deploy_apme_portal.yml \
    -e "@$VARS_FILE" \
    -e "@${SCRIPT_DIR}/defaults.yml" \
    -v

  if [ $? -eq 0 ]; then
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "APME deployed successfully!"
    info ""
    info "Next steps:"
    info "  1. Verify deployment: kubectl get pods -n $NAMESPACE"
    info "  2. Get portal route: kubectl get route -n $NAMESPACE"
    info "  3. Configure GitHub integration (optional):"
    info "     - Edit: $VARS_FILE"
    info "     - See: ${SCRIPT_DIR}/README.md"
    info ""
    info "To check status: aap-demo status"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  else
    error "Playbook execution failed"
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
