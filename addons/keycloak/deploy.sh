#!/usr/bin/env bash
# Deploy Keycloak as a local OIDC provider for AAP and Automation Orchestrator.
# Dev/test only. No AAP or AO authentication configuration is changed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-aap-demo-keycloak}"
KEYCLOAK_IMAGE="${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:26.8.1}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-aap-lab}"
STATE_DIR="${KEYCLOAK_STATE_DIR:-${HOME}/.aap-demo/keycloak}"
ACTION="${1:-deploy}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
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

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
umask 077

secret_file() {
  local _file="$STATE_DIR/$1"
  if [ ! -s "$_file" ]; then
    openssl rand -hex 24 >"$_file"
  fi
  chmod 600 "$_file"
  cat "$_file"
}

secret_file admin-password >/dev/null
secret_file aap-client-secret >/dev/null
secret_file ao-client-secret >/dev/null
secret_file aap-user-password >/dev/null
secret_file ao-user-password >/dev/null

cluster_domain="$(kubectl get route aap -n "${NAMESPACE:-aap-operator}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [ -n "$cluster_domain" ]; then
  cluster_domain="${cluster_domain#*.}"
else
  cluster_domain="apps.127.0.0.1.nip.io"
fi

KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.${cluster_domain}}"
AAP_HOST="$(kubectl get route aap -n "${NAMESPACE:-aap-operator}" -o jsonpath='{.spec.host}' 2>/dev/null || printf 'aap-aap-operator.%s' "$cluster_domain")"
AO_HOST="$(kubectl get route -n automation-orchestrator -o jsonpath='{.items[0].spec.host}' 2>/dev/null || printf 'automation-orchestrator.%s' "$cluster_domain")"

realm_file="$(mktemp "${TMPDIR:-/tmp}/aap-lab-realm.XXXXXX.json")"
cleanup() { rm -f "$realm_file"; }
trap cleanup EXIT

jq -n \
  --arg realm "$KEYCLOAK_REALM" \
  --arg aap_host "$AAP_HOST" \
  --arg ao_host "$AO_HOST" \
  --rawfile aap_secret_file "$STATE_DIR/aap-client-secret" \
  --rawfile ao_secret_file "$STATE_DIR/ao-client-secret" \
  --rawfile aap_password_file "$STATE_DIR/aap-user-password" \
  --rawfile ao_password_file "$STATE_DIR/ao-user-password" \
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
        redirectUris: ["https://" + $aap_host + "/*"],
        webOrigins: ["https://" + $aap_host],
        attributes: {"post.logout.redirect.uris": ("https://" + $aap_host + "/*")}
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
        redirectUris: ["https://" + $ao_host + "/*"],
        webOrigins: ["https://" + $ao_host],
        attributes: {"post.logout.redirect.uris": ("https://" + $ao_host + "/*")}
      }
    ],
    groups: [{name: "aap-admins"}, {name: "aap-operators"}],
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

kubectl create namespace "$KEYCLOAK_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$KEYCLOAK_NAMESPACE" create secret generic keycloak-admin \
  --from-file=password="$STATE_DIR/admin-password" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$KEYCLOAK_NAMESPACE" create secret generic keycloak-realm \
  --from-file=aap-lab-realm.json="$realm_file" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if command -v sha256sum >/dev/null 2>&1; then
  realm_revision="$(sha256sum "$realm_file" | awk '{print $1}')"
else
  realm_revision="$(shasum -a 256 "$realm_file" | awk '{print $1}')"
fi

sed \
  -e "s|__KEYCLOAK_IMAGE__|${KEYCLOAK_IMAGE}|g" \
  -e "s|__KEYCLOAK_HOST__|${KEYCLOAK_HOST}|g" \
  -e "s|__REALM_REVISION__|${realm_revision}|g" \
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
echo "  Credentials:   ${STATE_DIR}/"
echo ""
echo "  Configure AAP/AO manually with the issuer and client files."
echo "  Usernames: aap-oidc-admin, aap-oidc-operator"
