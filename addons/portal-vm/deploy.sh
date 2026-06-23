#!/usr/bin/env bash
# Deploy AAP Portal via QEMU x86 emulation on macOS
# ADDON_REQUIRES_AAP=true
#
# Uses qemu-system-x86_64 to run portal appliance qcow2 on ARM Mac.
# Slow (x86 emulation on ARM) but functional for dev/testing.
#
# Prerequisites:
#   - macOS (ARM or Intel)
#   - AAP deployed in aap-operator namespace
#   - Portal qcow2 downloaded from Red Hat Customer Portal
#   - brew install qemu cdrtools
#
# Usage:
#   ./deploy.sh          # Start portal VM
#   ./deploy.sh --delete # Stop and cleanup portal VM

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"
PORTAL_VM_NAME="${PORTAL_VM_NAME:-automation-portal}"
PORTAL_DIR="${PORTAL_DIR:-$HOME/.aap-demo/portal-vm}"
PORTAL_DIR_DISPLAY="${PORTAL_DIR/#$HOME/~}"  # Display version with ~

# Auto-discover qcow2 if not explicitly set
if [ -z "$QCOW2_PATH" ]; then
  QCOW2_PATTERN="$HOME/Downloads/ansible-automation-portal-*-x86_64.qcow2"
  # shellcheck disable=SC2086
  QCOW2_FOUND=$(ls $QCOW2_PATTERN 2>/dev/null | head -1)
  QCOW2_PATH="${QCOW2_FOUND:-$HOME/Downloads/ansible-automation-portal-2.2.1-x86_64.qcow2}"
fi

ACTION="${1:-deploy}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error() {
  echo -e "${RED}ERROR: $*${NC}" >&2
}

warn() {
  echo -e "${YELLOW}WARN: $*${NC}" >&2
}

info() {
  echo -e "${GREEN}INFO: $*${NC}"
}

cleanup() {
  if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
    info "Stopping portal VM..."

    # Kill QEMU process
    if [ -f "$PORTAL_DIR/qemu.pid" ]; then
      local pid
      pid=$(cat "$PORTAL_DIR/qemu.pid")
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 2
        kill -9 "$pid" 2>/dev/null || true
      fi
      rm -f "$PORTAL_DIR/qemu.pid"
    fi

    # Cleanup portal directory
    if [ -d "$PORTAL_DIR" ]; then
      info "Remove portal directory? (y/N)"
      read -r response
      if [ "$response" = "y" ] || [ "$response" = "Y" ]; then
        rm -rf "$PORTAL_DIR"
        info "✓ Portal VM cleaned up"
      else
        info "Kept portal directory: $PORTAL_DIR_DISPLAY"
      fi
    fi

    exit 0
  fi
}

get_host_ip() {
  # Get primary interface IP (en0)
  local host_ip
  host_ip=$(ifconfig en0 2>/dev/null | awk '/inet / {print $2}')

  if [ -z "$host_ip" ]; then
    # Fallback to any active interface with non-loopback IP
    host_ip=$(ifconfig | awk '/inet / && !/127.0.0.1/ {print $2; exit}')
  fi

  if [ -z "$host_ip" ]; then
    error "Failed to get host IP address"
    exit 1
  fi

  echo "$host_ip"
}

