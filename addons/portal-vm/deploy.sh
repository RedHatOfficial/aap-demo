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

# Auto-discover qcow2 if not explicitly set
if [ -z "$QCOW2_PATH" ]; then
  # Use array + nullglob for safe expansion
  shopt -s nullglob
  qcow2_candidates=( "$HOME/Downloads"/ansible-automation-portal-*-x86_64.qcow2 )
  QCOW2_PATH="${qcow2_candidates[0]:-$HOME/Downloads/ansible-automation-portal-2.2.1-x86_64.qcow2}"
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

    # Kill socat proxy
    if [ -f "$PORTAL_DIR/socat.pid" ]; then
      local socat_pid
      socat_pid=$(cat "$PORTAL_DIR/socat.pid")
      if kill -0 "$socat_pid" 2>/dev/null; then
        kill "$socat_pid" 2>/dev/null || true
      fi
      rm -f "$PORTAL_DIR/socat.pid"
    fi

    # Keep portal directory (contains qcow2, SSH keys, logs for next start)
    info "✓ Portal VM stopped (kept directory: $PORTAL_DIR)"

    exit 0
  fi
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
      "redirect_uris": "https://localhost:8443/api/auth/rhaap/handler/frame",
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

  # Create user-data (official minimal template from AAP Extend docs p212-213)
  cat > "$PORTAL_DIR/user-data" <<EOF
#cloud-config

users:
  - name: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $ssh_pub

aap:
  host_url: "https://$aap_route"
  token: "$aap_token"
  check_ssl: false
  oauth:
    client_id: "$client_id"
    client_secret: "$client_secret"

database:
  type: builtin

runcmd:
  - echo "10.0.2.2 $aap_route" >> /etc/hosts
  - |
    # Disable GitHub and GitLab auth plugins via config override
    # Portal loads configs/* in lexical order; zz- prefix loads last
    cat > /etc/portal/configs/app-config/zz-disable-scm-oauth.yaml <<'PLUGIN_EOF'
# Disable SCM OAuth providers (GitHub/GitLab) - only use RHAAP
dynamicPlugins:
  plugins:
    - package: '@backstage/plugin-auth-backend-module-github-provider-dynamic'
      disabled: true
    - package: '@backstage/plugin-auth-backend-module-gitlab-provider-dynamic'
      disabled: true
PLUGIN_EOF
  - systemctl restart portal.service
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

    # Check if process exists AND is qemu
    if kill -0 "$pid" 2>/dev/null && ps -p "$pid" | grep -q qemu; then
      warn "Portal VM already running (PID: $pid)"
      echo ""
      echo "Access portal at: https://localhost:8443"
      echo "SSH: ssh -i $PORTAL_DIR/id_ed25519 -p 2223 -o StrictHostKeyChecking=no admin@localhost"
      echo ""
      echo "Stop with: aap-demo disable portal-vm"
      exit 0
    else
      warn "Stale PID file found (process $pid not running), removing"
      rm -f "$PORTAL_DIR/qemu.pid"
    fi
  fi

  info "Starting portal VM (x86 emulation - expect 3-10min boot time)..."

  # Rotate logs before starting
  if [ -f "$PORTAL_DIR/qemu.log" ]; then
    mv "$PORTAL_DIR/qemu.log" "$PORTAL_DIR/qemu.log.$(date +%Y%m%d-%H%M%S)"
    # Keep only last 5 logs
    # shellcheck disable=SC2012
    ls -t "$PORTAL_DIR"/qemu.log.* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
  fi

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

  # Start QEMU in background with RHEL appliance optimizations
  # Separate serial console (contains cloud-init secrets) from process logs
  # shellcheck disable=SC2086
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
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::8443-:443,hostfwd=tcp::8080-:80,hostfwd=tcp::2223-:22,dns=10.0.2.3 \
    > "$PORTAL_DIR/qemu.log" 2>&1 &

  local qemu_pid=$!
  echo "$qemu_pid" > "$PORTAL_DIR/qemu.pid"

  # Start socat proxy for AAP connectivity (QEMU guest → macOS host → CRC)
  # Portal VM uses 10.0.2.2 (QEMU host gateway) to reach AAP
  if ! pgrep -f "socat.*TCP-LISTEN:443.*127.0.0.1:443" >/dev/null 2>&1; then
    info "Starting socat proxy for AAP connectivity..."
    nohup socat TCP-LISTEN:443,bind=0.0.0.0,fork,reuseaddr TCP:127.0.0.1:443 \
      > "$PORTAL_DIR/socat-https.log" 2>&1 &
    echo $! > "$PORTAL_DIR/socat.pid"
  fi

  info "✓ Portal VM started (PID: $qemu_pid)"
  echo ""
  echo "Boot progress: tail -f $PORTAL_DIR/serial.log"
  echo ""
  warn "⚠️  x86 emulation on ARM is slow - boot may take 3-10 minutes"
  echo ""
  echo "After boot completes:"
  echo "  Portal UI:  https://localhost:8443"
  echo "  SSH access: ssh -i $PORTAL_DIR/id_ed25519 -p 2223 -o StrictHostKeyChecking=no admin@localhost"
  echo ""
  echo "Check status: sudo systemctl status portal postgres devtools (from SSH)"
  echo "Stop VM:      aap-demo disable portal-vm"
}

# Main
cleanup

info "AAP Portal VM Deployment (QEMU x86 emulation)"
echo ""

check_prerequisites

info "Getting AAP credentials..."
AAP_CREDS=$(get_aap_credentials)

AAP_ROUTE="${AAP_CREDS%%|*}"
ADMIN_PASS="${AAP_CREDS##*|}"

OAUTH_CREDS=$(create_oauth_app "$AAP_ROUTE" "$ADMIN_PASS")

info "Generating cloud-init configuration..."
generate_cloud_init "$AAP_CREDS" "$OAUTH_CREDS"

start_portal_vm
