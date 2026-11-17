#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-keycloak-configure.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

STATE_DIR="$TEST_DIR/state"
STUB_DIR="$TEST_DIR/bin"
CURL_LOG="$TEST_DIR/curl.log"
KUBE_LOG="$TEST_DIR/kubectl.log"
APPLIED_SECRET="$TEST_DIR/applied-secret.yaml"
CA_SECRET_INPUT="$TEST_DIR/ca-secret-input.crt"
EXISTING_BUNDLE_FILE="$TEST_DIR/existing-bundle.crt"
mkdir -p "$STATE_DIR" "$STUB_DIR"
printf '%s' 'aap-client-test-value' >"$STATE_DIR/aap-client-secret"
printf '%s' 'ao-client-test-value' >"$STATE_DIR/ao-client-secret"
printf '%s' 'keycloak-admin-test-value' >"$STATE_DIR/admin-password"

cat >"$STUB_DIR/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${KUBE_LOG:-/dev/null}"
case "$*" in
  *"get aap -n aap-operator -o jsonpath={.items[0].metadata.name}"*) printf '%s' 'aap' ;;
  *"get aap aap -n aap-operator -o jsonpath={.spec.bundle_cacert_secret}"*)
    [ ! -s "$EXISTING_BUNDLE_FILE" ] || printf '%s' 'bundle-ca-secret'
    ;;
  *"get secret bundle-ca-secret -n aap-operator"*)
    if [ -s "$EXISTING_BUNDLE_FILE" ]; then
      case "$*" in *jsonpath*) base64 <"$EXISTING_BUNDLE_FILE" | tr -d '\n' ;; esac
    else
      exit 1
    fi
    ;;
  *"create secret generic bundle-ca-secret"*)
    ca_file=""
    for arg in "$@"; do
      case "$arg" in --from-file=bundle-ca.crt=*) ca_file="${arg#--from-file=bundle-ca.crt=}" ;; esac
    done
    cp "$ca_file" "$CA_SECRET_INPUT"
    printf 'apiVersion: v1\nkind: Secret\n'
    ;;
  *"apply -f -"*)
    cat >"$APPLIED_SECRET"
    [ ! -s "$CA_SECRET_INPUT" ] || cp "$CA_SECRET_INPUT" "$EXISTING_BUNDLE_FILE"
    ;;
  *"patch aap aap -n aap-operator"*) : ;;
  *"get deployments -n aap-operator -l app.kubernetes.io/component=aap-gateway -o name"*) printf '%s\n' 'deployment/aap-gateway' ;;
  *"rollout status deployment/aap-gateway"*) : ;;
  *"get namespace aap-demo-keycloak"*"managed-by"*) printf '%s' 'aap-demo-keycloak' ;;
  *"get namespace aap-demo-keycloak"*"part-of"*) printf '%s' 'aap-demo' ;;
  *"get route keycloak"*) printf '%s' 'keycloak.apps.example.test' ;;
  *"get route aap"*) printf '%s' 'aap.apps.example.test' ;;
  *"get route -n automation-orchestrator"*) printf '%s' 'ao.apps.example.test' ;;
  *"get secret aap-admin-password"*) printf '%s' 'YWFwLWFkbWluLXRlc3Q=' ;;
  *"get secret automation-orchestrator-initial-admin-password"*) printf '%s' 'YW8tYWRtaW4tdGVzdA==' ;;
  *) echo "unexpected kubectl invocation: $*" >&2; exit 1 ;;
esac
EOF

cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CURL_LOG"
case "$*" in
  *'/realms/master/protocol/openid-connect/token'*) printf '%s' '{"access_token":"keycloak-admin-token"}' ;;
  *'/admin/realms/aap-lab/clients?clientId=aap-demo-aap'*) printf '%s' '[{"id":"aap-client-id"}]' ;;
  *'-X PUT'*'/admin/realms/aap-lab/clients/aap-client-id'*) printf '%s' '{}' ;;
  *'/admin/realms/aap-lab/clients/aap-client-id'*) printf '%s' '{"id":"aap-client-id","clientId":"aap-demo-aap","redirectUris":[],"webOrigins":[],"attributes":{}}' ;;
  *'/realms/aap-lab'*) printf '%s' '{"public_key":"test-public-key"}' ;;
  *'-X POST'*'/authenticators/'*)
    body_file=""
    for arg in "$@"; do
      case "$arg" in @*) body_file="${arg#@}" ;; esac
    done
    jq -e ".configuration.ADDITIONAL_UNVERIFIED_ARGS.VERIFY_SSL == $AAP_EXPECT_VERIFY_SSL" "$body_file" >/dev/null || {
      echo "AAP Keycloak authenticator VERIFY_SSL did not match the expected test value" >&2
      exit 1
    }
    printf '%s' '{"id":42}'
    ;;
  *'/authenticators/42/'*) printf '%s' '{"id":42,"slug":"aap-authenticator-slug"}' ;;
  *'/authenticator_maps/?authenticator=42'*) printf '%s' '{"results":[]}' ;;
  *'-X POST'*'/authenticator_maps/'*) printf '%s' '{}' ;;
  *'/authenticators/'*) printf '%s' '{"results":[]}' ;;
  *'-X POST'*'/api/v1/auth/login'*) printf '%s' '{"access_token":"ao-token"}' ;;
  *'-X POST'*'/api/v1/identity_providers'*) printf '%s' '{"id":"ao-id"}' ;;
  *'/api/v1/identity_providers'*) printf '%s' '{"resources":[]}' ;;
  *'/api/v1/groups'*) printf '%s' '{"resources":[]}' ;;
  *) echo "unexpected curl invocation: $*" >&2; exit 1 ;;