check_prerequisites() {
  # Check macOS
  if [ "$(uname -s)" != "Darwin" ]; then
    error "This script is for macOS only (detected: $(uname -s))"
    exit 1
  fi

  # Check QEMU
  if ! command -v qemu-system-x86_64 &>/dev/null; then
    error "qemu-system-x86_64 not found"
    echo ""
    echo "Install with: brew install qemu"
    exit 1
  fi

  # Check mkisofs (cdrtools)
  if ! command -v mkisofs &>/dev/null; then
    error "mkisofs not found"
    echo ""
    echo "Install with: brew install cdrtools"
    exit 1
  fi

  # Check socket_vmnet (keg-only, needs full path)
  if [ ! -f "/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet_client" ]; then
    error "socket_vmnet not found - required for portal to reach AAP"
    echo ""
    echo "Install and start:"
    echo "  brew install socket_vmnet"
    echo "  sudo brew services start socket_vmnet"
    echo ""
    echo "See: $SCRIPT_DIR/setup-networking.sh"
    exit 1
  fi

  # Detect socket location (Homebrew vs system)
  if [ -S "/opt/homebrew/var/run/socket_vmnet" ]; then
    VMNET_SOCKET="/opt/homebrew/var/run/socket_vmnet"
  elif [ -S "/var/run/socket_vmnet" ]; then
    VMNET_SOCKET="/var/run/socket_vmnet"
  else
    error "socket_vmnet socket not found"
    echo ""
    echo "Start service:"
    echo "  sudo brew services start socket_vmnet"
    echo ""
    echo "Verify running:"
    echo "  pgrep -x socket_vmnet"
    exit 1
  fi

  info "Using bridged networking via socket_vmnet ($VMNET_SOCKET)"

  # Check AAP deployed
  if ! kubectl get aap aap -n "$NAMESPACE" &>/dev/null; then
    error "AAP not deployed in namespace $NAMESPACE"
    echo ""
    echo "Deploy AAP first: ./aap-demo.sh deploy"
    exit 1
  fi

  # Check qcow2 exists
  if [ ! -f "$QCOW2_PATH" ]; then
    error "Portal qcow2 not found: $QCOW2_PATH"
    echo ""
    echo "Download from Red Hat Customer Portal:"
    echo "  https://access.redhat.com/downloads/content/480/ver=2.7/rhel---9/2.7/x86_64/product-software"
    echo ""
    echo "Look for: 'Ansible automation portal QCOW2'"
    echo "Save to: ~/Downloads/ansible-automation-portal-*-x86_64.qcow2"
    echo ""
    echo "Or set custom path: QCOW2_PATH=/path/to/portal.qcow2 $0"
    exit 1
  fi

  info "Using qcow2: $(basename "$QCOW2_PATH")"
}

get_aap_credentials() {
  local aap_route
  local admin_pass
  aap_route=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  admin_pass=$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

  if [ -z "$aap_route" ] || [ -z "$admin_pass" ]; then
    error "Failed to get AAP credentials"
    exit 1
  fi

  echo "$aap_route|$admin_pass"
}

create_oauth_app() {
  local aap_route="$1"
  local admin_pass="$2"

  info "Creating OAuth application in AAP..." >&2

  # Check if app exists
  local existing
  existing=$(curl -sk -u "admin:$admin_pass" \
    "https://$aap_route/api/gateway/v1/applications/?name=portal-vm" | jq -r '.results[0].id // empty')

  if [ -n "$existing" ]; then
    # Delete existing
    curl -sk -u "admin:$admin_pass" -X DELETE \
      "https://$aap_route/api/gateway/v1/applications/$existing/" >/dev/null 2>&1
  fi

  # Create OAuth app in AAP
  local oauth_data
  local client_id
  local client_secret
  oauth_data=$(curl -sk -u "admin:$admin_pass" \
    -X POST -H "Content-Type: application/json" \
    "https://$aap_route/api/gateway/v1/applications/" \
    -d '{
      "name": "portal-vm",
      "description": "Portal VM QEMU deployment",
      "client_type": "confidential",
      "authorization_grant_type": "authorization-code",
      "redirect_uris": "https://localhost:8443/api/auth/callback",
      "organization": 1
    }')

  client_id=$(echo "$oauth_data" | jq -r '.client_id' 2>/dev/null)
  client_secret=$(echo "$oauth_data" | jq -r '.client_secret' 2>/dev/null)

  if [ -z "$client_id" ] || [ "$client_id" = "null" ]; then
    error "Failed to create OAuth app"
    echo "$oauth_data" >&2
    exit 1
  fi

  echo "$client_id|$client_secret"
}

