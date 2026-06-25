#!/bin/bash
# Import portal VM certificate to macOS keychain
#
# Run this AFTER portal finishes booting to eliminate SSL warnings
# in browser when accessing https://localhost:8443

set -e

PORTAL_DIR="${PORTAL_DIR:-$HOME/.aap-demo/portal-vm}"

# Check portal is running
if ! curl -ks https://localhost:8443 -o /dev/null -w "%{http_code}" | grep -q 200; then
  echo "ERROR: Portal not responding at https://localhost:8443"
  echo "Wait for portal to finish booting, then try again"
  exit 1
fi

echo "Fetching portal certificate via openssl..."

# Extract cert from HTTPS connection
openssl s_client -connect localhost:8443 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM >"$PORTAL_DIR/portal.crt"

echo "Certificate saved to: $PORTAL_DIR/portal.crt"
echo ""
echo "Certificate details:"
openssl x509 -in "$PORTAL_DIR/portal.crt" -noout -subject -issuer -dates
echo ""
echo "Adding certificate as trusted root to eliminate browser SSL warnings..."
echo ""
echo "Portal uses a self-signed certificate, which triggers 'Not Secure' warnings"
echo "in browsers. Adding this certificate to your user keychain marks it as trusted,"
echo "allowing secure access to https://localhost:8443 without warnings."
echo ""
echo "A popup will appear asking for your macOS password to authorize the trust change."
echo ""

# Add to user keychain as trusted (triggers GUI password prompt)
security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db "$PORTAL_DIR/portal.crt"

echo "✓ Certificate added to macOS keychain"
echo ""
echo "Restart browser to clear SSL warning"
echo "Portal should now be accessible at https://localhost:8443 without warnings"
