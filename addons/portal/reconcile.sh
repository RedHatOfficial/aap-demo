#!/usr/bin/env bash
# Portal CRD reconciler - watches Portal resources and renders Helm chart manifests
#
# Run as: ./reconcile.sh [--once]
#   --once: reconcile all existing Portals and exit
#   default: watch loop (reconcile every 30s)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_NAME="openshift-helm-charts/redhat-rhaap-portal"
RECONCILE_INTERVAL=30

reconcile_portal() {
  local portal_name="$1"
  local portal_namespace="$2"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reconciling Portal: $portal_namespace/$portal_name"

  # Get Portal spec
  local spec=$(kubectl get portal "$portal_name" -n "$portal_namespace" -o json)

  local aap_namespace=$(echo "$spec" | jq -r '.spec.aapNamespace')
  local cluster_domain=$(echo "$spec" | jq -r '.spec.clusterDomain')
  local chart_version=$(echo "$spec" | jq -r '.spec.chartVersion // "2.2.1"')
  local organization=$(echo "$spec" | jq -r '.spec.organization // "Default"')

  if [ "$aap_namespace" = "null" ] || [ "$cluster_domain" = "null" ]; then
    echo "  ERROR: Missing required fields (aapNamespace, clusterDomain)"
    kubectl patch portal "$portal_name" -n "$portal_namespace" --type=merge --subresource=status -p "{
      \"status\": {
        \"conditions\": [{
          \"type\": \"Ready\",
          \"status\": \"False\",
          \"lastTransitionTime\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
          \"reason\": \"InvalidSpec\",
          \"message\": \"Missing required fields: aapNamespace or clusterDomain\"
        }]
      }
    }" 2>/dev/null || true
    return 1
  fi

  # Get AAP route
  local aap_route=$(kubectl get route aap -n "$aap_namespace" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [ -z "$aap_route" ]; then
    echo "  ERROR: AAP route not found in namespace $aap_namespace"
    kubectl patch portal "$portal_name" -n "$portal_namespace" --type=merge --subresource=status -p "{
      \"status\": {
        \"conditions\": [{
          \"type\": \"Ready\",
          \"status\": \"False\",
          \"lastTransitionTime\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
          \"reason\": \"AAPNotFound\",
          \"message\": \"AAP route not found in namespace $aap_namespace\"
        }]
      }
    }" 2>/dev/null || true
    return 1
  fi

  # Get AAP admin credentials
  local admin_user="admin"
  local admin_pass=$(kubectl get secret aap-admin-password -n "$aap_namespace" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

  if [ -z "$admin_pass" ]; then
    echo "  ERROR: AAP admin password not found"
    return 1
  fi

  local portal_route="backstage-${portal_namespace}.${cluster_domain}"
  local redirect_uri="https://${portal_route}/api/auth/aap/handler/frame"

  echo "  Creating OAuth application in AAP..."

  # Create/update OAuth app
  local existing_app=$(curl -sk -u "${admin_user}:${admin_pass}" \
    "https://${aap_route}/api/gateway/v1/applications/?name=portal-${portal_namespace}-${portal_name}" | \
    jq -r '.results[0].id // empty' 2>/dev/null)

  local app_data
  if [ -n "$existing_app" ]; then
    app_data=$(curl -sk -u "${admin_user}:${admin_pass}" \
      -X PATCH -H "Content-Type: application/json" \
      "https://${aap_route}/api/gateway/v1/applications/${existing_app}/" \
      -d "{\"redirect_uris\": \"${redirect_uri}\"}")
  else
    app_data=$(curl -sk -u "${admin_user}:${admin_pass}" \
      -X POST -H "Content-Type: application/json" \
      "https://${aap_route}/api/gateway/v1/applications/" \
      -d "{
        \"name\": \"portal-${portal_namespace}-${portal_name}\",
        \"description\": \"Portal CR: ${portal_namespace}/${portal_name}\",
        \"client_type\": \"confidential\",
        \"authorization_grant_type\": \"authorization-code\",
        \"redirect_uris\": \"${redirect_uri}\",
        \"organization\": 1
      }")
  fi

  local client_id=$(echo "$app_data" | jq -r '.client_id')
  local client_secret=$(echo "$app_data" | jq -r '.client_secret')

  if [ -z "$client_id" ] || [ "$client_id" = "null" ]; then
    echo "  ERROR: Failed to create OAuth app"
    return 1
  fi

  echo "  OAuth app configured (Client ID: $client_id)"

  # Render Helm chart to manifests
  echo "  Rendering Helm chart manifests..."

  local manifests=$(helm template "portal-${portal_name}" "$CHART_NAME" \
    --version "$chart_version" \
    --namespace "$portal_namespace" \
    --set "redhat-developer-hub.global.clusterRouterBase=${cluster_domain}" \
    --set "redhat-developer-hub.upstream.backstage.appConfig.catalog.providers.rhaap.production.baseUrl=https://${aap_route}" \
    --set "redhat-developer-hub.upstream.backstage.appConfig.catalog.providers.rhaap.production.orgs=${organization}" \
    --set "redhat-developer-hub.upstream.backstage.appConfig.auth.providers.aap.production.clientId=${client_id}" \
    --set "redhat-developer-hub.upstream.backstage.appConfig.auth.providers.aap.production.clientSecret=${client_secret}" \
    --set "redhat-developer-hub.upstream.backstage.appConfig.auth.providers.aap.production.baseUrl=https://${aap_route}" \
    2>/dev/null)

  if [ -z "$manifests" ]; then
    echo "  ERROR: Failed to render Helm chart"
    return 1
  fi

  # Apply manifests
  echo "  Applying manifests to namespace $portal_namespace..."
  echo "$manifests" | kubectl apply -n "$portal_namespace" -f - >/dev/null 2>&1 || {
    echo "  ERROR: Failed to apply manifests"
    return 1
  }

  # Update Portal status
  kubectl patch portal "$portal_name" -n "$portal_namespace" --type=merge --subresource=status -p "{
    \"status\": {
      \"portalUrl\": \"https://${portal_route}\",
      \"oauthClientId\": \"${client_id}\",
      \"conditions\": [{
        \"type\": \"Ready\",
        \"status\": \"True\",
        \"lastTransitionTime\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"reason\": \"ReconcileSuccess\",
        \"message\": \"Portal deployed successfully\"
      }]
    }
  }" 2>/dev/null || true

  echo "  ✓ Portal reconciled successfully"
  echo "    URL: https://${portal_route}"
}

