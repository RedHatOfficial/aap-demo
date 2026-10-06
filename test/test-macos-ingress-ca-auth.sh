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
osascript() {
  printf '<%s>\n' "$@" >"$TEST_OSASCRIPT_ARGS"
  cat >"$TEST_OSASCRIPT_SOURCE"
  [ "${TEST_OSASCRIPT_FAIL:-false}" != true ]
}

# A successful Keychain verification after the helper reports import success.
security() {
  [ "${1:-}" = "find-certificate" ]
}

sudo() { return 1; }
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

check "forced macOS import succeeds after native authorization" test "$import_status" -eq 0
check "forced macOS import does not purge outside the authorization prompt" test "$PURGE_CALLED" = false
check "native authorization tool receives the certificate path as a separate argument" \
  grep -Fxq "<$CERT_PATH>" "$TEST_OSASCRIPT_ARGS"
check "authorization script requests administrator privileges" \
  grep -Fq 'with administrator privileges' "$TEST_OSASCRIPT_SOURCE"
check "authorization script quotes the certificate path as shell data" \
  grep -Fq 'quoted form of (item 1 of argv)' "$TEST_OSASCRIPT_SOURCE"
check "certificate path is not interpolated into the AppleScript source" \
  test "$(grep -Foc "$CERT_PATH" "$TEST_OSASCRIPT_SOURCE" || true)" -eq 0

# A certificate already trusted by the host must not open an authorization dialog.
rm -f "$TEST_OSASCRIPT_ARGS" "$TEST_OSASCRIPT_SOURCE"
_ingress_ca_fully_trusted() { return 0; }
import_ingress_ca_certificate "$CERT_PATH" >/dev/null 2>&1
trusted_status=$?
check "already-trusted certificate succeeds without authorization" test "$trusted_status" -eq 0
check "already-trusted certificate does not invoke osascript" test ! -e "$TEST_OSASCRIPT_ARGS"

# Canceling the native prompt is a soft failure for trust import, not a password error.
_ingress_ca_fully_trusted() { return 1; }
export TEST_OSASCRIPT_FAIL=true
TEST_TLS_TRUSTED=false
import_ingress_ca_certificate "$CERT_PATH" true "$CERT_PATH" aap-demo.apps.example.test >/dev/null 2>&1
cancel_status=$?
check "cancelled authorization reports trust import failure" test "$cancel_status" -ne 0
check "cancelled authorization gives a useful recovery message" \
  grep -Fq 'authorization was cancelled or failed' <(import_ingress_ca_certificate "$CERT_PATH" true "$CERT_PATH" aap-demo.apps.example.test 2>&1 >/dev/null || true)

exit "$failures"