generate_cloud_init() {
  local aap_creds="$1"
  local oauth_creds="$2"
  local host_ip="$3"
  local aap_route="${aap_creds%%|*}"
  local aap_token="${aap_creds##*|}"
  local client_id="${oauth_creds%%|*}"
  local client_secret="${oauth_creds##*|}"

  mkdir -p "$PORTAL_DIR"

  # Generate SSH key if not exists
  if [ ! -f "$PORTAL_DIR/id_ed25519" ]; then
    info "Generating SSH key for portal VM..."
    ssh-keygen -t ed25519 -N "" -f "$PORTAL_DIR/id_ed25519" -C "portal-vm" >/dev/null
  fi

  local ssh_pub
  ssh_pub=$(cat "$PORTAL_DIR/id_ed25519.pub")

  local aap_url="https://aap-aap-operator.apps.$host_ip.nip.io"
  info "AAP URL: $aap_url"
  warn "Network dependent - breaks if host IP changes"

  # Create user-data with /etc/hosts for route resolution
  # TODO: Make CRC bind 0.0.0.0 (not 127.0.0.1) so gateway IP works, then use dnsmasq wildcard
  cat > "$PORTAL_DIR/user-data" <<EOF
#cloud-config
ssh_pwauth: false
users:
  - name: admin
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $ssh_pub

aap:
  host_url: "$aap_url"
  token: "$aap_token"
  check_ssl: false
  oauth:
    client_id: "$client_id"
    client_secret: "$client_secret"

database:
  type: builtin

# Static /etc/hosts (network-dependent workaround)
# Future: Use dnsmasq wildcard after CRC binds 0.0.0.0
write_files:
  - path: /etc/hosts
    append: true
    content: |
      $host_ip aap-aap-operator.apps.$host_ip.nip.io
      $host_ip aap-mcp-aap-operator.apps.$host_ip.nip.io
  - path: /root/generate-portal-cert.sh
    permissions: '0700'
    owner: 'root:root'
    content: |
      #!/bin/bash
      # Generate self-signed cert with actual VM IP for portal
      set -e

      VM_IP=\$(ip -4 addr show scope global | awk '/inet/ {print \$2}' | cut -d/ -f1 | head -1)
      PORTAL_SSL=/etc/portal/ssl

      # Generate cert with SAN for VM IP, localhost, common names
      openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout \$PORTAL_SSL/key.pem \
        -out \$PORTAL_SSL/cert.pem \
        -days 365 \
        -subj "/C=US/ST=State/L=City/O=AAP Portal/CN=\$VM_IP" \
        -addext "subjectAltName=DNS:localhost,DNS:portal,DNS:portal.local,DNS:*.local,IP:\$VM_IP,IP:127.0.0.1,IP:192.168.105.2,IP:192.168.105.3,IP:192.168.105.4,IP:192.168.105.5" \
        2>/dev/null

      chown portal:root \$PORTAL_SSL/cert.pem \$PORTAL_SSL/key.pem
      chmod 644 \$PORTAL_SSL/cert.pem
      chmod 600 \$PORTAL_SSL/key.pem

      # Restart portal to pick up new cert
      systemctl restart portal

runcmd:
  - /root/generate-portal-cert.sh
EOF

  # Create meta-data
  echo "instance-id: $PORTAL_VM_NAME" > "$PORTAL_DIR/meta-data"

  # Create cloud-init ISO
  info "Creating cloud-init ISO..."
  mkisofs -output "$PORTAL_DIR/cloud-init.iso" \
    -volid cidata \
    -joliet \
    -rock \
    "$PORTAL_DIR/user-data" \
    "$PORTAL_DIR/meta-data" \
    >/dev/null 2>&1
}

