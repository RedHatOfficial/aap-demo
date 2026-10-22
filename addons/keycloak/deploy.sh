#!/usr/bin/env bash
# Deploy Keycloak as a local OIDC provider for AAP and Automation Orchestrator.
# Dev/test only. No AAP or AO authentication configuration is changed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-aap-demo-keycloak}"
KEYCLOAK_IMAGE="${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak@sha256:79c623a22abacf3fe6c00a5fb30f5b7843d717b234033b80995891c06116d244}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-aap-lab}"
STATE_DIR="${KEYCLOAK_STATE_DIR:-${HOME}/.aap-demo/keycloak}"
ACTION="${1:-deploy}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

protected_namespace() {
  case "$1" in
    default | kube-* | openshift-* | aap-operator | automation-orchestrator)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  if protected_namespace "$KEYCLOAK_NAMESPACE"; then
    echo "ERROR: refusing to delete protected namespace ${KEYCLOAK_NAMESPACE}" >&2
    exit 1
  fi
  if ! kubectl get namespace "$KEYCLOAK_NAMESPACE" >/dev/null 2>&1; then
    echo "Keycloak namespace ${KEYCLOAK_NAMESPACE} does not exist"
    exit 0
  fi
  _managed_by="$(kubectl get namespace "$KEYCLOAK_NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  _managed_part="$(kubectl get namespace "$KEYCLOAK_NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || true)"
  if [ "$_managed_by" != "aap-demo-keycloak" ] || [ "$_managed_part" != "aap-demo" ]; then
    echo "ERROR: refusing to delete unowned namespace ${KEYCLOAK_NAMESPACE}" >&2
    exit 1
  fi
  echo "Removing Keycloak namespace ${KEYCLOAK_NAMESPACE}..."
  kubectl delete namespace "$KEYCLOAK_NAMESPACE" --ignore-not-found
  echo "✓ Keycloak removed"
  echo "  Local credentials retained under: ${STATE_DIR}"
  exit 0
fi

for _cmd in kubectl jq openssl; do require_cmd "$_cmd"; done
kubectl cluster-info >/dev/null 2>&1 || {
  echo "ERROR: kubectl is not connected to a cluster" >&2
  exit 1
}
if protected_namespace "$KEYCLOAK_NAMESPACE"; then
  echo "ERROR: refusing to use protected namespace ${KEYCLOAK_NAMESPACE}" >&2
  exit 1
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
umask 077

secret_file() {
  local _file="$STATE_DIR/$1"
  if [ ! -s "$_file" ]; then
    openssl rand -hex 24 | tr -d '\r\n' >"$_file"
  else
    local _normalized
    _normalized="$(mktemp "${TMPDIR:-/tmp}/aap-demo-secret.XXXXXX")"
    tr -d '\r\n' <"$_file" >"$_normalized"
    chmod 600 "$_normalized"
    mv "$_normalized" "$_file"
  fi
  chmod 600 "$_file"
  cat "$_file"
}

secret_file admin-password >/dev/null
secret_file aap-client-secret >/dev/null
secret_file ao-client-secret >/dev/null
secret_file aap-user-password >/dev/null
secret_file ao-user-password >/dev/null
secret_file aap-auditor-password >/dev/null
secret_file aap-developer-password >/dev/null

cluster_domain="$(kubectl get route aap -n "${NAMESPACE:-aap-operator}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [ -n "$cluster_domain" ]; then
  cluster_domain="${cluster_domain#*.}"
else
  cluster_domain="apps.127.0.0.1.nip.io"
fi

KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.${cluster_domain}}"
AAP_HOST="$(kubectl get route aap -n "${NAMESPACE:-aap-operator}" -o jsonpath='{.spec.host}' 2>/dev/null || printf 'aap-aap-operator.%s' "$cluster_domain")"
AO_HOST="$(kubectl get route -n automation-orchestrator -o jsonpath='{.items[0].spec.host}' 2>/dev/null || printf 'automation-orchestrator.%s' "$cluster_domain")"
KEYCLOAK_AAP_REDIRECT_URI="${KEYCLOAK_AAP_REDIRECT_URI:-https://${AAP_HOST}/}"
KEYCLOAK_AO_REDIRECT_URI="${KEYCLOAK_AO_REDIRECT_URI:-https://${AO_HOST}/}"
case "$KEYCLOAK_AAP_REDIRECT_URI:$KEYCLOAK_AO_REDIRECT_URI" in
  *\**)
    echo "ERROR: Keycloak redirect URIs must be exact URLs, not wildcards" >&2
    exit 1
    ;;
esac

realm_file="$(mktemp "${TMPDIR:-/tmp}/aap-lab-realm.XXXXXX.json")"
cleanup() { rm -f "$realm_file"; }
trap cleanup EXIT

jq -n \
  --arg realm "$KEYCLOAK_REALM" \
  --arg aap_host "$AAP_HOST" \
  --arg ao_host "$AO_HOST" \
  --arg aap_redirect_uri "$KEYCLOAK_AAP_REDIRECT_URI" \
  --arg ao_redirect_uri "$KEYCLOAK_AO_REDIRECT_URI" \
  --rawfile aap_secret_file "$STATE_DIR/aap-client-secret" \
  --rawfile ao_secret_file "$STATE_DIR/ao-client-secret" \
  --rawfile aap_password_file "$STATE_DIR/aap-user-password" \
  --rawfile ao_password_file "$STATE_DIR/ao-user-password" \
  --rawfile auditor_password_file "$STATE_DIR/aap-auditor-password" \
  --rawfile developer_password_file "$STATE_DIR/aap-developer-password" \
  '{
    realm: $realm,
    enabled: true,
    registrationAllowed: false,
    resetPasswordAllowed: true,
    clients: [
      {
        clientId: "aap-demo-aap",
        name: "AAP 2.6 OIDC test client",
        enabled: true,
        protocol: "openid-connect",
        publicClient: false,
        secret: ($aap_secret_file | rtrimstr("\n")),
        standardFlowEnabled: true,
        directAccessGrantsEnabled: false,
        defaultClientScopes: ["profile", "email", "roles", "web-origins", "acr", "groups"],
        redirectUris: [$aap_redirect_uri],
        webOrigins: ["https://" + $aap_host],
        attributes: {"post.logout.redirect.uris": $aap_redirect_uri}
      },
      {
        clientId: "aap-demo-ao",
        name: "Automation Orchestrator OIDC test client",
        enabled: true,
        protocol: "openid-connect",
        publicClient: false,
        secret: ($ao_secret_file | rtrimstr("\n")),
        standardFlowEnabled: true,
        directAccessGrantsEnabled: false,
        defaultClientScopes: ["profile", "email", "roles", "web-origins", "acr", "groups"],
        redirectUris: [$ao_redirect_uri],
        webOrigins: ["https://" + $ao_host],
        attributes: {"post.logout.redirect.uris": $ao_redirect_uri}
      }
    ],
    groups: [
      {name: "aap-admins"},
      {name: "aap-operators"},
      {name: "aap-auditors"},
      {name: "aap-developers"}
    ],
    users: [
      {
        username: "aap-oidc-admin",
        enabled: true,
        email: "aap-oidc-admin@example.test",
        emailVerified: true,
        groups: ["/aap-admins"],
        credentials: [{type: "password", value: ($aap_password_file | rtrimstr("\n")), temporary: false}]
      },
      {
        username: "aap-oidc-operator",
        enabled: true,
        email: "aap-oidc-operator@example.test",
        emailVerified: true,
        groups: ["/aap-operators"],
        credentials: [{type: "password", value: ($ao_password_file | rtrimstr("\n")), temporary: false}]
      },
      {
        username: "aap-oidc-auditor",
        enabled: true,
        email: "aap-oidc-auditor@example.test",
        emailVerified: true,
        groups: ["/aap-auditors"],
        credentials: [{type: "password", value: ($auditor_password_file | rtrimstr("\n")), temporary: false}]
      },
      {
        username: "aap-oidc-developer",
        enabled: true,
        email: "aap-oidc-developer@example.test",
        emailVerified: true,
        groups: ["/aap-developers"],
        credentials: [{type: "password", value: ($developer_password_file | rtrimstr("\n")), temporary: false}]
      }
    ],
    clientScopes: [{
      name: "groups",
      protocol: "openid-connect",
      protocolMappers: [{
        name: "groups",
        protocol: "openid-connect",
        protocolMapper: "oidc-group-membership-mapper",
        config: {"full.path": "false", "id.token.claim": "true", "access.token.claim": "true", "userinfo.token.claim": "true", "claim.name": "groups"}
      }]
    }]
  }' >"$realm_file"

