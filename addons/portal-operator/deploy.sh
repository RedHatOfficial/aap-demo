#!/usr/bin/env bash
# Automation Portal Operator addon.
#
# The operator is a separate AAP 2.7 Technology Preview deployment path.  It
# intentionally does not share the Helm release or namespace used by portal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_NAMESPACE="${AAP_NAMESPACE:-${NAMESPACE:-aap-operator}}"
PORTAL_OPERATOR_NAMESPACE="${PORTAL_OPERATOR_NAMESPACE:-automation-portal}"
PORTAL_OPERATOR_DIR="${HOME}/.aap-demo/portal-operator"
PORTAL_NAME="${PORTAL_NAME:-portal}"
ACTION="${1:-deploy}"

OPERATOR_PACKAGE="${PORTAL_OPERATOR_PACKAGE:-automation-portal-operator}"
OPERATOR_CHANNEL="${PORTAL_OPERATOR_CHANNEL:-fast}"
OPERATOR_SOURCE="${PORTAL_OPERATOR_SOURCE:-redhat-operators}"
OPERATOR_SOURCE_NAMESPACE="${PORTAL_OPERATOR_SOURCE_NAMESPACE:-}"

require_tools() {
  local tool
  for tool in kubectl curl jq; do
    command -v "$tool" >/dev/null 2>&1 || {
      echo "❌ Required tool not found: $tool" >&2
      exit 1
    }
  done
}

cleanup() {
  echo "Disabling portal-operator addon..."
  kubectl delete automationportal "$PORTAL_NAME" -n "$PORTAL_OPERATOR_NAMESPACE" \
    --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete subscription "$OPERATOR_PACKAGE" -n "$PORTAL_OPERATOR_NAMESPACE" \
    --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace "$PORTAL_OPERATOR_NAMESPACE" --timeout=120s \
    --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$PORTAL_OPERATOR_DIR"
  echo "Portal operator addon disabled"
}

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  cleanup
  exit 0
fi