esac
EOF

chmod 700 "$STUB_DIR/kubectl" "$STUB_DIR/curl"

grep -Fq 'bundle_cacert_secret' "$ROOT_DIR/addons/keycloak/configure.sh" || {
  echo "FAIL: AAP must trust the Keycloak route CA through its managed CA bundle"
  exit 1
}
grep -Fq 'bundle-ca.crt' "$ROOT_DIR/addons/keycloak/configure.sh" || {
  echo "FAIL: AAP CA secret must use the documented bundle-ca.crt key"
  exit 1
}

output="$({
  KEYCLOAK_INSECURE_TLS=true \
    KEYCLOAK_CA_FILE="$TEST_DIR/no-ca-file" \
    KEYCLOAK_STATE_DIR="$STATE_DIR" \
    CURL_LOG="$CURL_LOG" \
    KUBE_LOG="$KUBE_LOG" \
    APPLIED_SECRET="$APPLIED_SECRET" \
    CA_SECRET_INPUT="$CA_SECRET_INPUT" \
    EXISTING_BUNDLE_FILE="$EXISTING_BUNDLE_FILE" \
    AAP_EXPECT_VERIFY_SSL=false \
    PATH="$STUB_DIR:$PATH" \
    NAMESPACE=aap-operator \
    bash "$ROOT_DIR/addons/keycloak/configure.sh" --target aap --map-groups --apply
} 2>&1)"

grep -q 'Created AAP authenticator: Keycloak lab' <<<"$output" || {
  echo "FAIL: mocked AAP authenticator was not created"
  echo "$output"
  exit 1
}
grep -q 'Set AAP Gateway callback: https://aap.apps.example.test/api/gateway/social/complete/aap-authenticator-slug/' <<<"$output" || {
  echo "FAIL: AAP Gateway callback was not derived from the authenticator slug"
  echo "$output"
  exit 1
}
grep -q -- '-X PUT' "$CURL_LOG" || {
  echo "FAIL: Keycloak AAP client redirect URI was not updated"
  cat "$CURL_LOG"
  exit 1
}
test "$(grep -c 'authenticator=42' "$CURL_LOG")" -eq 1 || {
  echo "FAIL: fresh authenticator ID was not used for group-map lookup"
  cat "$CURL_LOG"
  exit 1
}
test "$(grep -c 'authenticator_maps/' "$CURL_LOG")" -eq 5 || {
  echo "FAIL: expected one lookup and four AAP group-map requests"
  cat "$CURL_LOG"
  exit 1
}
if grep -Eq 'aap-client-test-value|aap-admin-test' "$CURL_LOG"; then
  echo "FAIL: client secret or admin password appeared in curl arguments"
  cat "$CURL_LOG"
  exit 1
fi

openssl req -x509 -newkey rsa:2048 -keyout "$TEST_DIR/ca-key.pem" -out "$TEST_DIR/ingress-ca.crt" \
  -sha256 -days 1 -nodes -subj '/CN=Keycloak test ingress CA' >/dev/null 2>&1
if ! secure_output="$({
  KEYCLOAK_INSECURE_TLS=false \
    KEYCLOAK_CA_FILE="$TEST_DIR/ingress-ca.crt" \
    KEYCLOAK_STATE_DIR="$STATE_DIR" \
    CURL_LOG="$CURL_LOG" \
    KUBE_LOG="$KUBE_LOG" \
    APPLIED_SECRET="$APPLIED_SECRET" \
    CA_SECRET_INPUT="$CA_SECRET_INPUT" \
    EXISTING_BUNDLE_FILE="$EXISTING_BUNDLE_FILE" \
    AAP_EXPECT_VERIFY_SSL=true \
    PATH="$STUB_DIR:$PATH" \
    NAMESPACE=aap-operator \
    bash "$ROOT_DIR/addons/keycloak/configure.sh" --target aap --apply
} 2>&1)"; then
  echo "FAIL: secure AAP configure did not complete"
  echo "$secure_output"
  cat "$KUBE_LOG"
  exit 1