if kubectl get namespace "$KEYCLOAK_NAMESPACE" >/dev/null 2>&1; then
  _managed_by="$(kubectl get namespace "$KEYCLOAK_NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  _managed_part="$(kubectl get namespace "$KEYCLOAK_NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || true)"
  if [ "$_managed_by" != "aap-demo-keycloak" ] || [ "$_managed_part" != "aap-demo" ]; then
    echo "ERROR: refusing to use unowned namespace ${KEYCLOAK_NAMESPACE}" >&2
    exit 1
  fi
else
  kubectl create namespace "$KEYCLOAK_NAMESPACE" >/dev/null
  kubectl label namespace "$KEYCLOAK_NAMESPACE" \
    app.kubernetes.io/managed-by=aap-demo-keycloak \
    app.kubernetes.io/part-of=aap-demo --overwrite >/dev/null
fi
kubectl -n "$KEYCLOAK_NAMESPACE" create secret generic keycloak-admin \
  --from-file=password="$STATE_DIR/admin-password" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$KEYCLOAK_NAMESPACE" create secret generic keycloak-realm \
  --from-file=aap-lab-realm.json="$realm_file" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if command -v sha256sum >/dev/null 2>&1; then
  realm_revision="$(sha256sum "$realm_file" | awk '{print $1}')"
  admin_revision="$(sha256sum "$STATE_DIR/admin-password" | awk '{print $1}')"
else
  realm_revision="$(shasum -a 256 "$realm_file" | awk '{print $1}')"
  admin_revision="$(shasum -a 256 "$STATE_DIR/admin-password" | awk '{print $1}')"
fi

sed \
  -e "s|__KEYCLOAK_IMAGE__|${KEYCLOAK_IMAGE}|g" \
  -e "s|__KEYCLOAK_HOST__|${KEYCLOAK_HOST}|g" \
  -e "s|__REALM_REVISION__|${realm_revision}|g" \
  -e "s|__ADMIN_REVISION__|${admin_revision}|g" \
  -e "s|aap-demo-keycloak|${KEYCLOAK_NAMESPACE}|g" \
  "$SCRIPT_DIR/keycloak.yaml" | kubectl apply -f - >/dev/null

echo "Waiting for Keycloak..."
kubectl rollout status deployment/keycloak -n "$KEYCLOAK_NAMESPACE" --timeout="${KEYCLOAK_ROLLOUT_TIMEOUT:-10m}"

issuer="https://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}"
echo ""
echo "✓ Keycloak deployed"
echo "  Admin console: https://${KEYCLOAK_HOST}/admin/"
echo "  Issuer:        ${issuer}"
echo "  Realm:         ${KEYCLOAK_REALM}"
echo "  AAP client:    aap-demo-aap"
echo "  AO client:     aap-demo-ao"
echo "  AAP callback:  ${KEYCLOAK_AAP_REDIRECT_URI}"
echo "  AO callback:   ${KEYCLOAK_AO_REDIRECT_URI}"
echo "  Credentials:   ${STATE_DIR}/"
echo ""
echo "  Configure AAP/AO manually with the issuer and client files."
echo "  Users:       aap-oidc-admin, aap-oidc-operator, aap-oidc-auditor, aap-oidc-developer"
