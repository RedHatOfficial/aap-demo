#!/usr/bin/env bash
# Verify macOS ingress CA replacement uses the native authorization dialog.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=includes/ingress-ca-trust.sh
source "${SCRIPT_DIR}/../includes/ingress-ca-trust.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

CERT_PATH="$TMPDIR/CRC ingress CA's replacement.crt"
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'test-certificate' '-----END CERTIFICATE-----' >"$CERT_PATH"

export TEST_OSASCRIPT_ARGS="$TMPDIR/osascript-args"
export TEST_OSASCRIPT_SOURCE="$TMPDIR/osascript-source"
export TEST_SUDO_ARGS="$TMPDIR/sudo-args"
OSASCRIPT_CALLS=0
SUDO_CALLS=0
: >"$TEST_SUDO_ARGS"
osascript() {
  OSASCRIPT_CALLS=$((OSASCRIPT_CALLS + 1))
  printf '<%s>\n' "$@" >"$TEST_OSASCRIPT_ARGS"
  cat >"$TEST_OSASCRIPT_SOURCE"
  [ "${TEST_OSASCRIPT_FAIL:-false}" != true ]
}

sudo() {
  SUDO_CALLS=$((SUDO_CALLS + 1))
  printf '<%s>\n' "$@" >>"$TEST_SUDO_ARGS"
  if [ "${1:-}" = security ] && [ "${2:-}" = delete-certificate ]; then
    return 1
  fi
  if [ "${TEST_SUDO_FAIL:-false}" = true ]; then
    return 1
  fi
  [ "${1:-}" = security ] && [ "${2:-}" = add-trusted-cert ]
}

# A successful Keychain verification after the helper reports import success.
security() {
  [ "${1:-}" = "find-certificate" ]
}

uname() { printf '%s\n' Darwin; }
_ingress_ca_macos_server_certificate_trusted() {
  [ "${TEST_TLS_TRUSTED:-false}" = true ]
}

PURGE_CALLED=false
_purge_ingress_ca_trust() {
  PURGE_CALLED=true
}

failures=0
check() {
  local description="$1"
  shift
  if "$@"; then
    printf '✓ %s\n' "$description"
  else
    printf '✗ %s\n' "$description"
    failures=$((failures + 1))
  fi
}

TEST_TLS_TRUSTED=true
import_ingress_ca_certificate "$CERT_PATH" true "$CERT_PATH" aap-demo.apps.example.test >/dev/null 2>&1
import_status=$?

check "forced macOS import succeeds after sudo authorization" test "$import_status" -eq 0
check "forced macOS import does not purge outside the authorization prompt" test "$PURGE_CALLED" = false
check "sudo invokes security add-trusted-cert" \
  grep -Fqx '<security>' "$TEST_SUDO_ARGS" && grep -Fq '<add-trusted-cert>' "$TEST_SUDO_ARGS"
check "sudo imports into the system keychain" \
  grep -Fq '</Library/Keychains/System.keychain>' "$TEST_SUDO_ARGS"
check "forced macOS import does not invoke AppleScript authorization" test "$OSASCRIPT_CALLS" -eq 0
initial_sudo_calls=$SUDO_CALLS

# A certificate already trusted by the host must not open an authorization dialog.
rm -f "$TEST_OSASCRIPT_ARGS" "$TEST_OSASCRIPT_SOURCE"
_ingress_ca_fully_trusted() { return 0; }
import_ingress_ca_certificate "$CERT_PATH" >/dev/null 2>&1
trusted_status=$?
check "already-trusted certificate succeeds without authorization" test "$trusted_status" -eq 0
check "already-trusted certificate does not invoke sudo" test "$SUDO_CALLS" -eq "$initial_sudo_calls"

# Failed administrator authorization is a soft failure for trust import.
_ingress_ca_fully_trusted() { return 1; }
export TEST_OSASCRIPT_FAIL=true
export TEST_SUDO_FAIL=true
TEST_TLS_TRUSTED=false
import_ingress_ca_certificate "$CERT_PATH" true "$CERT_PATH" aap-demo.apps.example.test >/dev/null 2>&1
cancel_status=$?
check "failed macOS authorization reports import failure" test "$cancel_status" -ne 0
check "failed macOS authorization gives a useful recovery message" \
  grep -Fq 'Could not add CA to macOS keychain' <(import_ingress_ca_certificate "$CERT_PATH" true "$CERT_PATH" aap-demo.apps.example.test 2>&1 >/dev/null || true)

exit "$failures"