fi
grep -q 'AAP Gateway trusts the Keycloak ingress CA' <<<"$secure_output" || {
  echo "FAIL: secure AAP configure did not report CA trust"
  echo "$secure_output"
  exit 1
}
grep -q 'bundle-ca-secret' "$KUBE_LOG" || {
  echo "FAIL: AAP bundle CA Secret was not created"
  cat "$KUBE_LOG"
  exit 1
}
grep -q 'patch aap aap -n aap-operator' "$KUBE_LOG" || {
  echo "FAIL: AAP custom resource was not linked to the CA bundle Secret"
  cat "$KUBE_LOG"
  exit 1
}
grep -q 'rollout status deployment/aap-gateway' "$KUBE_LOG" || {
  echo "FAIL: configuration did not wait for the Gateway CA trust rollout"
  cat "$KUBE_LOG"
  exit 1
}
cmp -s "$TEST_DIR/ingress-ca.crt" "$CA_SECRET_INPUT" || {
  echo "FAIL: Keycloak ingress CA was not included in the AAP bundle Secret"
  exit 1
}

openssl req -x509 -newkey rsa:2048 -keyout "$TEST_DIR/other-ca-key.pem" -out "$TEST_DIR/other-ca.crt" \
  -sha256 -days 1 -nodes -subj '/CN=Existing AAP CA' >/dev/null 2>&1
cat "$TEST_DIR/other-ca.crt" "$TEST_DIR/ingress-ca.crt" >"$EXISTING_BUNDLE_FILE"
if ! merge_output="$({
  KEYCLOAK_INSECURE_TLS=false \
    KEYCLOAK_CA_FILE="$TEST_DIR/ingress-ca.crt" \
    KEYCLOAK_STATE_DIR="$STATE_DIR" \
    CURL_LOG="$CURL_LOG" \
    KUBE_LOG="$KUBE_LOG" \
    APPLIED_SECRET="$APPLIED_SECRET" \
    CA_SECRET_INPUT="$CA_SECRET_INPUT" \
    EXISTING_BUNDLE_FILE="$EXISTING_BUNDLE_FILE" \
    AAP_EXPECT_VERIFY_SSL=true \
    PATH="$STUB_DIR:$PATH" \
    NAMESPACE=aap-operator \
    bash "$ROOT_DIR/addons/keycloak/configure.sh" --target aap --apply
} 2>&1)"; then
  echo "FAIL: merging an existing AAP CA bundle failed"
  echo "$merge_output"
  cat "$KUBE_LOG"
  exit 1
fi
test "$(grep -c '^-----BEGIN CERTIFICATE-----$' "$CA_SECRET_INPUT")" -eq 2 || {
  echo "FAIL: existing AAP CA was not preserved or Keycloak CA was duplicated"
  exit 1
}
test "$(grep -c 'patch aap aap -n aap-operator' "$KUBE_LOG")" -eq 1 || {
  echo "FAIL: an already-linked AAP CA bundle was patched again"
  cat "$KUBE_LOG"
  exit 1
}

if ! grep -q 'scopes:"openid"' "$ROOT_DIR/addons/keycloak/configure.sh"; then
  echo "FAIL: AO must request only the universally valid OIDC scope"
  exit 1
fi
if ! grep -q 'scopes=\$scopes' "$ROOT_DIR/addons/keycloak/configure.sh"; then
  echo "FAIL: AO updates must apply the current desired scopes"
  exit 1
fi

if ! ao_output="$({
  KEYCLOAK_INSECURE_TLS=true \
    KEYCLOAK_STATE_DIR="$STATE_DIR" \
    CURL_LOG="$CURL_LOG" \
    PATH="$STUB_DIR:$PATH" \
    NAMESPACE=aap-operator \
    bash "$ROOT_DIR/addons/keycloak/configure.sh" --target ao --apply
} 2>&1)"; then
  echo "FAIL: mocked AO configure command failed"
  echo "$ao_output"
  cat "$CURL_LOG"
  exit 1
fi

grep -q 'Created AO identity provider: Keycloak lab' <<<"$ao_output" || {
  echo "FAIL: mocked AO identity provider was not created"
  echo "$ao_output"
  exit 1
}
if grep -q '/api/v1/auth/csrf_token' "$CURL_LOG"; then
  echo "FAIL: AO bearer login must not request a cookie-flow CSRF token"
  cat "$CURL_LOG"
  exit 1
fi
grep -q -- '-X POST https://ao.apps.example.test/api/v1/auth/login' "$CURL_LOG" || {
  echo "FAIL: AO bearer login request was not sent directly"
  cat "$CURL_LOG"
  exit 1
}
if grep -Eq 'ao-token|ao-admin-test|ao-client-test-value' "$CURL_LOG"; then
  echo "FAIL: AO credential appeared in curl arguments"
  cat "$CURL_LOG"
  exit 1
fi

echo "PASS: mocked Keycloak AAP and AO configure and group mapping"
