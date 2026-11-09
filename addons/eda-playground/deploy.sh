#!/usr/bin/env bash
# Deploy the experimental EDA Playground addon to the current cluster.

set +x
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-eda-playground}"
AAP_NAMESPACE="${AAP_NAMESPACE:-aap-operator}"
OAUTH_APP_NAME="${OAUTH_APP_NAME:-EDA Playground}"
STATE_DIR="${EDA_PLAYGROUND_STATE_DIR:-${HOME}/.aap-demo/eda-playground}"
IMAGE="${EDA_PLAYGROUND_IMAGE:-ghcr.io/bbgrimmett2/eda-playground:0.1.0}"
ACTION="${1:-deploy}"

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [[ "$ACTION" != "--delete" && "$ACTION" != "delete" ]]; }; then
  echo "Usage: $0 [--delete|delete]" >&2
  exit 2
fi

command -v kubectl >/dev/null 2>&1 || {
  echo "ERROR: kubectl is required" >&2
  exit 1
}

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  kubectl cluster-info >/dev/null 2>&1 || {
    echo "ERROR: kubectl is not connected to a cluster; refusing cleanup" >&2
    exit 1
  }

  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Namespace $NAMESPACE does not exist; nothing to delete"
    exit 0
  fi

  MANAGED_BY="$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  if [ "$MANAGED_BY" != "aap-demo-eda-playground" ]; then
    echo "Namespace $NAMESPACE is not owned by the EDA Playground addon; skipping deletion"
    exit 0
  fi

  kubectl delete namespace "$NAMESPACE" --ignore-not-found
  exit 0
fi

kubectl cluster-info >/dev/null 2>&1 || {
  echo "ERROR: kubectl is not connected to a cluster" >&2
  exit 1
}
for required in jq curl openssl base64; do
  command -v "$required" >/dev/null 2>&1 || {
    echo "ERROR: $required is required" >&2
    exit 1
  }
done

if [[ "$IMAGE" == *'|'* || "$IMAGE" == *$'\n'* ]]; then
  echo "ERROR: EDA_PLAYGROUND_IMAGE contains unsupported characters" >&2
  exit 2
fi

AAP_ROUTE="$(kubectl get route aap -n "$AAP_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)"
[ -n "$AAP_ROUTE" ] || {
  echo "ERROR: AAP route unavailable" >&2
  exit 1
}
ADMIN_PASS="$(kubectl get secret aap-admin-password -n "$AAP_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
[ -n "$ADMIN_PASS" ] || {
  echo "ERROR: AAP admin Secret unavailable" >&2
  exit 1
}
GATEWAY="https://$AAP_ROUTE/api/gateway/v1"
if ! curl -fsSk -u "admin:$ADMIN_PASS" --max-time 10 "$GATEWAY/ping/" >/dev/null 2>&1; then
  echo "ERROR: AAP Gateway ping failed" >&2
  exit 1
fi

CLUSTER_DOMAIN="${EDA_PLAYGROUND_DOMAIN:-}"
IS_MICROSHIFT=false
if [ -z "$CLUSTER_DOMAIN" ]; then
  CLUSTER_DOMAIN="$(kubectl get ingresses.config/cluster -o jsonpath='{.spec.domain}' --request-timeout=5s 2>/dev/null || true)"
  if [ -z "$CLUSTER_DOMAIN" ]; then
    IS_MICROSHIFT=true
    CLUSTER_DOMAIN="${AAP_ROUTE#*.}"
  fi
fi
[ -n "$CLUSTER_DOMAIN" ] && [ "$CLUSTER_DOMAIN" != "$AAP_ROUTE" ] || {
  echo "ERROR: unable to discover cluster application domain" >&2
  exit 1
}
ROUTE_HOST="eda-playground.$CLUSTER_DOMAIN"