delete_portal() {
  local portal_name="$1"
  local portal_namespace="$2"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deleting Portal: $portal_namespace/$portal_name"

  # Get stored OAuth client ID from status
  local client_id=$(kubectl get portal "$portal_name" -n "$portal_namespace" -o jsonpath='{.status.oauthClientId}' 2>/dev/null)

  if [ -n "$client_id" ]; then
    # Try to delete OAuth app (best effort)
    local spec=$(kubectl get portal "$portal_name" -n "$portal_namespace" -o json 2>/dev/null || echo "{}")
    local aap_namespace=$(echo "$spec" | jq -r '.spec.aapNamespace // empty')

    if [ -n "$aap_namespace" ]; then
      local aap_route=$(kubectl get route aap -n "$aap_namespace" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
      local admin_pass=$(kubectl get secret aap-admin-password -n "$aap_namespace" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

      if [ -n "$aap_route" ] && [ -n "$admin_pass" ]; then
        local app_id=$(curl -sk -u "admin:${admin_pass}" \
          "https://${aap_route}/api/gateway/v1/applications/?name=portal-${portal_namespace}-${portal_name}" | \
          jq -r '.results[0].id // empty' 2>/dev/null)

        if [ -n "$app_id" ]; then
          curl -sk -u "admin:${admin_pass}" \
            -X DELETE "https://${aap_route}/api/gateway/v1/applications/${app_id}/" 2>/dev/null || true
          echo "  ✓ OAuth app deleted"
        fi
      fi
    fi
  fi

  echo "  ✓ Portal deletion handled"
}

# Main reconcile loop
if [ "$1" = "--once" ]; then
  echo "Running one-time reconciliation..."

  # Reconcile all existing Portals
  kubectl get portals --all-namespaces -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' | while read portal; do
    namespace="${portal%/*}"
    name="${portal#*/}"
    reconcile_portal "$name" "$namespace" || true
  done

  echo "One-time reconciliation complete"
  exit 0
fi

echo "Starting Portal reconciler (interval: ${RECONCILE_INTERVAL}s)"
echo "Press Ctrl+C to stop"
echo ""

# Watch loop
while true; do
  # Get all Portal resources
  kubectl get portals --all-namespaces -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' | while read portal; do
    namespace="${portal%/*}"
    name="${portal#*/}"

    # Check if marked for deletion
    deletion_timestamp=$(kubectl get portal "$name" -n "$namespace" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")

    if [ -n "$deletion_timestamp" ]; then
      delete_portal "$name" "$namespace" || true
    else
      reconcile_portal "$name" "$namespace" || true
    fi
  done

  sleep "$RECONCILE_INTERVAL"
done