start_portal_vm() {
  # Copy qcow2 to portal dir (don't modify original)
  if [ ! -f "$PORTAL_DIR/portal.qcow2" ]; then
    info "Copying qcow2 to portal directory..."
    cp "$QCOW2_PATH" "$PORTAL_DIR/portal.qcow2"
  fi

  # Check if already running
  if [ -f "$PORTAL_DIR/qemu.pid" ]; then
    local pid
    pid=$(cat "$PORTAL_DIR/qemu.pid")
    if kill -0 "$pid" 2>/dev/null; then
      warn "Portal VM already running (PID: $pid)"
      echo ""
      echo "Access portal at: https://localhost:8443"
      echo "SSH: ssh -i $PORTAL_DIR_DISPLAY/id_ed25519 admin@<vm-ip>"
      echo ""
      echo "Stop with: $0 --delete"
      exit 0
    fi
  fi

  info "Starting portal VM (x86 emulation - expect 3-10min boot time)..."

  # Detect HVF support (macOS Hypervisor framework)
  # Portal requires x86-64-v2 CPU features (SSE4.2, POPCNT, etc)
  local accel_arg="-accel tcg"
  local cpu_arg="-cpu Nehalem"  # x86-64-v2 compatible
  if sysctl kern.hv_support 2>/dev/null | grep -q ": 1" && qemu-system-x86_64 -accel help 2>&1 | grep -q hvf; then
    accel_arg="-accel hvf"
    cpu_arg="-cpu host"
    info "Using HVF acceleration"
  else
    warn "HVF not available, using TCG (slower)"
  fi

  # Bridged networking via socket_vmnet
  local net_device="-device virtio-net-pci,netdev=net0,mac=52:55:00:d1:55:01"
  local net_backend="-netdev socket,id=net0,fd=3"

  info "Network: bridged via socket_vmnet"

  # Start QEMU via socket_vmnet_client for FD passing
  # shellcheck disable=SC2086
  nohup /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet_client \
    "$VMNET_SOCKET" \
    qemu-system-x86_64 \
    $accel_arg \
    -machine q35 \
    $cpu_arg \
    -m 8192 \
    -smp cpus=4 \
    -nographic \
    -serial mon:stdio \
    -device virtio-blk-pci,drive=disk0 \
    -drive id=disk0,if=none,format=qcow2,file="$PORTAL_DIR/portal.qcow2" \
    -drive file="$PORTAL_DIR/cloud-init.iso",media=cdrom,readonly=on \
    $net_device \
    $net_backend \
    > "$PORTAL_DIR/qemu.log" 2>&1 &

  local qemu_pid=$!
  echo "$qemu_pid" > "$PORTAL_DIR/qemu.pid"

  info "✓ Portal VM started (PID: $qemu_pid)"
  echo ""
  warn "⚠️  x86 emulation on ARM is slow - boot may take 3-10 minutes"
  info "Waiting for SSH to become available..."
  echo ""
  echo "Boot progress: tail -f ~/.aap-demo/portal-vm/qemu.log"
}

wait_for_ssh() {
  local max_wait=600  # 10 minutes
  local elapsed=0
  local ssh_key="$PORTAL_DIR/id_ed25519"

  while [ $elapsed -lt $max_wait ]; do
    if ssh -i "$ssh_key" \
           -p 2223 \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=5 \
           -o LogLevel=ERROR \
           admin@localhost \
           'exit 0' 2>/dev/null; then
      info "✓ SSH available after ${elapsed}s"
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
    echo -n "."
  done

  error "SSH not available after ${max_wait}s"
}

