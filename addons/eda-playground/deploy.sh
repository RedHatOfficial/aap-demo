#!/usr/bin/env bash
# Deploy the experimental EDA Playground addon to the current cluster.

set +x
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_NAMESPACE="${AAP_NAMESPACE:-${NAMESPACE:-aap-operator}}"
NAMESPACE="${EDA_PLAYGROUND_NAMESPACE:-eda-playground}"
OAUTH_APP_NAME="${OAUTH_APP_NAME:-EDA Playground}"
STATE_DIR="${EDA_PLAYGROUND_STATE_DIR:-${HOME}/.aap-demo/eda-playground}"
IMAGE="${EDA_PLAYGROUND_IMAGE:-ghcr.io/bbgrimmett2/eda-playground:0.1.0}"
ACTION="${1:-deploy}"

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [[ "$ACTION" != "--delete" && "$ACTION" != "delete" ]]; }; then
  echo "Usage: $0 [--delete|delete]" >&2
  exit 2
fi

if [[ ! "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || [ "${#NAMESPACE}" -gt 63 ] \
  || [ "$NAMESPACE" = "$AAP_NAMESPACE" ] || [ "$NAMESPACE" = aap-operator ] \
  || [ "$NAMESPACE" = default ] || [[ "$NAMESPACE" == kube-* ]] || [[ "$NAMESPACE" == openshift-* ]]; then
  echo "ERROR: unsafe EDA Playground namespace: $NAMESPACE" >&2
  exit 1
fi

command -v kubectl >/dev/null 2>&1 || {
  echo "ERROR: kubectl is required" >&2
  exit 1
}

# curl reads credentials from its configuration on stdin, never from argv.
# Escape values interpreted by curl's quoted configuration syntax.
gateway_curl() {
  printf 'user = "admin:%s"\n' "$CURL_PASSWORD" | curl --config - -fsSk "$@" 2>/dev/null
}

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  kubectl cluster-info >/dev/null 2>&1 || {
    echo "ERROR: kubectl is not connected to a cluster; refusing cleanup" >&2
    exit 1
  }

  CREDENTIALS="$STATE_DIR/oauth_credentials.json"
  TOMBSTONE="$STATE_DIR/oauth_app_id"
  CLEANUP_FAILED=0
  cleanup_error() {
    echo "ERROR: EDA Playground cleanup incomplete: $1" >&2
    CLEANUP_FAILED=1
  }
  gateway_request() {
    if GATEWAY_RESPONSE="$(gateway_curl -w $'\n%{http_code}' "$@")"; then
      GATEWAY_EXIT=0
    else
      GATEWAY_EXIT=$?
    fi
    GATEWAY_STATUS="${GATEWAY_RESPONSE##*$'\n'}"
    GATEWAY_BODY="${GATEWAY_RESPONSE%$'\n'*}"
  }
  SAVED_ID=""
  APP_ID=""
  AAP_ROUTE=""
  ADMIN_PASS=""
  MANAGED_BY=""
  if [ -f "$TOMBSTONE" ]; then
    if ! SAVED_ID="$(cat "$TOMBSTONE" 2>/dev/null)"; then
      cleanup_error 'saved OAuth ownership marker could not be read'
      exit 1
    fi
    if [[ ! "$SAVED_ID" =~ ^[1-9][0-9]*$ ]]; then
      cleanup_error 'saved OAuth ownership marker has a missing or invalid application ID'
      exit 1
    fi
  fi
  if [ -f "$CREDENTIALS" ]; then
    if ! command -v jq >/dev/null 2>&1; then
      cleanup_error 'jq is required to read saved OAuth ownership'
      exit 1
    elif ! SAVED_ID="$(jq -r '.oauth_app_id // empty' "$CREDENTIALS" 2>/dev/null)"; then
      cleanup_error 'saved OAuth metadata could not be read'
      exit 1
    fi
  fi
  if [ -f "$CREDENTIALS" ] && [[ ! "$SAVED_ID" =~ ^[1-9][0-9]*$ ]]; then
    cleanup_error 'saved OAuth metadata has a missing or invalid application ID'
    exit 1
  fi
  for required in jq curl base64; do
    command -v "$required" >/dev/null 2>&1 || cleanup_error "$required is required for OAuth cleanup"
  done
  if [ "$CLEANUP_FAILED" -eq 0 ]; then
    if ! AAP_ROUTE="$(kubectl get route aap -n "$AAP_NAMESPACE" --ignore-not-found -o jsonpath='{.spec.host}' 2>/dev/null)"; then
      cleanup_error 'AAP Route lookup failed'
    fi
    if [ -n "$AAP_ROUTE" ] && [ "$CLEANUP_FAILED" -eq 0 ]; then
      if ! ADMIN_B64="$(kubectl get secret aap-admin-password -n "$AAP_NAMESPACE" --ignore-not-found -o jsonpath='{.data.password}' 2>/dev/null)"; then
        cleanup_error 'AAP admin Secret lookup failed'
      elif [ -n "$ADMIN_B64" ] && ! ADMIN_PASS="$(printf '%s' "$ADMIN_B64" | base64 -d 2>/dev/null)"; then
        cleanup_error 'AAP admin Secret could not be decoded'
      fi
    fi
    if [ -n "$AAP_ROUTE" ] && [ -n "$ADMIN_PASS" ] && [ "$CLEANUP_FAILED" -eq 0 ]; then
      CURL_PASSWORD="${ADMIN_PASS//\\/\\\\}"
      CURL_PASSWORD="${CURL_PASSWORD//\"/\\\"}"
      GATEWAY="https://$AAP_ROUTE/api/gateway/v1"
      gateway_request --max-time 10 "$GATEWAY/ping/"
      if [ "$GATEWAY_EXIT" -ne 0 ] || [[ ! "$GATEWAY_STATUS" =~ ^2[0-9][0-9]$ ]]; then
        cleanup_error 'AAP Gateway ping failed'
      else
        ENCODED_NAME="$(jq -rn --arg name "$OAUTH_APP_NAME" '$name|@uri')"
        NEXT_URL="$GATEWAY/applications/?name=$ENCODED_NAME"
        MATCH_IDS=""
        PAGE_COUNT=0
        while [ -n "$NEXT_URL" ]; do
          PAGE_COUNT=$((PAGE_COUNT + 1))
          if [ "$PAGE_COUNT" -gt 100 ] || [[ "$NEXT_URL" != "$GATEWAY/applications/"* ]]; then
            cleanup_error 'Gateway application pagination is invalid'
            break
          fi
          gateway_request "$NEXT_URL"
          if [ "$GATEWAY_EXIT" -ne 0 ] || [[ ! "$GATEWAY_STATUS" =~ ^2[0-9][0-9]$ ]]; then
            cleanup_error 'Gateway application lookup failed'
            break
          fi
          if ! jq -e '(.results | type == "array") and (.next == null or (.next | type == "string"))' <<<"$GATEWAY_BODY" >/dev/null 2>&1; then
            cleanup_error 'Gateway application response is invalid'
            break
          fi
          if ! jq -e --arg name "$OAUTH_APP_NAME" 'all(.results[] | select(.name == $name); .id | tostring | test("^[1-9][0-9]*$"))' <<<"$GATEWAY_BODY" >/dev/null 2>&1; then
            cleanup_error 'Gateway application has a missing or invalid ID'
            exit 1
          fi
          PAGE_IDS="$(jq -r --arg name "$OAUTH_APP_NAME" '.results[] | select(.name == $name) | .id | tostring' <<<"$GATEWAY_BODY")"
          if [ -n "$PAGE_IDS" ]; then MATCH_IDS="${MATCH_IDS}${MATCH_IDS:+$'\n'}${PAGE_IDS}"; fi
          NEXT_URL="$(jq -r '.next // empty' <<<"$GATEWAY_BODY")"
          if [[ "$NEXT_URL" == /api/gateway/v1/applications/* ]]; then NEXT_URL="https://$AAP_ROUTE$NEXT_URL"; fi
        done
        if [ "$CLEANUP_FAILED" -eq 0 ]; then
          if [ -n "$SAVED_ID" ]; then
            if [ "$(grep -Fxc -- "$SAVED_ID" <<<"$MATCH_IDS" || true)" = 1 ]; then
              APP_ID="$SAVED_ID"
            elif [ -n "$MATCH_IDS" ]; then
              echo 'OAuth application ownership mismatch; skipping application deletion'
            fi
          elif [ "$(grep -c . <<<"$MATCH_IDS" || true)" = 1 ]; then
            APP_ID="$MATCH_IDS"
          elif [ -n "$MATCH_IDS" ]; then
            cleanup_error 'multiple exact-name OAuth applications found'
          fi
        fi
      fi
    fi
  fi

  # Persist validated ownership before any destructive cleanup, even if AAP is absent.
  OWNED_ID="${SAVED_ID:-$APP_ID}"
  if [ -n "$OWNED_ID" ]; then
    umask 077
    if ! { mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR" && printf '%s\n' "$OWNED_ID" >"$TOMBSTONE"; } 2>/dev/null; then
      cleanup_error 'could not save OAuth ownership marker'
      exit 1
    fi
  fi
  if [[ "$APP_ID" =~ ^[1-9][0-9]*$ ]] && [ "$CLEANUP_FAILED" -eq 0 ]; then
    gateway_request -X DELETE "$GATEWAY/applications/$APP_ID/"
    if [ "$GATEWAY_STATUS" != 404 ] && { [ "$GATEWAY_EXIT" -ne 0 ] || [[ ! "$GATEWAY_STATUS" =~ ^2[0-9][0-9]$ ]]; }; then
      cleanup_error "OAuth application $APP_ID deletion failed"
    fi
  fi

  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    if ! MANAGED_BY="$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"; then
      cleanup_error "namespace $NAMESPACE ownership lookup failed"
    fi
    if [ "$MANAGED_BY" = "aap-demo-eda-playground" ]; then
      SCC_READY=true
      if command -v oc >/dev/null 2>&1; then
        if ! SCC_ERROR="$(oc adm policy remove-scc-from-user anyuid -z eda-playground -n "$NAMESPACE" 2>&1)"; then
          case "$SCC_ERROR" in
            'Error from server (NotFound): rolebindings.rbac.authorization.k8s.io "system:openshift:scc:anyuid" not found' | \
              'Error from server (NotFound): securitycontextconstraints.security.openshift.io "anyuid" not found') ;;
            'error: unable to find target [eda-playground]' | 'unable to find target [eda-playground]')
              if ! SCC_BINDING="$(oc get rolebinding system:openshift:scc:anyuid -n "$NAMESPACE" -o json 2>/dev/null)" \
                || ! jq -e --arg ns "$NAMESPACE" '
                  .kind == "RoleBinding" and
                  .metadata.name == "system:openshift:scc:anyuid" and .metadata.namespace == $ns and
                  .roleRef == {apiGroup:"rbac.authorization.k8s.io",kind:"ClusterRole",name:"system:openshift:scc:anyuid"} and
                  (.subjects == null or (.subjects | type == "array")) and
                  all(.subjects[]?;
                    (.kind == "ServiceAccount" or .kind == "User" or .kind == "Group") and
                    (.name | type == "string") and
                    (.kind != "ServiceAccount" or (.namespace | type == "string"))) and
                  all(.subjects[]?;
                    (.kind != "ServiceAccount" or .name != "eda-playground" or .namespace != $ns) and
                    (.kind != "User" or .name != ("system:serviceaccount:" + $ns + ":eda-playground")))
                ' <<<"$SCC_BINDING" >/dev/null 2>&1; then
                cleanup_error "SCC subject absence could not be confirmed in namespace $NAMESPACE"
                SCC_READY=false
              fi
              ;;
            *)
              cleanup_error "SCC binding removal failed in namespace $NAMESPACE"
              SCC_READY=false
              ;;
          esac
        fi
      fi
      if [ "$SCC_READY" = true ]; then
        if ! kubectl delete namespace "$NAMESPACE" --ignore-not-found >/dev/null 2>&1; then
          cleanup_error "namespace $NAMESPACE deletion failed"
        fi
      fi
    else
      echo "Namespace $NAMESPACE is not owned by the EDA Playground addon; skipping deletion"
    fi
  elif ! NS_CHECK="$(kubectl get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"; then
    cleanup_error "namespace $NAMESPACE lookup failed"
  elif [ -n "$NS_CHECK" ]; then
    cleanup_error "namespace $NAMESPACE lookup failed"
  fi
  rm -f "$CREDENTIALS" || cleanup_error 'local OAuth credential removal failed'
  rmdir "$STATE_DIR" 2>/dev/null || true
  exit "$CLEANUP_FAILED"
fi

kubectl cluster-info >/dev/null 2>&1 || {
  echo "ERROR: kubectl is not connected to a cluster" >&2
  exit 1
}
if ! EXISTING_NAMESPACE="$(kubectl get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"; then
  echo "ERROR: EDA Playground namespace $NAMESPACE lookup failed" >&2
  exit 1
fi
if [ -n "$EXISTING_NAMESPACE" ]; then
  if ! MANAGED_BY="$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" \
    || [ "$MANAGED_BY" != aap-demo-eda-playground ]; then
    echo "ERROR: namespace $NAMESPACE is not owned by EDA Playground" >&2
    exit 1
  fi
fi
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

if ! AAP_ROUTE="$(kubectl get route aap -n "$AAP_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)"; then
  echo "ERROR: AAP route unavailable in $AAP_NAMESPACE" >&2
  exit 1
fi
[ -n "$AAP_ROUTE" ] || {
  echo "ERROR: AAP route unavailable" >&2
  exit 1
}
if ! ADMIN_PASS="$(kubectl get secret aap-admin-password -n "$AAP_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"; then
  echo "ERROR: AAP admin Secret unavailable in $AAP_NAMESPACE" >&2
  exit 1
fi
[ -n "$ADMIN_PASS" ] || {
  echo "ERROR: AAP admin Secret unavailable" >&2
  exit 1
}
GATEWAY="https://$AAP_ROUTE/api/gateway/v1"
CURL_PASSWORD="${ADMIN_PASS//\\/\\\\}"
CURL_PASSWORD="${CURL_PASSWORD//\"/\\\"}"
if ! gateway_curl --max-time 10 "$GATEWAY/ping/" >/dev/null 2>&1; then
  echo "ERROR: AAP Gateway ping failed" >&2
  exit 1
fi

INGRESS_DOMAIN="$(kubectl get ingresses.config/cluster -o jsonpath='{.spec.domain}' --request-timeout=5s 2>/dev/null || true)"
IS_MICROSHIFT=false
if [ -z "$INGRESS_DOMAIN" ]; then
  IS_MICROSHIFT=true
  INGRESS_DOMAIN="${AAP_ROUTE#*.}"
fi
CLUSTER_DOMAIN="${EDA_PLAYGROUND_DOMAIN:-$INGRESS_DOMAIN}"
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
ORGS="$(gateway_curl "$GATEWAY/organizations/")"
ORG_ID="$(jq -r '.results[0].id // empty' <<<"$ORGS")"
if [ -z "$ORG_ID" ]; then
  ORG_RESPONSE="$(gateway_curl -X POST "$GATEWAY/organizations/" \
    -H 'Content-Type: application/json' -d '{"name":"Default"}')"
  ORG_ID="$(jq -r '.id // empty' <<<"$ORG_RESPONSE")"
fi
[ -n "$ORG_ID" ] || {
  echo "ERROR: Gateway organization unavailable" >&2
  exit 1
}
ENCODED_NAME="$(jq -rn --arg name "$OAUTH_APP_NAME" '$name|@uri')"
APPS="$(gateway_curl "$GATEWAY/applications/?name=$ENCODED_NAME")"
SAVED_ID=""
if [ -f "$CREDENTIALS" ]; then
  SAVED_ID="$(jq -r '.oauth_app_id // empty' "$CREDENTIALS")"
fi
MATCH_COUNT="$(jq --arg name "$OAUTH_APP_NAME" '[.results[] | select(.name == $name)] | length' <<<"$APPS")"
SAVED_MATCH_COUNT="$(jq --arg name "$OAUTH_APP_NAME" --arg id "$SAVED_ID" '[.results[] | select(.name == $name and (.id|tostring) == $id)] | length' <<<"$APPS")"
if [ "$SAVED_MATCH_COUNT" -eq 1 ]; then
  OAUTH_APP_ID="$SAVED_ID"
elif [ "$MATCH_COUNT" -eq 1 ]; then
  OAUTH_APP_ID="$(jq -r --arg name "$OAUTH_APP_NAME" '.results[] | select(.name == $name) | .id' <<<"$APPS")"
elif [ "$MATCH_COUNT" -gt 1 ]; then
  echo "ERROR: multiple OAuth applications have the configured name; restore matching saved credentials or resolve duplicates before retrying" >&2
  exit 1
else
  OAUTH_APP_ID=""
fi
CLIENT_ID=""
CLIENT_SECRET=""
if [ -n "$OAUTH_APP_ID" ]; then
  CLIENT_ID="$(jq -r --arg name "$OAUTH_APP_NAME" --arg id "$OAUTH_APP_ID" '.results[] | select(.name == $name and (.id|tostring) == $id) | .client_id // empty' <<<"$APPS")"
  if [ -f "$CREDENTIALS" ] && [ "$(jq -r '.oauth_app_id // empty' "$CREDENTIALS")" = "$OAUTH_APP_ID" ]; then
    CLIENT_SECRET="$(jq -r '.client_secret // empty' "$CREDENTIALS")"
  fi
  if [ -z "$CLIENT_SECRET" ]; then
    gateway_curl -X DELETE "$GATEWAY/applications/$OAUTH_APP_ID/" >/dev/null 2>&1 || {
      echo "ERROR: could not recreate owned OAuth application" >&2
      exit 1
    }
    OAUTH_APP_ID=""
  fi
fi
if [ -z "$OAUTH_APP_ID" ]; then
  APP_REQUEST="$(jq -n --arg name "$OAUTH_APP_NAME" --argjson org "$ORG_ID" \
    '{name:$name,organization:$org,authorization_grant_type:"authorization-code",client_type:"confidential",redirect_uris:"https://example.com"}')"
  APP_RESPONSE="$(gateway_curl -X POST "$GATEWAY/applications/" \
    -H 'Content-Type: application/json' -d "$APP_REQUEST")"
  OAUTH_APP_ID="$(jq -r '.id // empty' <<<"$APP_RESPONSE")"
  CLIENT_ID="$(jq -r '.client_id // empty' <<<"$APP_RESPONSE")"
  CLIENT_SECRET="$(jq -r '.client_secret // empty' <<<"$APP_RESPONSE")"
fi
[ -n "$OAUTH_APP_ID" ] && [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] || {
  echo "ERROR: Gateway OAuth credentials incomplete" >&2
  exit 1
}
SECRET_DIR="$(mktemp -d "$STATE_DIR/.secret-inputs.XXXXXX")"
trap 'rm -rf "$SECRET_DIR"' EXIT
printf '%s' "$CLIENT_ID" >"$SECRET_DIR/client-id"
printf '%s' "$CLIENT_SECRET" >"$SECRET_DIR/client-secret"
TEMP_CREDENTIALS="$(mktemp "$STATE_DIR/.oauth-credentials.XXXXXX")"
jq -n --arg oauth_app_id "$OAUTH_APP_ID" --rawfile client_id "$SECRET_DIR/client-id" \
  --rawfile client_secret "$SECRET_DIR/client-secret" \
  '{oauth_app_id:$oauth_app_id,client_id:$client_id,client_secret:$client_secret}' >"$TEMP_CREDENTIALS"
chmod 600 "$TEMP_CREDENTIALS"
mv "$TEMP_CREDENTIALS" "$CREDENTIALS"
SESSION_SECRET="$(openssl rand -hex 16)"
printf '%s' "$SESSION_SECRET" >"$SECRET_DIR/session-secret"
AAP_BASE_URL="https://$AAP_ROUTE"
if [ "$IS_MICROSHIFT" = true ]; then
  AAP_BASE_URL="http://$AAP_ROUTE"
fi
REDIRECT="https://$ROUTE_HOST/auth/callback"

# Build Secret JSON on stdin; command output and shell tracing never expose values.
awk -v namespace="$NAMESPACE" '
  /^  name: eda-playground$/ && !namespace_name_seen {
    sub(/eda-playground$/, namespace)
    namespace_name_seen = 1
  }
  /^  namespace: eda-playground$/ { sub(/eda-playground$/, namespace) }
  { print }
' "$SCRIPT_DIR/namespace.yaml" | kubectl apply -f - >/dev/null
jq -n --arg name eda-playground-oauth --arg namespace "$NAMESPACE" \
  --rawfile client_id "$SECRET_DIR/client-id" --rawfile client_secret "$SECRET_DIR/client-secret" \
  --rawfile session_secret "$SECRET_DIR/session-secret" \
  '{apiVersion:"v1",kind:"Secret",metadata:{name:$name,namespace:$namespace},type:"Opaque",stringData:{"client-id":$client_id,"client-secret":$client_secret,"session-secret":$session_secret}}' \
  | kubectl create -f - --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if command -v oc >/dev/null 2>&1; then
  oc adm policy add-scc-to-user anyuid -z eda-playground -n "$NAMESPACE" >/dev/null
fi
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

CURRENT_REVISION="$(kubectl get deployment eda-playground -n "$NAMESPACE" \
  -o jsonpath="{.spec.template.metadata.annotations['aap-demo/revision']}" 2>/dev/null || true)"
if [[ "$CURRENT_REVISION" =~ ^[0-9]+$ ]]; then
  REVISION=$((CURRENT_REVISION + 1))
else
  REVISION="$(date -u +%s)"
fi
if [ "$REVISION" = "$CURRENT_REVISION" ]; then
  REVISION="${REVISION}1"
fi
REVISION_PATCH="$(jq -n --arg revision "$REVISION" \
  '{spec:{template:{metadata:{annotations:{"aap-demo/revision":$revision}}}}}')"
kubectl patch deployment eda-playground -n "$NAMESPACE" --type=merge -p "$REVISION_PATCH" >/dev/null

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
if ! kubectl rollout status deployment/eda-playground -n "$NAMESPACE" --timeout=180s >/dev/null; then
  echo "ERROR: EDA Playground rollout did not complete; inspect deployment/eda-playground in $NAMESPACE and retry deployment" >&2
  exit 1
fi
ROUTE_HOST="$(kubectl get route eda-playground -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)"
[ -n "$ROUTE_HOST" ] || {
  echo "ERROR: EDA Playground Route unavailable" >&2
  exit 1
}
REDIRECT="https://$ROUTE_HOST/auth/callback"
PATCH_REQUEST="$(jq -n --arg uri "$REDIRECT" '{redirect_uris:$uri}')"
if ! gateway_curl -X PATCH "$GATEWAY/applications/$OAUTH_APP_ID/" \
  -H 'Content-Type: application/json' -d "$PATCH_REQUEST" >/dev/null 2>&1; then
  echo "ERROR: OAuth redirect update failed; retry deployment after checking the Gateway application" >&2
  exit 1
fi
echo "EDA Playground deployed in namespace $NAMESPACE"
echo "Route: https://$ROUTE_HOST"