check_aap() {
  AAP_ROUTE=$(kubectl get route aap -n "$AAP_NAMESPACE" \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [ -n "$AAP_ROUTE" ] || {
    echo "❌ AAP route not found in namespace $AAP_NAMESPACE. Run 'aap-demo deploy' first." >&2
    exit 1
  }
  ADMIN_PASS=$(kubectl get secret aap-admin-password -n "$AAP_NAMESPACE" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  [ -n "$ADMIN_PASS" ] || {
    echo "❌ AAP admin password not found" >&2
    exit 1
  }
}

setup_namespace() {
  kubectl create namespace "$PORTAL_OPERATOR_NAMESPACE" 2>/dev/null || true
  kubectl label namespace "$PORTAL_OPERATOR_NAMESPACE" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged --overwrite >/dev/null 2>&1 || true
  grant_operator_sccs_for_namespace "$PORTAL_OPERATOR_NAMESPACE"
}

grant_operator_sccs_for_namespace() {
  local namespace="$1"
  if [ "${PORTAL_OPERATOR_GRANT_SCC:-false}" != true ]; then
    echo "⚠️  CatalogSource may require SCC access in $namespace; set PORTAL_OPERATOR_GRANT_SCC=true to grant privileged SCC to its dedicated service accounts"
    return
  fi
  if command -v oc >/dev/null 2>&1; then
    oc adm policy add-scc-to-user privileged \
      -z redhat-operators -n "$namespace" >/dev/null 2>&1 || true
    oc adm policy add-scc-to-user privileged \
      -z default -n "$namespace" >/dev/null 2>&1 || true
    return
  fi
  kubectl create clusterrolebinding \
    "system:openshift:scc:privileged:${namespace}-redhat-operators" \
    --clusterrole=system:openshift:scc:privileged \
    --serviceaccount="${namespace}:redhat-operators" >/dev/null 2>&1 || true
  kubectl create clusterrolebinding \
    "system:openshift:scc:privileged:${namespace}-default" \
    --clusterrole=system:openshift:scc:privileged \
    --serviceaccount="${namespace}:default" >/dev/null 2>&1 || true
}

require_amd64_cluster() {
  local cluster_arch
  cluster_arch="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)"
  if [ -z "$cluster_arch" ]; then
    echo "❌ Could not detect cluster architecture; Automation Portal Operator requires amd64" >&2
    exit 1
  fi
  echo "✓ Cluster architecture: $cluster_arch"
  [ "$cluster_arch" = amd64 ] || {
    echo "❌ Automation Portal Operator currently supports amd64 only; detected $cluster_arch" >&2
    echo "   Use 'aap-demo enable portal' for the ARM64-compatible Helm portal path." >&2
    exit 1
  }
}

copy_catalog_source() {
  local target_namespace="$1"
  local catalog_image catalog_secret
  kubectl create namespace "$target_namespace" 2>/dev/null || true
  if kubectl get secret redhat-operators-pull-secret -n "$AAP_NAMESPACE" >/dev/null 2>&1; then
    kubectl get secret redhat-operators-pull-secret -n "$AAP_NAMESPACE" -o json \
      | jq --arg namespace "$target_namespace" \
        'del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields) | .metadata.namespace=$namespace' \
      | kubectl apply -f - >/dev/null
  fi
  catalog_image=$(kubectl get catalogsource "$OPERATOR_SOURCE" -n "$AAP_NAMESPACE" \
    -o jsonpath='{.spec.image}')
  catalog_secret=$(kubectl get catalogsource "$OPERATOR_SOURCE" -n "$AAP_NAMESPACE" \
    -o jsonpath='{.spec.secrets[0]}')
  kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${OPERATOR_SOURCE}
  namespace: ${target_namespace}
spec:
  displayName: Red Hat Operators
  publisher: Red Hat
  sourceType: grpc
  image: ${catalog_image}
  grpcPodConfig:
    securityContextConfig: restricted
  secrets:
    - ${catalog_secret}
  updateStrategy:
    registryPoll:
      interval: 10m
EOF
  grant_operator_sccs_for_namespace "$target_namespace"
}

prepare_catalog_source() {
  if [ "$AAP_NAMESPACE" != openshift-marketplace ] \
    && kubectl get catalogsource "$OPERATOR_SOURCE" -n "$AAP_NAMESPACE" >/dev/null 2>&1; then
    # The local AAP demo uses namespace-scoped catalogs. Keep each OLM
    # consumer in the namespace where its catalog is visible.
    copy_catalog_source "$PORTAL_OPERATOR_NAMESPACE"
    OPERATOR_SOURCE_NAMESPACE="$PORTAL_OPERATOR_NAMESPACE"
    return
  fi
  if kubectl get catalogsource "$OPERATOR_SOURCE" -n openshift-marketplace >/dev/null 2>&1; then
    OPERATOR_SOURCE_NAMESPACE="openshift-marketplace"
    return
  fi
  if ! kubectl get catalogsource "$OPERATOR_SOURCE" -n "$AAP_NAMESPACE" >/dev/null 2>&1; then
    echo "❌ CatalogSource $OPERATOR_SOURCE not found in $AAP_NAMESPACE or openshift-marketplace" >&2
    exit 1
  fi
  copy_catalog_source "$PORTAL_OPERATOR_NAMESPACE"
  OPERATOR_SOURCE_NAMESPACE="$PORTAL_OPERATOR_NAMESPACE"
}

prepare_rhdh_namespace() {
  local rhdh_catalog_namespace="openshift-marketplace"
  kubectl create namespace openshift-operators 2>/dev/null || true
  kubectl apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: global-operators
  namespace: openshift-operators
spec: {}
EOF
  if [ "$OPERATOR_SOURCE_NAMESPACE" != openshift-marketplace ]; then
    copy_catalog_source openshift-operators
    rhdh_catalog_namespace="openshift-operators"
  fi
  if kubectl get subscription rhdh -n openshift-operators >/dev/null 2>&1; then
    kubectl patch subscription rhdh -n openshift-operators --type=merge \
      -p "{\"spec\":{\"source\":\"${OPERATOR_SOURCE}\",\"sourceNamespace\":\"${rhdh_catalog_namespace}\"}}" \
      >/dev/null
  fi
}

install_operator() {
  if kubectl get crd automationportals.automationportal.aap.redhat.com >/dev/null 2>&1; then
    echo "✓ Automation Portal Operator CRD already installed"
    return
  fi

  if [ -z "$OPERATOR_SOURCE_NAMESPACE" ]; then
    prepare_catalog_source
  fi

  echo "Installing Automation Portal Operator ($OPERATOR_PACKAGE/$OPERATOR_CHANNEL) from $OPERATOR_SOURCE_NAMESPACE..."
  kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: automation-portal
  namespace: ${PORTAL_OPERATOR_NAMESPACE}
spec:
  targetNamespaces:
    - ${PORTAL_OPERATOR_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${OPERATOR_PACKAGE}
  namespace: ${PORTAL_OPERATOR_NAMESPACE}
spec:
  channel: ${OPERATOR_CHANNEL}
  installPlanApproval: Automatic
  name: ${OPERATOR_PACKAGE}
  source: ${OPERATOR_SOURCE}
  sourceNamespace: ${OPERATOR_SOURCE_NAMESPACE}
EOF

  for _ in $(seq 1 60); do
    kubectl get crd automationportals.automationportal.aap.redhat.com >/dev/null 2>&1 && {
      echo "✓ Automation Portal Operator installed"
      return
    }
    sleep 5
  done
  echo "❌ Operator CRD was not installed. Check the Subscription and CSV:" >&2
  echo "   kubectl get subscription,csv -n $PORTAL_OPERATOR_NAMESPACE" >&2
  exit 1
}

select_organization() {
  local orgs_json org_count response
  orgs_json=$(curl -ksu "admin:$ADMIN_PASS" \
    "https://$AAP_ROUTE/api/gateway/v1/organizations/")
  org_count=$(echo "$orgs_json" | jq -r '.count // 0')
  if [ "$org_count" -eq 0 ]; then
    response=$(curl -ksu "admin:$ADMIN_PASS" -X POST \
      "https://$AAP_ROUTE/api/gateway/v1/organizations/" \
      -H 'Content-Type: application/json' \
      -d '{"name":"Default","description":"Default organization for portal operator"}')
    ORG_ID=$(echo "$response" | jq -r '.id')
  else
    ORG_ID=$(echo "$orgs_json" | jq -r '.results[0].id')
  fi
  [ -n "${ORG_ID:-}" ] && [ "$ORG_ID" != null ] || {
    echo "❌ Failed to select an AAP organization" >&2
    exit 1
  }
}

load_github_credentials() {
  # Reuse the credential names already used by the existing APME/portal flow.
  GITHUB_TOKEN="${GITHUB_TOKEN:-}"
  GITHUB_APP_ID="${GITHUB_APP_ID:-}"
  GITHUB_APP_CLIENT_ID="${GITHUB_APP_CLIENT_ID:-}"
  GITHUB_APP_CLIENT_SECRET="${GITHUB_APP_CLIENT_SECRET:-}"
  GITHUB_APP_PRIVATE_KEY_PATH="${GITHUB_APP_PRIVATE_KEY_PATH:-}"

  local file="${GITHUB_CREDS_FILE:-${HOME}/.aap-demo/apme-eap-github-creds.yml}"
  [ -f "$file" ] || return 0
  GITHUB_TOKEN="${GITHUB_TOKEN:-$(sed -n 's/^github_token:[[:space:]]*//p' "$file" | tr -d '"' | head -1)}"
  GITHUB_APP_ID="${GITHUB_APP_ID:-$(sed -n 's/^github_app_id:[[:space:]]*//p' "$file" | tr -d '"' | head -1)}"
  GITHUB_APP_CLIENT_ID="${GITHUB_APP_CLIENT_ID:-$(sed -n 's/^github_app_client_id:[[:space:]]*//p' "$file" | tr -d '"' | head -1)}"
  GITHUB_APP_CLIENT_SECRET="${GITHUB_APP_CLIENT_SECRET:-$(sed -n 's/^github_app_client_secret:[[:space:]]*//p' "$file" | tr -d '"' | head -1)}"
  GITHUB_APP_PRIVATE_KEY_PATH="${GITHUB_APP_PRIVATE_KEY_PATH:-$(sed -n 's/^github_app_private_key_path:[[:space:]]*//p' "$file" | tr -d '"' | head -1)}"
}

create_oauth_app() {
  local name="${OAUTH_APP_NAME:-automation-portal}"
  local encoded existing count response
  encoded=$(jq -rn --arg name "$name" '$name|@uri')
  existing=$(curl -ksu "admin:$ADMIN_PASS" \
    "https://$AAP_ROUTE/api/gateway/v1/applications/?name=$encoded")
  count=$(echo "$existing" | jq -r '.count // 0')
  if [ "$count" -gt 0 ] && [ -f "$PORTAL_OPERATOR_DIR/oauth_credentials.json" ]; then
    OAUTH_APP_ID=$(echo "$existing" | jq -r '.results[0].id')
    CLIENT_ID=$(jq -r '.client_id' "$PORTAL_OPERATOR_DIR/oauth_credentials.json")
    CLIENT_SECRET=$(jq -r '.client_secret' "$PORTAL_OPERATOR_DIR/oauth_credentials.json")
    return
  fi
  if [ "$count" -gt 0 ]; then
    local old_id
    old_id=$(echo "$existing" | jq -r '.results[0].id')
    curl -ksu "admin:$ADMIN_PASS" -X DELETE \
      "https://$AAP_ROUTE/api/gateway/v1/applications/$old_id/" >/dev/null || true
  fi
  response=$(curl -ksu "admin:$ADMIN_PASS" -X POST \
    "https://$AAP_ROUTE/api/gateway/v1/applications/" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg name "$name" --argjson organization "$ORG_ID" \
      '{name:$name, organization:$organization, authorization_grant_type:"authorization-code", client_type:"confidential", redirect_uris:"https://example.com"}')")
  OAUTH_APP_ID=$(echo "$response" | jq -r '.id')
  CLIENT_ID=$(echo "$response" | jq -r '.client_id')
  CLIENT_SECRET=$(echo "$response" | jq -r '.client_secret')
  [ -n "$CLIENT_ID" ] && [ "$CLIENT_ID" != null ] || {
    echo "❌ Failed to create AAP OAuth app" >&2
    exit 1
  }
  jq -n --arg oauth_app_id "$OAUTH_APP_ID" --arg client_id "$CLIENT_ID" \
    --arg client_secret "$CLIENT_SECRET" \
    '{oauth_app_id:$oauth_app_id,client_id:$client_id,client_secret:$client_secret}' \
    >"$PORTAL_OPERATOR_DIR/oauth_credentials.json"
  chmod 600 "$PORTAL_OPERATOR_DIR/oauth_credentials.json"
}

create_credentials() {
  mkdir -p "$PORTAL_OPERATOR_DIR"
  chmod 700 "$PORTAL_OPERATOR_DIR"
  create_oauth_app
  local token_response api_token
  token_response=$(curl -ksu "admin:$ADMIN_PASS" -X POST \
    "https://$AAP_ROUTE/api/gateway/v1/tokens/" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg description 'Portal operator catalog access' '{description:$description,scope:"write"}')")
  api_token=$(echo "$token_response" | jq -r '.token // empty')
  [ -n "$api_token" ] || {
    echo "❌ Failed to generate AAP API token" >&2
    exit 1
  }

  kubectl create secret generic secrets-rhaap-portal -n "$PORTAL_OPERATOR_NAMESPACE" \
    --from-literal=aap-host-url="https://$AAP_ROUTE" \
    --from-literal=oauth-client-id="$CLIENT_ID" \
    --from-literal=oauth-client-secret="$CLIENT_SECRET" \
    --from-literal=aap-token="$api_token" --dry-run=client -o yaml | kubectl apply -f -

  load_github_credentials
  if [ "${PORTAL_GITHUB_ENABLED:-false}" = true ]; then
    local args=()
    if [ "${PORTAL_GITHUB_AUTH_TYPE:-app}" = app ]; then
      [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_CLIENT_ID:-}" ] && [ -n "${GITHUB_APP_CLIENT_SECRET:-}" ] && [ -n "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ] || {
        echo "❌ GitHub App enabled but app credentials are incomplete" >&2
        exit 1
      }
      args+=(--from-literal=github-app-id="$GITHUB_APP_ID" --from-literal=github-app-client-id="$GITHUB_APP_CLIENT_ID"
        --from-literal=github-app-client-secret="$GITHUB_APP_CLIENT_SECRET"
        --from-file=github-app-private-key="$GITHUB_APP_PRIVATE_KEY_PATH")
    else
      [ -n "${GITHUB_TOKEN:-}" ] || {
        echo "❌ GitHub token integration enabled but GITHUB_TOKEN is empty" >&2
        exit 1
      }
      args+=(--from-literal=github-token="$GITHUB_TOKEN")
    fi
    kubectl create secret generic secrets-scm -n "$PORTAL_OPERATOR_NAMESPACE" "${args[@]}" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi

  if kubectl get secret redhat-operators-pull-secret -n "$AAP_NAMESPACE" >/dev/null 2>&1; then
    kubectl get secret redhat-operators-pull-secret -n "$AAP_NAMESPACE" \
      -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d >"$PORTAL_OPERATOR_DIR/auth.json"
    kubectl create secret generic portal-registry-auth -n "$PORTAL_OPERATOR_NAMESPACE" \
      --from-file=auth.json="$PORTAL_OPERATOR_DIR/auth.json" --dry-run=client -o yaml | kubectl apply -f -
  else
    echo "⚠️  redhat-operators-pull-secret not found; create portal-registry-auth before the portal starts"
  fi
}

apply_portal() {
  local github_enabled="${PORTAL_GITHUB_ENABLED:-false}"
  local auth_type="${PORTAL_GITHUB_AUTH_TYPE:-app}"
  local sync_interval="${PORTAL_CATALOG_SYNC_INTERVAL:-60}"
  local check_ssl="${PORTAL_CHECK_SSL:-true}"
  local git_contents="${PORTAL_GIT_CONTENTS_ENABLED:-false}"
  local collections="${PORTAL_COLLECTIONS_ENABLED:-false}"
  local devtools="${PORTAL_DEVTOOLS_ENABLED:-true}"
  local integration_block=""
  if [ "$github_enabled" = true ]; then
    integration_block="  scm:\n    credentials:\n      secretRef: secrets-scm\n    github:\n      enabled: true\n      host: ${PORTAL_GITHUB_HOST:-github.com}\n      authType: ${auth_type}\n  auth:\n    providers:\n      github:\n        enabled: true\n        credentials:\n          secretRef: secrets-scm"
  fi
  kubectl apply -f - <<EOF
apiVersion: automationportal.aap.redhat.com/v1alpha1
kind: AutomationPortal
metadata:
  name: ${PORTAL_NAME}
  namespace: ${PORTAL_OPERATOR_NAMESPACE}
spec:
  aap:
    checkSSL: ${check_ssl}
    credentials:
      secretRef: secrets-rhaap-portal
$(printf '%b\n' "$integration_block")
  plugins:
    registry: ${PORTAL_PLUGIN_REGISTRY:-registry.redhat.io}
    catalog:
      syncInterval: ${sync_interval}
      jobTemplates:
        enabled: true
      collections:
        enabled: ${collections}
      gitContents:
        enabled: ${git_contents}
  devtools:
    enabled: ${devtools}
  permissions:
    enabled: true
EOF
}

wait_for_portal() {
  echo "Waiting for AutomationPortal/$PORTAL_NAME to become Running..."
  for _ in $(seq 1 120); do
    phase=$(kubectl get automationportal "$PORTAL_NAME" -n "$PORTAL_OPERATOR_NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$phase" = Running ] && break
    [ "$phase" = Failed ] && {
      kubectl describe automationportal "$PORTAL_NAME" -n "$PORTAL_OPERATOR_NAMESPACE"
      exit 1
    }
    sleep 5
  done
  [ "${phase:-}" = Running ] || {
    echo "❌ Portal did not reach Running" >&2
    exit 1
  }
  PORTAL_ROUTE=$(kubectl get route -n "$PORTAL_OPERATOR_NAMESPACE" \
    -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
  [ -n "$PORTAL_ROUTE" ] || {
    echo "❌ Portal route not found" >&2
    exit 1
  }
  curl -ksu "admin:$ADMIN_PASS" -X PATCH \
    "https://$AAP_ROUTE/api/gateway/v1/applications/$OAUTH_APP_ID/" \
    -H 'Content-Type: application/json' \
    -d "{\"redirect_uris\":\"https://$PORTAL_ROUTE/api/auth/rhaap/handler/frame\"}" >/dev/null
}

main() {
  require_tools
  kubectl cluster-info >/dev/null 2>&1 || {
    echo "❌ Cannot connect to Kubernetes" >&2
    exit 1
  }
  check_aap
  require_amd64_cluster
  setup_namespace
  [ -n "$OPERATOR_SOURCE_NAMESPACE" ] || prepare_catalog_source
  install_operator
  prepare_rhdh_namespace
  select_organization
  create_credentials
  apply_portal
  wait_for_portal
  echo "✓ Portal operator addon enabled"
  echo "Portal URL: https://$PORTAL_ROUTE"
  echo "AAP is the OIDC/OAuth provider; redirect URI updated for the deployed route."
}

main