trust_portal_cert() {
  local ssh_key="$PORTAL_DIR/id_ed25519"
  local cert_path="$PORTAL_DIR/portal-cert.pem"

  info "Extracting portal certificate..."

  ssh -i "$ssh_key" \
      -p 2223 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      admin@localhost \
      'sudo cat /etc/portal/ssl/cert.pem' > "$cert_path" 2>/dev/null

  if [ ! -s "$cert_path" ]; then
    warn "Failed to extract certificate - skipping trust setup"
    return 1
  fi

  info "Certificate details:"
  openssl x509 -in "$cert_path" -noout -subject -dates 2>/dev/null || true
  echo ""

  info "Adding certificate to login keychain..."

  # Import to user's login keychain (no sudo)
  if security import "$cert_path" \
       -k ~/Library/Keychains/login.keychain-db \
       -T /Applications/Safari.app \
       -T /Applications/Google\ Chrome.app 2>/dev/null; then

    # Set trust for SSL
    local cert_hash
    cert_hash=$(openssl x509 -noout -fingerprint -sha1 -in "$cert_path" | cut -d= -f2 | tr -d :)

    security add-trusted-cert \
      -r trustAsRoot \
      -p ssl \
      -k ~/Library/Keychains/login.keychain-db \
      "$cert_path" 2>/dev/null || true

    info "✓ Certificate imported to login keychain and trusted for SSL"
    echo ""
    info "Browser notes:"
    echo "  - Chrome/Safari: Restart browser to pick up trusted cert"
    echo "  - Firefox: Uses own cert store - may still show warning"
    return 0
  else
    warn "Failed to import certificate - manual trust required"
    return 1
  fi
}

setup_vanity_url() {
  local ssh_key="$PORTAL_DIR/id_ed25519"

  info "Getting portal VM IP for vanity URL..."

  local vm_ip
  vm_ip=$(ssh -i "$ssh_key" \
              -p 2223 \
              -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=5 \
              -o LogLevel=ERROR \
              admin@localhost \
              "hostname -I | awk '{print \$1}'" 2>/dev/null) || true

  if [ -z "$vm_ip" ]; then
    warn "Failed to get VM IP - skipping vanity URL setup"
    return 1
  fi

  info "Portal VM IP: $vm_ip"

  # Check if already exists
  if grep -q "^$vm_ip.*portal$" /etc/hosts 2>/dev/null; then
    info "✓ Vanity URL 'portal' already configured"
    return 0
  fi

  # Add to /etc/hosts (requires sudo)
  echo ""
  info "Adding 'portal' vanity URL to /etc/hosts (requires sudo)..."

  if echo "$vm_ip portal" | sudo tee -a /etc/hosts >/dev/null 2>&1; then
    info "✓ Vanity URL configured: https://portal:8443"
    return 0
  else
    warn "Failed to add vanity URL - use https://localhost:8443 instead"
    return 1
  fi
}

show_access_info() {
  echo ""
  info "Portal VM Ready"
  echo ""
  echo "Access:"

  # Check if vanity URL is configured
  if grep -q "portal$" /etc/hosts 2>/dev/null; then
    echo "  Portal UI:  https://portal:8443"
  else
    echo "  Portal UI:  https://localhost:8443"
  fi

  echo "  SSH:        ssh -i ~/.aap-demo/portal-vm/id_ed25519 -p 2223 admin@localhost"
  echo ""
  echo "Verify portal services:"
  echo "  ssh -i ~/.aap-demo/portal-vm/id_ed25519 -p 2223 admin@localhost 'sudo systemctl status portal'"
  echo ""
  echo "Stop VM: ./deploy.sh --delete"
}

# Main
cleanup

info "AAP Portal VM Deployment (QEMU x86 emulation)"
echo ""

check_prerequisites

HOST_IP=$(get_host_ip)
info "Host IP: $HOST_IP"

info "Getting AAP credentials..."
AAP_CREDS=$(get_aap_credentials)

AAP_ROUTE="${AAP_CREDS%%|*}"
ADMIN_PASS="${AAP_CREDS##*|}"

OAUTH_CREDS=$(create_oauth_app "$AAP_ROUTE" "$ADMIN_PASS")

info "Generating cloud-init configuration..."
generate_cloud_init "$AAP_CREDS" "$OAUTH_CREDS" "$HOST_IP"

start_portal_vm
wait_for_ssh
trust_portal_cert
setup_vanity_url
show_access_info