# Gateway returns a client secret only at creation. Keep the saved value private.
umask 077
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
CREDENTIALS="$STATE_DIR/oauth_credentials.json"
ORGS="$(curl -fsSk -u "admin:$ADMIN_PASS" "$GATEWAY/organizations/")"
ORG_ID="$(jq -r '.results[0].id // empty' <<<"$ORGS")"
if [ -z "$ORG_ID" ]; then
  ORG_RESPONSE="$(curl -fsSk -u "admin:$ADMIN_PASS" -X POST "$GATEWAY/organizations/" \
    -H 'Content-Type: application/json' -d '{"name":"Default"}')"
  ORG_ID="$(jq -r '.id // empty' <<<"$ORG_RESPONSE")"
fi
[ -n "$ORG_ID" ] || {
  echo "ERROR: Gateway organization unavailable" >&2
  exit 1
}
ENCODED_NAME="$(jq -rn --arg name "$OAUTH_APP_NAME" '$name|@uri')"
APPS="$(curl -fsSk -u "admin:$ADMIN_PASS" "$GATEWAY/applications/?name=$ENCODED_NAME")"
OAUTH_APP_ID="$(jq -r --arg name "$OAUTH_APP_NAME" '.results[] | select(.name == $name) | .id' <<<"$APPS" | head -1)"
CLIENT_ID=""
CLIENT_SECRET=""
if [ -n "$OAUTH_APP_ID" ]; then
  CLIENT_ID="$(jq -r --arg name "$OAUTH_APP_NAME" '.results[] | select(.name == $name) | .client_id // empty' <<<"$APPS" | head -1)"
  if [ -f "$CREDENTIALS" ] && [ "$(jq -r '.oauth_app_id // empty' "$CREDENTIALS")" = "$OAUTH_APP_ID" ]; then
    CLIENT_SECRET="$(jq -r '.client_secret // empty' "$CREDENTIALS")"
  fi
  if [ -z "$CLIENT_SECRET" ]; then
    curl -fsSk -u "admin:$ADMIN_PASS" -X DELETE "$GATEWAY/applications/$OAUTH_APP_ID/" >/dev/null || {
      echo "ERROR: could not recreate owned OAuth application" >&2
      exit 1
    }
    OAUTH_APP_ID=""
  fi
fi
if [ -z "$OAUTH_APP_ID" ]; then
  APP_REQUEST="$(jq -n --arg name "$OAUTH_APP_NAME" --argjson org "$ORG_ID" \
    '{name:$name,organization:$org,authorization_grant_type:"authorization-code",client_type:"confidential",redirect_uris:"https://example.com"}')"
  APP_RESPONSE="$(curl -fsSk -u "admin:$ADMIN_PASS" -X POST "$GATEWAY/applications/" \
    -H 'Content-Type: application/json' -d "$APP_REQUEST")"
  OAUTH_APP_ID="$(jq -r '.id // empty' <<<"$APP_RESPONSE")"
  CLIENT_ID="$(jq -r '.client_id // empty' <<<"$APP_RESPONSE")"
  CLIENT_SECRET="$(jq -r '.client_secret // empty' <<<"$APP_RESPONSE")"
fi
[ -n "$OAUTH_APP_ID" ] && [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] || {
  echo "ERROR: Gateway OAuth credentials incomplete" >&2
  exit 1
}
TEMP_CREDENTIALS="$(mktemp "$STATE_DIR/.oauth-credentials.XXXXXX")"
jq -n --arg oauth_app_id "$OAUTH_APP_ID" --arg client_id "$CLIENT_ID" \
  --arg client_secret "$CLIENT_SECRET" \
  '{oauth_app_id:$oauth_app_id,client_id:$client_id,client_secret:$client_secret}' >"$TEMP_CREDENTIALS"
chmod 600 "$TEMP_CREDENTIALS"
mv "$TEMP_CREDENTIALS" "$CREDENTIALS"
SESSION_SECRET="$(openssl rand -hex 16)"
AAP_BASE_URL="https://$AAP_ROUTE"
if [ "$IS_MICROSHIFT" = true ]; then
  AAP_BASE_URL="http://$AAP_ROUTE"
