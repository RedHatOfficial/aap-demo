#!/usr/bin/env bash
# Regression: a CA present in System Keychain is not necessarily trusted for TLS.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=includes/ingress-ca-trust.sh
source "${SCRIPT_DIR}/../includes/ingress-ca-trust.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

CA_CERT="$TMPDIR/ingress-ca.crt"
CA_KEY="$TMPDIR/ingress-ca.key"
LEAF_KEY="$TMPDIR/router.key"
LEAF_CSR="$TMPDIR/router.csr"
LEAF_CERT="$TMPDIR/router.crt"
EXTENSIONS="$TMPDIR/router-extensions.cnf"
printf '%s\n' \
  '[server_cert]' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth' \
  'subjectAltName=DNS:*.apps.127.0.0.1.nip.io' >"$EXTENSIONS"
openssl req -x509 -newkey rsa:2048 -keyout "$CA_KEY" -out "$CA_CERT" \
  -days 2 -nodes -subj '/CN=ingress-ca' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
openssl req -newkey rsa:2048 -keyout "$LEAF_KEY" -out "$LEAF_CSR" \
  -nodes -subj '/CN=*.apps.127.0.0.1.nip.io' >/dev/null 2>&1
openssl x509 -req -in "$LEAF_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" \
  -CAcreateserial -out "$LEAF_CERT" -days 1 \
  -extfile "$EXTENSIONS" -extensions server_cert >/dev/null 2>&1

export AAP_DEMO_CONFIG_DIR="$TMPDIR/config"
mkdir -p "$AAP_DEMO_CONFIG_DIR"
cp "$CA_CERT" "$AAP_DEMO_CONFIG_DIR/crc-ingress-ca.crt"
TEST_OS_TRUSTED=false
OSASCRIPT_CALLS=0
VERIFY_ARGS="$TMPDIR/verify-args"

uname() { printf '%s\n' Darwin; }

# Model the cluster secret fetch while keeping the production install/repair path real.
_fetch_ingress_ca_from_cluster() {
  cp "$CA_CERT" "$1"
  if [ -n "${2:-}" ]; then cp "$LEAF_CERT" "$2"; fi
}

# Keychain lookup finds the certificate, but TLS validation reflects its actual trust state.
security() {
  case "${1:-}" in
    find-certificate)
      cat "$CA_CERT"
      return 0
      ;;
    verify-cert)
      printf '<%s>\n' "$@" >"$VERIFY_ARGS"
      [ "$TEST_OS_TRUSTED" = true ]
      return
      ;;
    *)
      return 1
      ;;
  esac
}

# Simulate the terminal authorization operation changing macOS keychain state.
SUDO_CALLS=0
sudo() {
  SUDO_CALLS=$((SUDO_CALLS + 1))
  case "${2:-}" in
    delete-certificate) return 1 ;;
    add-trusted-cert) return 0 ;;
    *) return 1 ;;
  esac
}

osascript() {
  OSASCRIPT_CALLS=$((OSASCRIPT_CALLS + 1))
  cat >/dev/null
  TEST_OS_TRUSTED=true
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

install_ingress_ca_trust >"$TMPDIR/untrusted-output" 2>&1
check "present but TLS-untrusted CA triggers sudo authorization" test "$SUDO_CALLS" -eq 2
check "repair reports that it is updating ingress CA trust" \
  grep -Fq 'Trusting ingress CA...' "$TMPDIR/untrusted-output"
if grep -Fq 'Ingress CA trusted (macOS keychain)' "$TMPDIR/untrusted-output"; then
  check "repair does not report TLS trust for a Keychain-only CA" false
else
  check "repair does not report TLS trust for a Keychain-only CA" true
fi
check "repair reports the failed live TLS trust verification" \
  grep -Fq 'automatic trust import failed' "$TMPDIR/untrusted-output"
check "repair verifies the live certificate with SSL policy and wildcard hostname" \
  grep -Fxq '<-p>' "$VERIFY_ARGS" && grep -Fxq '<ssl>' "$VERIFY_ARGS" \
  && grep -Fxq '<-s>' "$VERIFY_ARGS" \
  && grep -Fxq '<aap-demo-cert-check.apps.127.0.0.1.nip.io>' "$VERIFY_ARGS"

OSASCRIPT_CALLS=0
SUDO_CALLS=0
TEST_OS_TRUSTED=true
install_ingress_ca_trust >"$TMPDIR/trusted-output" 2>&1
check "TLS-trusted CA does not prompt again" test "$OSASCRIPT_CALLS" -eq 0
check "TLS-trusted CA does not invoke sudo again" test "$SUDO_CALLS" -eq 0
check "repair reports already-trusted CA instead of silently skipping" \
  grep -Fq 'Ingress CA already trusted' "$TMPDIR/trusted-output"

TEST_OS_TRUSTED=false
if ingress_ca_trust_status "$AAP_DEMO_CONFIG_DIR/crc-ingress-ca.crt" >"$TMPDIR/status-untrusted" 2>&1; then
  check "status rejects a CA present in Keychain but not trusted for TLS" false
else
  check "status rejects a CA present in Keychain but not trusted for TLS" \
    grep -Eq 'System trust:[[:space:]]+not trusted' "$TMPDIR/status-untrusted"
fi

TEST_OS_TRUSTED=true
if ingress_ca_trust_status "$AAP_DEMO_CONFIG_DIR/crc-ingress-ca.crt" >"$TMPDIR/status-trusted" 2>&1; then
  check "status confirms TLS trust only after macOS verification succeeds" \
    grep -Eq 'Browser trust:[[:space:]]+trusted \(macOS keychain\)' "$TMPDIR/status-trusted"
else
  check "status confirms TLS trust only after macOS verification succeeds" false
fi

exit "$failures"
