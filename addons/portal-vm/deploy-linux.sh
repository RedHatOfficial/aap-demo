#!/usr/bin/env bash
# Deploy AAP Portal via QEMU/KVM on Linux (native x86, no emulation)
# ADDON_REQUIRES_AAP=true
#
# Designed for RHEL/CentOS/Fedora with KVM support.
# Uses native KVM acceleration instead of socket_vmnet bridged networking.
#
# Prerequisites:
#   - Linux x86_64 with KVM support
#   - AAP deployed in aap-operator namespace
#   - Portal qcow2 downloaded from Red Hat Customer Portal
#   - qemu-kvm and genisoimage installed
#
# Usage:
#   ./deploy-linux.sh          # Start portal VM
#   ./deploy-linux.sh --delete # Stop and cleanup portal VM

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"
PORTAL_VM_NAME="${PORTAL_VM_NAME:-automation-portal}"
PORTAL_DIR="${PORTAL_DIR:-$HOME/.aap-demo/portal-vm}"
PORTAL_DIR_DISPLAY="${PORTAL_DIR/#$HOME/~}"

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
NC='\033[0m'

error() {
  echo -e "${RED}ERROR: $*${NC}" >&2
  exit 1
}

warn() {
  echo -e "${YELLOW}WARN: $*${NC}" >&2
}

info() {
  echo -e "${GREEN}INFO: $*${NC}"
}

cleanup() {
  # Handle --delete
  if [ "$ACTION" = "--delete" ]; then
    if [ ! -f "$PORTAL_DIR/qemu.pid" ]; then
      warn "Portal VM not running (no PID file)"
      exit 0
    fi

    local pid
    pid=$(cat "$PORTAL_DIR/qemu.pid")

    if kill -0 "$pid" 2>/dev/null; then
      info "Stopping Portal VM (PID: $pid)..."
      kill "$pid"
      sleep 2
      if kill -0 "$pid" 2>/dev/null; then
        warn "Force killing Portal VM..."
        kill -9 "$pid"
      fi
      info "✓ Portal VM stopped"
    else
      warn "Portal VM not running (stale PID: $pid)"
    fi

    rm -f "$PORTAL_DIR/qemu.pid"

    # Ask about cleanup
    echo ""
    echo -n "Delete portal directory? (y/N): "
    read -r response
    if [ "$response" = "y" ] || [ "$response" = "Y" ]; then
      rm -rf "$PORTAL_DIR"
      info "✓ Portal VM cleaned up"
    else
      info "Kept portal directory: $PORTAL_DIR_DISPLAY"
    fi

    exit 0
  fi
}

check_prerequisites() {
  # Check if running as root (KVM needs it or user in kvm group)
  if [ "$EUID" -ne 0 ] && ! groups | grep -q kvm; then
    error "Must run as root OR be in 'kvm' group: sudo usermod -aG kvm $USER"
  fi

  # Check KVM support
  if [ ! -e /dev/kvm ]; then
    error "KVM not available. Enable virtualization in BIOS and load kvm module."
  fi

  # Check qemu-kvm
  if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    error "qemu-system-x86_64 not found. Install: dnf install qemu-kvm"
  fi

  # Check genisoimage (Linux cloud-init ISO tool)
  if ! command -v genisoimage >/dev/null 2>&1; then
    error "genisoimage not found. Install: dnf install genisoimage"
  fi

  # Check kubectl/oc
  if ! command -v kubectl >/dev/null 2>&1 && ! command -v oc >/dev/null 2>&1; then
    error "kubectl or oc not found. Install OpenShift CLI."
  fi

  # Check qcow2 exists
  if [ ! -f "$QCOW2_PATH" ]; then
    error "Portal qcow2 not found: $QCOW2_PATH"
  fi

  info "Using qcow2: $(basename "$QCOW2_PATH")"

  # Create portal directory
  mkdir -p "$PORTAL_DIR"

  # Check if VM already running
  if [ -f "$PORTAL_DIR/qemu.pid" ]; then
    local pid
    pid=$(cat "$PORTAL_DIR/qemu.pid")
    if kill -0 "$pid" 2>/dev/null; then
      warn "Portal VM already running (PID: $pid)"
      echo ""
      echo "Access portal at: https://localhost:8443"
      echo "SSH: ssh -i $PORTAL_DIR_DISPLAY/id_ed25519 -p 2223 admin@localhost"
      echo ""
      echo "Stop with: $0 --delete"
      exit 0
    fi
  fi
}

get_host_ip() {
  # Get primary network interface IP (for AAP routes)
  ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -1
}

get_aap_credentials() {
  local kubectl_cmd="kubectl"
  command -v oc >/dev/null 2>&1 && kubectl_cmd="oc"

  # Get AAP route
  local aap_route
  aap_route=$($kubectl_cmd get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null) || \
    error "AAP route not found in namespace $NAMESPACE"

  # Get admin password
  local admin_pass
  admin_pass=$($kubectl_cmd get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d) || \
    error "AAP admin password secret not found"

  echo "https://$aap_route|$admin_pass"
}

