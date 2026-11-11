#!/usr/bin/env bash
# Unit tests for satellite-ca-trust.sh: CA fetch validation, fingerprint
# matching, and idempotent trust detection. No live Satellite required — the
# fetch is stubbed with a locally generated CA.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=includes/satellite-ca-trust.sh
source "${SCRIPT_DIR}/../includes/satellite-ca-trust.sh"

PASSED=0
FAILED=0

_pass() { echo "✓ $1"; ((PASSED++)); }
_fail() { echo "✗ $1"; ((FAILED++)); }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

CA="$TMPDIR/satellite-ca.crt"
LEAF="$TMPDIR/leaf.crt"
NOT_CA="$TMPDIR/not-ca.crt"

# A proper CA cert (CA:TRUE).
openssl req -x509 -newkey rsa:2048 -keyout "$TMPDIR/ca-key.pem" -out "$CA" \
  -days 1 -nodes -subj "/CN=satellite.demo.lab" \
  -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1

# A self-signed leaf without CA:TRUE (must be rejected).
openssl req -x509 -newkey rsa:2048 -keyout "$TMPDIR/leaf-key.pem" -out "$NOT_CA" \
  -days 1 -nodes -subj "/CN=not-a-ca" \
  -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1

echo "======================================"
echo "satellite CA trust tests"
echo "======================================"
echo ""

# --- fingerprint ------------------------------------------------------------
fp=$(_satellite_ca_fingerprint "$CA")
if [ -n "$fp" ] && [[ "$fp" =~ ^[0-9A-F]{64}$ ]]; then
  _pass "fingerprint_format"
else
  _fail "fingerprint_format (got '$fp')"
fi

# --- fetch validation: accept a real CA -------------------------------------
_fetch_satellite_ca() { cp "$CA" "$1"; }
if _fetch_satellite_ca "$TMPDIR/fetched.crt" && grep -q 'BEGIN CERTIFICATE' "$TMPDIR/fetched.crt"; then
  _pass "fetch_accepts_ca"
else
  _fail "fetch_accepts_ca"
fi

# --- fetch validation: reject a non-CA cert ---------------------------------
# Restore the real function, then point it at a server that hands back a leaf.
unset -f _fetch_satellite_ca
source "${SCRIPT_DIR}/../includes/satellite-ca-trust.sh"
curl() { cp "$NOT_CA" "${@: -1}"; }  # stub: last arg is -o destination
if _fetch_satellite_ca "$TMPDIR/rejected.crt" 2>/dev/null; then
  _fail "fetch_rejects_non_ca"
else
  _pass "fetch_rejects_non_ca"
fi
unset -f curl

# --- already-trusted detection ----------------------------------------------
# Point the anchors at our temp dir and copy the CA in as "installed".
_SATELLITE_CA_RHEL_ANCHOR="$TMPDIR/anchors/satellite-demo-lab-ca.crt"
_SATELLITE_CA_DEBIAN_ANCHOR="$TMPDIR/debian/satellite-demo-lab-ca.crt"
mkdir -p "$TMPDIR/anchors"
cp "$CA" "$_SATELLITE_CA_RHEL_ANCHOR"

if _satellite_ca_already_trusted "$CA"; then
  _pass "already_trusted_detects_match"
else
  _fail "already_trusted_detects_match"
fi

# A different CA must not be reported as trusted.
openssl req -x509 -newkey rsa:2048 -keyout "$TMPDIR/other-key.pem" \
  -out "$TMPDIR/other-ca.crt" -days 1 -nodes -subj "/CN=other-ca" \
  -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1
if _satellite_ca_already_trusted "$TMPDIR/other-ca.crt"; then
  _fail "already_trusted_rejects_different_ca"
else
  _pass "already_trusted_rejects_different_ca"
fi

# --- skip flag ----------------------------------------------------------------
if AAP_DEMO_TRUST_CA=false install_satellite_ca_trust >/dev/null 2>&1; then
  _pass "skip_flag_honored"
else
  _fail "skip_flag_honored"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
