#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-keycloak-configure.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

STATE_DIR="$TEST_DIR/state"
STUB_DIR="$TEST_DIR/bin"
CURL_LOG="$TEST_DIR/curl.log"
mkdir -p "$STATE_DIR" "$STUB_DIR"
printf '%s' 'aap-client-test-value' >"$STATE_DIR/aap-client-secret"
printf '%s' 'ao-client-test-value' >"$STATE_DIR/ao-client-secret"

cat >"$STUB_DIR/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
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
  *'/realms/aap-lab'*) printf '%s' '{"public_key":"test-public-key"}' ;;
  *'-X POST'*'/authenticators/'*) printf '%s' '{"id":42}' ;;
  *'/authenticator_maps/?authenticator=42'*) printf '%s' '{"results":[]}' ;;
  *'-X POST'*'/authenticator_maps/'*) printf '%s' '{}' ;;
  *'/authenticators/'*) printf '%s' '{"results":[]}' ;;
  *'/api/v1/auth/csrf_token'*) printf '%s' '{"csrf_token":"csrf-test"}' ;;
  *'-X POST'*'/api/v1/auth/login'*) printf '%s' '{"access_token":"ao-token"}' ;;
  *'-X POST'*'/api/v1/identity_providers'*) printf '%s' '{"id":"ao-id"}' ;;
  *'/api/v1/identity_providers'*) printf '%s' '{"resources":[]}' ;;
  *'/api/v1/groups'*) printf '%s' '{"resources":[]}' ;;
  *) echo "unexpected curl invocation: $*" >&2; exit 1 ;;
esac
EOF

chmod 700 "$STUB_DIR/kubectl" "$STUB_DIR/curl"

output="$({
  KEYCLOAK_INSECURE_TLS=true \
    KEYCLOAK_STATE_DIR="$STATE_DIR" \
    CURL_LOG="$CURL_LOG" \
    PATH="$STUB_DIR:$PATH" \
    NAMESPACE=aap-operator \
    bash "$ROOT_DIR/addons/keycloak/configure.sh" --target aap --map-groups --apply
} 2>&1)"

grep -q 'Created AAP authenticator: Keycloak lab' <<<"$output" || {
  echo "FAIL: mocked AAP authenticator was not created"
  echo "$output"
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
grep -q '/api/v1/auth/csrf_token' "$CURL_LOG" || {
  echo "FAIL: AO login did not request a CSRF token"
  cat "$CURL_LOG"
  exit 1
}
grep -q -- '-b ' "$CURL_LOG" || {
  echo "FAIL: AO login did not send the CSRF cookie"
  cat "$CURL_LOG"
  exit 1
}
grep -q 'X-CSRF-Token' "$ROOT_DIR/addons/keycloak/configure.sh" || {
  echo "FAIL: AO login did not send the CSRF header"
  exit 1
}
if grep -Eq 'ao-token|ao-admin-test|ao-client-test-value' "$CURL_LOG"; then
  echo "FAIL: AO credential appeared in curl arguments"
  cat "$CURL_LOG"
  exit 1
fi

echo "PASS: mocked Keycloak AAP and AO configure and group mapping"