create_oauth_app() {
  local aap_route="$1"
  local admin_pass="$2"

  # Generate OAuth client credentials
  local client_id="portal-vm"
  local client_secret
  client_secret=$(openssl rand -hex 32)

  # Create OAuth application in AAP
  local token_response
  token_response=$(curl -sk -X POST "$aap_route/api/v2/tokens/" \
    -H "Content-Type: application/json" \
    -u "admin:$admin_pass" \
    -d '{
      "description": "Portal VM OAuth Token",
      "application": null,
      "scope": "write"
    }')

  local token
  token=$(echo "$token_response" | grep -o '"token":"[^"]*' | cut -d'"' -f4)

  if [ -z "$token" ]; then
    warn "Failed to create OAuth token - using password auth fallback"
    echo "$client_id|$client_secret"
    return
  fi

  # Create OAuth2 application
  curl -sk -X POST "$aap_route/api/v2/applications/" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$client_id\",
      \"description\": \"Portal VM OAuth Application\",
      \"client_type\": \"confidential\",
      \"authorization_grant_type\": \"password\",
      \"redirect_uris\": \"\",
      \"client_secret\": \"$client_secret\"
    }" >/dev/null 2>&1 || warn "OAuth app creation failed - may already exist"

  echo "$client_id|$client_secret"
}

generate_cloud_init() {
  local aap_creds="$1"
  local oauth_creds="$2"
  local host_ip="$3"

  local aap_route="${aap_creds%%|*}"
  local admin_pass="${aap_creds##*|}"
  local client_id="${oauth_creds%%|*}"
  local client_secret="${oauth_creds##*|}"

  info "AAP URL: $aap_route"

  # Generate SSH key pair (if not exists)
  if [ ! -f "$PORTAL_DIR/id_ed25519" ]; then
    ssh-keygen -t ed25519 -f "$PORTAL_DIR/id_ed25519" -N "" -C "portal-vm" >/dev/null 2>&1
  fi

  local ssh_pubkey
  ssh_pubkey=$(cat "$PORTAL_DIR/id_ed25519.pub")

  # Create user-data (cloud-init config)
  cat > "$PORTAL_DIR/user-data" <<EOF
#cloud-config
hostname: portal-vm
fqdn: portal-vm.local

ssh_pwauth: false
disable_root: true

users:
  - name: admin
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $ssh_pubkey

aap:
  host_url: "$aap_route"
  token: "$admin_pass"
  check_ssl: false
  oauth:
    client_id: "$client_id"
    client_secret: "$client_secret"

database:
  type: builtin

# Static /etc/hosts (network-dependent workaround)
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
        -addext "subjectAltName=DNS:localhost,DNS:portal,DNS:portal.local,DNS:*.local,IP:\$VM_IP,IP:127.0.0.1" \
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
  genisoimage -output "$PORTAL_DIR/cloud-init.iso" \
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

  info "Starting Portal VM with KVM acceleration..."

  # Use KVM (native x86)
  local accel_arg="-enable-kvm"
  local cpu_arg="-cpu host"

  # User-mode networking with port forwards (no bridging needed)
  local net_args="-netdev user,id=net0,hostfwd=tcp::2223-:22,hostfwd=tcp::8443-:8443 -device virtio-net-pci,netdev=net0"

  # Start QEMU in background
  nohup qemu-system-x86_64 \
    $accel_arg \
    -machine q35 \
    $cpu_arg \
    -m 8192 \
    -smp cpus=4 \
    -nographic \
    -serial file:"$PORTAL_DIR/serial.log" \
    -device virtio-blk-pci,drive=disk0 \
    -drive id=disk0,if=none,format=qcow2,file="$PORTAL_DIR/portal.qcow2" \
    -drive file="$PORTAL_DIR/cloud-init.iso",media=cdrom,readonly=on \
    $net_args \
    > "$PORTAL_DIR/qemu.log" 2>&1 &

  local qemu_pid=$!
  echo "$qemu_pid" > "$PORTAL_DIR/qemu.pid"

  info "✓ Portal VM started (PID: $qemu_pid)"
  echo ""
  info "Boot progress: tail -f ~/.aap-demo/portal-vm/serial.log"
  echo ""
  info "Waiting for SSH to become available..."
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

  # On Linux, add to system CA trust
  if [ -d /etc/pki/ca-trust/source/anchors ]; then
    info "Adding certificate to system CA trust (requires sudo)..."
    if sudo cp "$cert_path" /etc/pki/ca-trust/source/anchors/portal-vm.pem && \
       sudo update-ca-trust; then
      info "✓ Certificate trusted system-wide"
      return 0
    fi
  elif [ -d /usr/local/share/ca-certificates ]; then
    info "Adding certificate to system CA trust (requires sudo)..."
    if sudo cp "$cert_path" /usr/local/share/ca-certificates/portal-vm.crt && \
       sudo update-ca-certificates; then
      info "✓ Certificate trusted system-wide"
      return 0
    fi
  fi

  warn "Could not add to system CA trust - manual trust required"
  info "Certificate saved to: $cert_path"
  return 1
}

show_access_info() {
  echo ""
  info "Portal VM Ready"
  echo ""
  echo "Access:"
  echo "  Portal UI:  https://localhost:8443"
  echo "  SSH:        ssh -i ~/.aap-demo/portal-vm/id_ed25519 -p 2223 admin@localhost"
  echo ""
  echo "Verify portal services:"
  echo "  ssh -i ~/.aap-demo/portal-vm/id_ed25519 -p 2223 admin@localhost 'sudo systemctl status portal'"
  echo ""
  echo "Stop VM: ./deploy-linux.sh --delete"
}

# Main
cleanup

info "AAP Portal VM Deployment (QEMU/KVM on Linux)"
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
show_access_info
