#!/usr/bin/env bash
# Extract portal VM cert and add to macOS trusted root store

set -e

PORTAL_DIR="${PORTAL_DIR:-$HOME/.aap-demo/portal-vm}"
SSH_KEY="$PORTAL_DIR/id_ed25519"
CERT_PATH="$PORTAL_DIR/portal-cert.pem"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() {
  echo -e "${RED}ERROR: $*${NC}" >&2
  exit 1
}

info() {
  echo -e "${GREEN}INFO: $*${NC}"
}

warn() {
  echo -e "${YELLOW}WARN: $*${NC}"
}

# Check VM is running
if [ ! -f "$PORTAL_DIR/qemu.pid" ]; then
  error "Portal VM not running. Start with: ./deploy.sh"
fi

PID=$(cat "$PORTAL_DIR/qemu.pid")
if ! kill -0 "$PID" 2>/dev/null; then
  error "Portal VM process not found. PID $PID not running."
fi

# Check SSH key exists
if [ ! -f "$SSH_KEY" ]; then
  error "SSH key not found: $SSH_KEY"
fi

info "Extracting portal certificate from VM..."

# Extract cert via SSH
ssh -i "$SSH_KEY" \
    -p 2223 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    admin@localhost \
    'sudo cat /etc/portal/ssl/cert.pem' > "$CERT_PATH" 2>/dev/null

if [ ! -s "$CERT_PATH" ]; then
  error "Failed to extract certificate from VM"
fi

info "Certificate saved to: $CERT_PATH"

# Show cert details
echo ""
info "Certificate details:"
openssl x509 -in "$CERT_PATH" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || \
  openssl x509 -in "$CERT_PATH" -noout -subject -issuer -dates

echo ""
warn "About to add certificate to macOS System Keychain (requires sudo)"
echo "Press Enter to continue, Ctrl-C to cancel..."
read -r

# Add to macOS System Keychain as trusted
sudo security add-trusted-cert \
  -d \
  -r trustRoot \
  -k /Library/Keychains/System.keychain \
  "$CERT_PATH"

info "✓ Certificate added to System Keychain and trusted for SSL"
echo ""
info "Browser changes:"
echo "  - Chrome/Safari: Restart browser to pick up new trusted cert"
echo "  - Firefox: Uses own cert store - still shows warning (use Chrome/Safari)"
echo ""
info "To verify: open https://localhost:8443 in Chrome/Safari"
echo "To remove later: open Keychain Access > System > Certificates > search 'portal'"
