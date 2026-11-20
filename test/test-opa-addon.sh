#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-aap-operator}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

command -v aap-demo >/dev/null 2>&1 || fail "aap-demo is not on PATH"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is not on PATH"
command -v curl >/dev/null 2>&1 || fail "curl is not on PATH"
command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"

aap-demo enable opa
trap 'aap-demo disable opa >/dev/null 2>&1 || true' EXIT

kubectl rollout status deployment/opa -n "$NAMESPACE" --timeout=180s
OPA_ROUTE="$(kubectl get route opa -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
[ -n "$OPA_ROUTE" ] || fail "OPA route is missing"
curl --fail --silent --insecure "https://${OPA_ROUTE}/health" >/dev/null \
  || fail "OPA health check failed"

AAP_ROUTE="$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
[ -n "$AAP_ROUTE" ] || fail "AAP route is missing"

AAP_PASSWORD="$(kubectl get secret -n "$NAMESPACE" aap-admin-password -o jsonpath='{.data.password}' | base64 -d)"
[ -n "$AAP_PASSWORD" ] || fail "AAP admin password is missing"

for template in \
  'OPA | Load Example Policies' \
  'OPA | Test Policies' \
  'OPA | Clear Policies' \
  'OPA | Demo Policy'; do
  encoded="$(printf '%s' "$template" | jq -sRr @uri)"
  curl --fail --silent --insecure -u "admin:${AAP_PASSWORD}" \
    "https://${AAP_ROUTE}/api/controller/v2/job_templates/?name=${encoded}" \
    | jq -e --arg name "$template" '.results | any(.[]; .name == $name)' >/dev/null \
    || fail "AAP template missing: $template"
done

trap - EXIT
aap-demo disable opa

if kubectl get deployment/opa -n "$NAMESPACE" >/dev/null 2>&1; then
  fail "OPA Deployment still exists after disable"
fi
if kubectl get service/opa -n "$NAMESPACE" >/dev/null 2>&1; then
  fail "OPA Service still exists after disable"
fi
if kubectl get route/opa -n "$NAMESPACE" >/dev/null 2>&1; then
  fail "OPA Route still exists after disable"
fi

echo "PASS: native OPA addon enable, health, templates, and cleanup"
