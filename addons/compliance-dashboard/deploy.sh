#!/usr/bin/env bash
# Compliance Dashboard addon — adds compliance scanning plugin to Portal
# Requires: portal addon deployed, gh CLI authenticated, skopeo
#
# Usage:
#   ./deploy.sh          # Install compliance dashboard
#   ./deploy.sh --delete # Remove compliance dashboard

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTAL_NAMESPACE="${PORTAL_NAMESPACE:-redhat-rhaap-portal}"
PORTAL_DEPLOYMENT="${PORTAL_DEPLOYMENT:-redhat-rhaap-portal}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-aap-demo-registry}"
ACTION="${1:-deploy}"

# Plugin source
PLUGIN_REPO="ansible/ansible-rhdh-plugins"
PLUGIN_BRANCH="feat/2216-compliance-pipelines"
ARTIFACT_PATTERN="early-access-plugins-feat-2216-compliance-pipelines"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}INFO:${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
error() { echo -e "${RED}ERROR:${NC} $*" >&2; }

# Check prerequisites
check_prereqs() {
  local missing=()
  command -v gh &>/dev/null || missing+=("gh")
  command -v skopeo &>/dev/null || missing+=("skopeo")
  command -v jq &>/dev/null || missing+=("jq")
  command -v kubectl &>/dev/null || missing+=("kubectl")

  if [ ${#missing[@]} -gt 0 ]; then
    error "Missing required tools: ${missing[*]}"
    exit 1
  fi

  if ! gh auth status &>/dev/null; then
    error "gh CLI not authenticated. Run: gh auth login"
    exit 1
  fi
}

# Check portal is deployed
check_portal() {
  if ! kubectl get deployment "$PORTAL_DEPLOYMENT" -n "$PORTAL_NAMESPACE" &>/dev/null; then
    error "Portal not deployed. Run: aap-demo enable portal"
    exit 1
  fi
  info "Portal deployment found"
}

# Check registry is available
check_registry() {
  if ! kubectl get svc registry -n "$REGISTRY_NAMESPACE" &>/dev/null; then
    error "Local registry not deployed. Run: aap-demo enable registry"
    exit 1
  fi
  REGISTRY_IP=$(kubectl get svc registry -n "$REGISTRY_NAMESPACE" -o jsonpath='{.spec.clusterIP}')
  REGISTRY_URL="${REGISTRY_IP}:5000"
  info "Registry found at ${REGISTRY_URL}"
}

# Download latest compliance plugin artifact
download_artifact() {
  info "Finding latest compliance plugin artifact..."

  local artifact_json
  artifact_json=$(gh api repos/${PLUGIN_REPO}/actions/artifacts \
    --jq "[.artifacts[] | select(.name | contains(\"${ARTIFACT_PATTERN}\")) | select(.name | endswith(\".oci.tar.gz\"))] | sort_by(.created_at) | reverse | .[0]")

  if [ -z "$artifact_json" ] || [ "$artifact_json" = "null" ]; then
    error "No compliance plugin artifact found in ${PLUGIN_REPO}"
    exit 1
  fi

  local artifact_id artifact_name
  artifact_id=$(echo "$artifact_json" | jq -r '.id')
  artifact_name=$(echo "$artifact_json" | jq -r '.name')

  info "Downloading: ${artifact_name}"

  WORK_DIR=$(mktemp -d)
  trap 'rm -rf "$WORK_DIR"' EXIT

  curl -sL -H "Authorization: Bearer $(gh auth token)" \
    "https://api.github.com/repos/${PLUGIN_REPO}/actions/artifacts/${artifact_id}/zip" \
    -o "${WORK_DIR}/artifact.tar.gz"

  # Extract OCI layout
  cd "$WORK_DIR"
  tar -xzf artifact.tar.gz 2>/dev/null || true

  if [ ! -f index.json ]; then
    error "Invalid artifact: missing index.json"
    exit 1
  fi

  # Get tag from index.json
  OCI_TAG=$(jq -r '.manifests[0].annotations["org.opencontainers.image.ref.name"]' index.json)
  info "OCI tag: ${OCI_TAG}"
}

# Push plugin to local registry
push_to_registry() {
  info "Pushing compliance plugin to registry..."

  # Get registry route for pushing from host
  local registry_route
  registry_route=$(kubectl get route registry -n "$REGISTRY_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

  if [ -z "$registry_route" ]; then
    error "Registry route not found"
    exit 1
  fi

  skopeo copy --dest-tls-verify=false \
    "oci:${WORK_DIR}:${OCI_TAG}" \
    "docker://${registry_route}/ansible-rhdh-plugins:compliance"

  info "Plugin pushed to ${registry_route}/ansible-rhdh-plugins:compliance"
}

# Configure insecure registry for portal
configure_insecure_registry() {
  info "Configuring insecure registry for portal..."

  # Check if already configured
  if kubectl get cm registries-conf -n "$PORTAL_NAMESPACE" &>/dev/null; then
    info "Insecure registry config already exists"
    return 0
  fi

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: registries-conf
  namespace: ${PORTAL_NAMESPACE}
data:
  registries.conf: |
    [[registry]]
    location = "${REGISTRY_URL}"
    insecure = true
EOF

  # Patch deployment to mount registries.conf
  local patch_needed=false
  if ! kubectl get deployment "$PORTAL_DEPLOYMENT" -n "$PORTAL_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.volumes[*].name}' | grep -q registries-conf; then
    patch_needed=true
  fi

  if [ "$patch_needed" = true ]; then
    kubectl patch deployment "$PORTAL_DEPLOYMENT" -n "$PORTAL_NAMESPACE" --type='json' -p='[
      {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "registries-conf", "configMap": {"name": "registries-conf"}}},
      {"op": "add", "path": "/spec/template/spec/initContainers/0/volumeMounts/-", "value": {"name": "registries-conf", "mountPath": "/etc/containers/registries.conf.d/insecure.conf", "subPath": "registries.conf"}},
      {"op": "add", "path": "/spec/template/spec/initContainers/0/env/-", "value": {"name": "CONTAINERS_REGISTRIES_CONF", "value": "/etc/containers/registries.conf.d/insecure.conf"}}
    ]'
    info "Portal deployment patched for insecure registry"
  fi
}

# Update dynamic-plugins configmap
update_dynamic_plugins() {
  info "Updating dynamic-plugins configmap..."

  local cm_name="${PORTAL_DEPLOYMENT}-dynamic-plugins"
  local current_config
  current_config=$(kubectl get cm "$cm_name" -n "$PORTAL_NAMESPACE" -o jsonpath='{.data.dynamic-plugins\.yaml}')

  # Check if compliance already configured
  if echo "$current_config" | grep -q "ansible-plugin-backstage-compliance"; then
    info "Compliance plugins already in dynamic-plugins config"
    return 0
  fi

  # Append compliance plugins
  local new_config="${current_config}
# Compliance Dashboard plugins
- disabled: false
  integrity: ''
  package: 'oci://${REGISTRY_URL}/ansible-rhdh-plugins:compliance!ansible-plugin-backstage-compliance'
  pluginConfig:
    dynamicPlugins:
      frontend:
        ansible.plugin-backstage-compliance:
          dynamicRoutes:
          - importName: CompliancePage
            path: /compliance/*
            menuItem:
              icon: security
              text: Compliance
- disabled: false
  integrity: ''
  package: 'oci://${REGISTRY_URL}/ansible-rhdh-plugins:compliance!ansible-plugin-backstage-compliance-backend'
  pluginConfig:
    dynamicPlugins:
      backend:
        ansible.plugin-backstage-compliance-backend: {}
"

  kubectl create configmap "$cm_name" \
    --from-literal="dynamic-plugins.yaml=${new_config}" \
    -n "$PORTAL_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  info "Dynamic plugins configmap updated"
}

# Update app-config configmap
update_app_config() {
  info "Updating app-config configmap..."

  local cm_name="${PORTAL_DEPLOYMENT}-app-config"
  local current_config
  current_config=$(kubectl get cm "$cm_name" -n "$PORTAL_NAMESPACE" -o jsonpath='{.data.app-config\.yaml}')

  # Check if compliance already configured
  if echo "$current_config" | grep -q "compliance:"; then
    info "Compliance config already in app-config"
    return 0
  fi

  # Insert compliance config after ansible: section
  local new_config
  new_config=$(echo "$current_config" | sed 's/^  feedback:$/  compliance:\
    enabled: true\
    dataSource: live\
    authMode: production\
  feedback:/')

  kubectl create configmap "$cm_name" \
    --from-literal="app-config.yaml=${new_config}" \
    -n "$PORTAL_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  info "App config updated with compliance settings"
}

# Restart portal
restart_portal() {
  info "Restarting portal..."
  kubectl rollout restart deployment/"$PORTAL_DEPLOYMENT" -n "$PORTAL_NAMESPACE"
  kubectl rollout status deployment/"$PORTAL_DEPLOYMENT" -n "$PORTAL_NAMESPACE" --timeout=300s
  info "Portal restarted"
}

# Get portal URL
get_portal_url() {
  local route
  route=$(kubectl get route "$PORTAL_DEPLOYMENT" -n "$PORTAL_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [ -n "$route" ]; then
    echo ""
    info "Compliance Dashboard available at:"
    info "  https://${route}/compliance"
  fi
}

# Remove compliance dashboard
cleanup() {
  info "Removing compliance dashboard..."

  # Remove from dynamic-plugins
  local cm_name="${PORTAL_DEPLOYMENT}-dynamic-plugins"
  local current_config
  current_config=$(kubectl get cm "$cm_name" -n "$PORTAL_NAMESPACE" -o jsonpath='{.data.dynamic-plugins\.yaml}' 2>/dev/null || echo "")

  if echo "$current_config" | grep -q "ansible-plugin-backstage-compliance"; then
    # Remove compliance plugin entries
    local new_config
    new_config=$(echo "$current_config" | sed '/# Compliance Dashboard plugins/,/ansible.plugin-backstage-compliance-backend: {}/d')

    kubectl create configmap "$cm_name" \
      --from-literal="dynamic-plugins.yaml=${new_config}" \
      -n "$PORTAL_NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -

    info "Removed compliance from dynamic-plugins"
  fi

  # Remove from app-config
  cm_name="${PORTAL_DEPLOYMENT}-app-config"
  current_config=$(kubectl get cm "$cm_name" -n "$PORTAL_NAMESPACE" -o jsonpath='{.data.app-config\.yaml}' 2>/dev/null || echo "")

  if echo "$current_config" | grep -q "compliance:"; then
    local new_config
    new_config=$(echo "$current_config" | sed '/^  compliance:/,/^  [a-z]/{ /^  compliance:/d; /enabled: true/d; /dataSource: live/d; /authMode: production/d; }')

    kubectl create configmap "$cm_name" \
      --from-literal="app-config.yaml=${new_config}" \
      -n "$PORTAL_NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -

    info "Removed compliance from app-config"
  fi

  # Restart portal
  kubectl rollout restart deployment/"$PORTAL_DEPLOYMENT" -n "$PORTAL_NAMESPACE" 2>/dev/null || true

  info "Compliance dashboard removed"
}

# Main
main() {
  case "$ACTION" in
    deploy | install)
      check_prereqs
      check_portal
      check_registry
      download_artifact
      push_to_registry
      configure_insecure_registry
      update_dynamic_plugins
      update_app_config
      restart_portal
      get_portal_url
      ;;
    --delete | delete | remove | uninstall)
      cleanup
      ;;
    *)
      echo "Usage: $0 [deploy|--delete]"
      exit 1
      ;;
  esac
}

main
