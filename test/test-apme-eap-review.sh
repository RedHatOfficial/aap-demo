#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${SCRIPT_DIR}/addons/apme-eap/deploy.yaml"
LIB="${SCRIPT_DIR}/addons/apme-eap/lib.sh"

bash -n "${SCRIPT_DIR}/addons/apme-eap/deploy.sh" "${LIB}"

for placeholder in AAP_HOST_URL AAP_TOKEN OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET BACKEND_SECRET POSTGRES_PASSWORD; do
  if grep -q "\${${placeholder}}" "${TEMPLATE}"; then
    echo "undeclared template placeholder remains: ${placeholder}" >&2
    exit 1
  fi
done

grep -q 'kind: RoleBinding' "${LIB}"
grep -q 'cluster-admin' "${LIB}" && {
  echo "APME deploy helper must not grant cluster-admin" >&2
  exit 1
}
grep -q 'APME_TOKEN_DURATION:-2h' "${LIB}"
grep -q 'apme_cleanup_openshift_deploy_token' "${SCRIPT_DIR}/addons/apme-eap/deploy.sh"

echo "✓ APME template placeholders and deploy-token scope are safe"
