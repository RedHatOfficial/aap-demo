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
if [ -f "$admin_password_file" ]; then
  admin_bytes="$(wc -c <"$admin_password_file" | tr -d ' ')"
  admin_last_byte="$(od -An -t x1 -N 1 -j $((admin_bytes - 1)) "$admin_password_file" | tr -d ' ')"
  [ "$admin_last_byte" != "0a" ] || {
    echo "FAIL: admin password file ends with newline"
    exit 1
  }
fi

curl -skf "https://${host}/realms/${REALM}/.well-known/openid-configuration" \
  | jq -e '.issuer and .authorization_endpoint and .token_endpoint and .jwks_uri' >/dev/null

kubectl get secret keycloak-realm -n "$NAMESPACE" \
  -o jsonpath='{.data.aap-lab-realm\.json}' | base64 -d \
  | jq -e '
    ([.clients[].clientId] | sort) == ["aap-demo-aap", "aap-demo-ao"] and
    all(.clients[]; . as $client |
      any(.protocolMappers[]; .protocolMapper == "oidc-audience-mapper" and .config["included.client.audience"] == $client.clientId) and
      any(.protocolMappers[]; .protocolMapper == "oidc-usermodel-property-mapper" and .config["claim.name"] == "preferred_username") and
      any(.protocolMappers[]; .protocolMapper == "oidc-usermodel-property-mapper" and .config["claim.name"] == "email")
    ) and
    ([.groups[].name] | sort) == ["aap-admins", "aap-auditors", "aap-developers", "aap-operators"] and
    ([.users[].username] | sort) == ["aap-oidc-admin", "aap-oidc-auditor", "aap-oidc-developer", "aap-oidc-operator"] and
    all(.users[]; (.firstName == "AAP OIDC") and (.lastName | type == "string" and length > 0))
  ' >/dev/null

echo "PASS: live Keycloak Route, readiness, discovery, realm, groups, users, claims, and clients"
