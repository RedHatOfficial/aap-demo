#!/usr/bin/env bash
# Unit tests for CURL_CA_BUNDLE export: never replace the system store with
# the standalone ingress CA.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=includes/ingress-ca-trust.sh
source "${SCRIPT_DIR}/../includes/ingress-ca-trust.sh"

PASSED=0
FAILED=0

_pass() {
  echo "✓ $1"
  ((PASSED++))
}

_fail() {
  echo "✗ $1"
  ((FAILED++))
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export AAP_DEMO_CONFIG_DIR="$TMPDIR"
DUMMY_CA="$TMPDIR/crc-ingress-ca.crt"

openssl req -x509 -newkey rsa:2048 -keyout "$TMPDIR/key.pem" -out "$DUMMY_CA" \
  -days 1 -nodes -subj "/CN=aap-demo-test-ca" >/dev/null 2>&1

echo "======================================"
echo "ingress CA export tests"
echo "======================================"
echo ""

# Dummy cert is not in the OS trust store, so export should build a combined bundle.
unset CURL_CA_BUNDLE SSL_CERT_FILE REQUESTS_CA_BUNDLE
_ingress_ca_export_env "$DUMMY_CA"

if [ "${CURL_CA_BUNDLE:-}" = "$DUMMY_CA" ]; then
  _fail "export_does_not_use_standalone_ca"
else
  _pass "export_does_not_use_standalone_ca"
fi

COMBINED=$(get_ingress_ca_cli_bundle_path)
if [ "${CURL_CA_BUNDLE:-}" = "$COMBINED" ] && [ -s "$COMBINED" ]; then
  _pass "export_uses_combined_bundle"
else
  _fail "export_uses_combined_bundle (CURL_CA_BUNDLE=${CURL_CA_BUNDLE:-unset})"
fi

if [ "$(grep -c 'BEGIN CERTIFICATE' "$COMBINED")" -ge 2 ] \
  && grep -qF "$(openssl x509 -in "$DUMMY_CA" -outform PEM | tail -n +2 | head -1)" "$COMBINED"; then
  _pass "combined_bundle_includes_ingress_ca"
else
  _fail "combined_bundle_includes_ingress_ca"
fi

# Public HTTPS must still verify when the combined bundle is in use.
if [ -n "${CURL_CA_BUNDLE:-}" ]; then
  if curl -fsSL -o /dev/null --max-time 15 -I "https://github.com" 2>/dev/null; then
    _pass "combined_bundle_verifies_github"
  else
    _fail "combined_bundle_verifies_github"
  fi
else
  _fail "combined_bundle_verifies_github (CURL_CA_BUNDLE unset)"
fi

# When the CA is already in the OS store, env vars must not override it.
REAL_CA="${HOME}/.aap-demo/crc-ingress-ca.crt"
if [ -f "$REAL_CA" ] && _ingress_ca_in_trust_store "$REAL_CA"; then
  unset CURL_CA_BUNDLE SSL_CERT_FILE REQUESTS_CA_BUNDLE
  export CURL_CA_BUNDLE="$REAL_CA" SSL_CERT_FILE="$REAL_CA"
  _ingress_ca_export_env "$REAL_CA"
  if [ -z "${CURL_CA_BUNDLE:-}" ] && [ -z "${SSL_CERT_FILE:-}" ]; then
    _pass "fedora_ca_trust_skips_env_override"
  else
    _fail "fedora_ca_trust_skips_env_override (CURL_CA_BUNDLE=${CURL_CA_BUNDLE:-unset})"
  fi
else
  echo "⊘ fedora_ca_trust_skips_env_override (ingress CA not in OS store on this host)"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