fi
REDIRECT="https://$ROUTE_HOST/auth/callback"

# Build Secret JSON on stdin; command output and shell tracing never expose values.
sed -e "s|name: eda-playground$|name: $NAMESPACE|g" -e "s|namespace: eda-playground$|namespace: $NAMESPACE|g" \
  "$SCRIPT_DIR/namespace.yaml" | kubectl apply -f - >/dev/null
jq -n --arg name eda-playground-oauth --arg namespace "$NAMESPACE" \
  --arg client_id "$CLIENT_ID" --arg client_secret "$CLIENT_SECRET" --arg session_secret "$SESSION_SECRET" \
  '{apiVersion:"v1",kind:"Secret",metadata:{name:$name,namespace:$namespace},type:"Opaque",stringData:{"client-id":$client_id,"client-secret":$client_secret,"session-secret":$session_secret}}' \
  | kubectl create -f - --dry-run=client -o yaml | kubectl apply -f - >/dev/null
for manifest in configmap.yaml service.yaml; do
  sed "s|namespace: eda-playground$|namespace: $NAMESPACE|g" "$SCRIPT_DIR/$manifest" | kubectl apply -f - >/dev/null
done
sed -e "s|__EDA_PLAYGROUND_IMAGE__|$IMAGE|g" \
  -e "s|__EDA_PLAYGROUND_AAP_BASE_URL__|$AAP_BASE_URL|g" \
  -e "s|__EDA_PLAYGROUND_REDIRECT_URI__|$REDIRECT|g" \
  -e "s|namespace: eda-playground|namespace: $NAMESPACE|g" \
  "$SCRIPT_DIR/deployment.yaml" | kubectl apply -f - >/dev/null
sed -e "s|__EDA_PLAYGROUND_ROUTE_HOST__|$ROUTE_HOST|g" -e "s|namespace: eda-playground|namespace: $NAMESPACE|g" \
  "$SCRIPT_DIR/route.yaml" | kubectl apply -f - >/dev/null

if [ "$IS_MICROSHIFT" = true ]; then
  AAP_IP="$(kubectl get svc aap -n "$AAP_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
  [ -n "$AAP_IP" ] || {
    echo "ERROR: AAP Service ClusterIP unavailable" >&2
    exit 1
  }
  ALIAS_PATCH="$(jq -n --arg ip "$AAP_IP" --arg host "$AAP_ROUTE" \
    '{spec:{template:{spec:{hostAliases:[{ip:$ip,hostnames:[$host]}]}}}}')"
  kubectl patch deployment eda-playground -n "$NAMESPACE" --type=merge -p "$ALIAS_PATCH" >/dev/null
fi
kubectl rollout status deployment/eda-playground -n "$NAMESPACE" >/dev/null
if command -v oc >/dev/null 2>&1; then
  oc adm policy add-scc-to-user anyuid -z eda-playground -n "$NAMESPACE" >/dev/null
fi
ROUTE_HOST="$(kubectl get route eda-playground -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)"
[ -n "$ROUTE_HOST" ] || {
  echo "ERROR: EDA Playground Route unavailable" >&2
  exit 1
}
REDIRECT="https://$ROUTE_HOST/auth/callback"
PATCH_REQUEST="$(jq -n --arg uri "$REDIRECT" '{redirect_uris:$uri}')"
if ! curl -fsSk -u "admin:$ADMIN_PASS" -X PATCH "$GATEWAY/applications/$OAUTH_APP_ID/" \
  -H 'Content-Type: application/json' -d "$PATCH_REQUEST" >/dev/null; then
  echo "ERROR: OAuth redirect update failed; retry deployment after checking the Gateway application" >&2
  exit 1
fi
echo "EDA Playground deployed in namespace $NAMESPACE"
echo "Route: https://$ROUTE_HOST"
