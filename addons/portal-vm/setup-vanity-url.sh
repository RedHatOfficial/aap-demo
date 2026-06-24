#!/usr/bin/env bash
# Add 'portal' vanity hostname pointing to portal VM IP

set -e

PORTAL_DIR="${PORTAL_DIR:-$HOME/.aap-demo/portal-vm}"
SSH_KEY="$PORTAL_DIR/id_ed25519"

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

info "Getting portal VM IP address..."

# Get IP from VM
VM_IP=$(ssh -i "$SSH_KEY" \
            -p 2223 \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 \
            -o LogLevel=ERROR \
            admin@localhost \
            "hostname -I | awk '{print \$1}'" 2>/dev/null)

if [ -z "$VM_IP" ]; then
  error "Failed to get VM IP address"
fi

info "Portal VM IP: $VM_IP"

# Check if entry already exists
if grep -q "^$VM_IP.*portal$" /etc/hosts 2>/dev/null; then
  info "✓ /etc/hosts already has entry for 'portal'"
  echo ""
  info "Access portal at: https://portal:8443"
  exit 0
fi

# Add to /etc/hosts
echo ""
warn "About to add '$VM_IP portal' to /etc/hosts (requires sudo)"
echo "Press Enter to continue, Ctrl-C to cancel..."
read -r

echo "$VM_IP portal" | sudo tee -a /etc/hosts >/dev/null

info "✓ Added 'portal' to /etc/hosts"
echo ""
info "Access portal at: https://portal:8443"
echo ""
info "To remove later:"
echo "  sudo sed -i '' '/portal$/d' /etc/hosts"
