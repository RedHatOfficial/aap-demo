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
[ "$available" = "1" ] || { echo "FAIL: Keycloak deployment is not ready"; exit 1; }

host="$(kubectl get route keycloak -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
[ -n "$host" ] || { echo "FAIL: Keycloak Route has no host"; exit 1; }

curl -skf "https://${host}/realms/${REALM}/.well-known/openid-configuration" \
  | jq -e '.issuer and .authorization_endpoint and .token_endpoint and .jwks_uri' >/dev/null

kubectl get secret keycloak-realm -n "$NAMESPACE" \
  -o jsonpath='{.data.aap-lab-realm\.json}' | base64 -d \
  | jq -e '
    ([.clients[].clientId] | sort) == ["aap-demo-aap", "aap-demo-ao"] and
    ([.groups[].name] | sort) == ["aap-admins", "aap-operators"] and
    ([.users[].username] | sort) == ["aap-oidc-admin", "aap-oidc-operator"]
  ' >/dev/null

echo "PASS: live Keycloak Route, readiness, discovery, realm, groups, users, and clients"
