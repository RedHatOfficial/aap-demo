#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${KEYCLOAK_NAMESPACE:-aap-demo-keycloak}"
REALM="${KEYCLOAK_REALM:-aap-lab}"

for command_name in kubectl curl jq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "FAIL: required command not found: $command_name"
    exit 1
  }
done

kubectl cluster-info >/dev/null 2>&1 || {
  echo "FAIL: kubectl is not connected to a cluster"
  exit 1
}

available="$(kubectl get deployment keycloak -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}')"
[ "$available" = "1" ] || {
  echo "FAIL: Keycloak deployment is not ready"
  exit 1
}

host="$(kubectl get route keycloak -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
[ -n "$host" ] || {
  echo "FAIL: Keycloak Route has no host"
  exit 1
}

state_dir="${KEYCLOAK_STATE_DIR:-${HOME}/.aap-demo/keycloak}"
admin_password_file="$state_dir/admin-password"
test -s "$admin_password_file" || {
  echo "FAIL: Keycloak admin password file is missing"
  exit 1
}

admin_token="$(curl -skf -X POST "https://${host}/realms/master/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'client_id=admin-cli' \
  --data-urlencode 'grant_type=password' \
  --data-urlencode 'username=admin' \
  --data-urlencode "password@${admin_password_file}" | jq -r '.access_token // empty')"
[ -n "$admin_token" ] || {
  echo "FAIL: Keycloak admin API login failed"
  exit 1
}

admin_curl() {
  curl -skf -H "Authorization: Bearer ${admin_token}" "$@"
}

curl -skf "https://${host}/realms/${REALM}/.well-known/openid-configuration" \
  | jq -e '.issuer and .authorization_endpoint and .token_endpoint and .jwks_uri' >/dev/null

admin_curl "https://${host}/admin/realms/${REALM}/clients?clientId=aap-demo-aap" \
  | jq -e '
    (. | length == 1) and
    .[0].clientId == "aap-demo-aap" and
    any(.[0].protocolMappers[]; .protocolMapper == "oidc-audience-mapper" and .config["included.client.audience"] == "aap-demo-aap" and .config["access.token.claim"] == "true") and
    any(.[0].protocolMappers[]; .protocolMapper == "oidc-usermodel-property-mapper" and .config["claim.name"] == "preferred_username" and .config["id.token.claim"] == "true" and .config["access.token.claim"] == "true" and .config["userinfo.token.claim"] == "true") and
    any(.[0].protocolMappers[]; .protocolMapper == "oidc-usermodel-property-mapper" and .config["claim.name"] == "email" and .config["id.token.claim"] == "true" and .config["access.token.claim"] == "true" and .config["userinfo.token.claim"] == "true")
  ' >/dev/null

admin_curl "https://${host}/admin/realms/${REALM}/clients?clientId=aap-demo-ao" \
  | jq -e '
    (. | length == 1) and
    .[0].clientId == "aap-demo-ao" and
    any(.[0].protocolMappers[]; .protocolMapper == "oidc-audience-mapper" and .config["included.client.audience"] == "aap-demo-ao" and .config["access.token.claim"] == "true") and
    any(.[0].protocolMappers[]; .protocolMapper == "oidc-usermodel-property-mapper" and .config["claim.name"] == "preferred_username" and .config["id.token.claim"] == "true" and .config["access.token.claim"] == "true" and .config["userinfo.token.claim"] == "true") and
    any(.[0].protocolMappers[]; .protocolMapper == "oidc-usermodel-property-mapper" and .config["claim.name"] == "email" and .config["id.token.claim"] == "true" and .config["access.token.claim"] == "true" and .config["userinfo.token.claim"] == "true")
  ' >/dev/null

admin_curl "https://${host}/admin/realms/${REALM}/groups" \
  | jq -e '([.[].name] | sort) == ["aap-admins", "aap-auditors", "aap-developers", "aap-operators"]' >/dev/null

admin_curl "https://${host}/admin/realms/${REALM}/users?max=100" \
  | jq -e '
    ([.[].username] | sort) == ["aap-oidc-admin", "aap-oidc-auditor", "aap-oidc-developer", "aap-oidc-operator"] and
    all(.[]; (.firstName == "AAP OIDC") and (.lastName | type == "string" and length > 0))
  ' >/dev/null

echo "PASS: live Keycloak Route, readiness, discovery, active realm, groups, users, claims, and clients"
