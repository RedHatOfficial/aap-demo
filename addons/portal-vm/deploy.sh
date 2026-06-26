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
  qcow2_candidates=("$HOME/Downloads"/ansible-automation-portal-*-x86_64.qcow2)
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
    fi

    # Kill socat proxy (may require sudo if started with sudo)
    if [ -f "$PORTAL_DIR/socat.pid" ]; then
      local socat_pid
      socat_pid=$(cat "$PORTAL_DIR/socat.pid")
      if kill -0 "$socat_pid" 2>/dev/null; then
        kill "$socat_pid" 2>/dev/null || sudo kill "$socat_pid" 2>/dev/null || true
      fi
    fi

    # Remove entire portal directory (qcow2, SSH keys, logs, cloud-init)
    if [ -d "$PORTAL_DIR" ]; then
      rm -rf "$PORTAL_DIR"
      info "✓ Portal VM stopped and removed: $PORTAL_DIR"
    else
      info "✓ Portal VM stopped"
    fi

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
  local api_token

  aap_route=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  admin_pass=$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

  if [ -z "$aap_route" ] || [ -z "$admin_pass" ]; then
    error "Failed to get AAP credentials"
    exit 1
  fi

  # Create API token for portal backend catalog (not OAuth - separate auth)
  info "Creating AAP API token for portal backend..." >&2

  # Get cluster CA bundle for TLS verification
  local ca_bundle="/tmp/aap-ca-$$.crt"
  kubectl get secret router-certs-default -n openshift-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d >"$ca_bundle"

  api_token=$(curl --cacert "$ca_bundle" -s -u "admin:$admin_pass" \
    -X POST "https://$aap_route/api/gateway/v1/tokens/" \
    -H "Content-Type: application/json" \
    -d '{"description":"Portal backend catalog","application":null,"scope":"write"}' \
    | jq -r '.token // empty')

  rm -f "$ca_bundle"

  if [ -z "$api_token" ]; then
    error "Failed to create AAP API token"
    exit 1
  fi

  echo "$aap_route|$admin_pass|$api_token"
}

save_oauth_credentials() {
  local client_id="$1"
  local client_secret="$2"
  umask 077
  printf '%s\n%s\n' "$client_id" "$client_secret" >"$PORTAL_DIR/oauth.credentials"
}

load_oauth_credentials() {
  if [ ! -f "$PORTAL_DIR/oauth.credentials" ]; then
    return 1
  fi
  local client_id client_secret
  client_id=$(sed -n '1p' "$PORTAL_DIR/oauth.credentials")
  client_secret=$(sed -n '2p' "$PORTAL_DIR/oauth.credentials")
  if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
    return 1
  fi
  echo "$client_id|$client_secret"
}

create_oauth_app() {
  local aap_route="$1"
  local admin_pass="$2"

  # Get cluster CA bundle for TLS verification
  local ca_bundle="/tmp/aap-ca-oauth-$$.crt"
  kubectl get secret router-certs-default -n openshift-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d >"$ca_bundle"

  local aap_client_id
  aap_client_id=$(curl --cacert "$ca_bundle" -s -u "admin:$admin_pass" \
    "https://$aap_route/api/gateway/v1/applications/?name=portal-vm" \
    | jq -r '.results[0].client_id // empty')

  local saved_creds saved_id saved_secret
  if saved_creds=$(load_oauth_credentials 2>/dev/null); then
    saved_id="${saved_creds%%|*}"
    saved_secret="${saved_creds##*|}"
    if [ -n "$aap_client_id" ] && [ "$aap_client_id" = "$saved_id" ]; then
      info "Reusing existing OAuth application in AAP (client_id matches saved credentials)" >&2
      rm -f "$ca_bundle"
      echo "$saved_id|$saved_secret"
      return 0
    fi
  fi

  info "Creating OAuth application in AAP..." >&2

  local existing
  existing=$(curl --cacert "$ca_bundle" -s -u "admin:$admin_pass" \
    "https://$aap_route/api/gateway/v1/applications/?name=portal-vm" | jq -r '.results[0].id // empty')

  if [ -n "$existing" ]; then
    curl --cacert "$ca_bundle" -s -u "admin:$admin_pass" -X DELETE \
      "https://$aap_route/api/gateway/v1/applications/$existing/" >/dev/null 2>&1
  fi

  local oauth_data client_id client_secret
  oauth_data=$(curl --cacert "$ca_bundle" -s -u "admin:$admin_pass" \
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

  rm -f "$ca_bundle"

  client_id=$(echo "$oauth_data" | jq -r '.client_id' 2>/dev/null)
  client_secret=$(echo "$oauth_data" | jq -r '.client_secret' 2>/dev/null)

  if [ -z "$client_id" ] || [ "$client_id" = "null" ]; then
    error "Failed to create OAuth app"
    echo "$oauth_data" >&2
    exit 1
  fi

  save_oauth_credentials "$client_id" "$client_secret"
  echo "$client_id|$client_secret"
}

sync_oauth_to_vm() {
  local aap_route="$1"
  local client_id="$2"
  local client_secret="$3"

  if [ ! -f "$PORTAL_DIR/id_ed25519" ]; then
    return 0
  fi

  if ! ssh -i "$PORTAL_DIR/id_ed25519" -p 2223 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    -o BatchMode=yes admin@localhost true 2>/dev/null; then
    return 0
  fi

  info "Syncing OAuth credentials to portal VM..."
  local secret_b64
  secret_b64=$(printf '%s' "$client_secret" | base64 | tr -d '\n')

  ssh -i "$PORTAL_DIR/id_ed25519" -p 2223 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@localhost \
    "sudo mkdir -p /etc/containers/systemd/portal.container.d
sudo tee /etc/containers/systemd/portal.container.d/20-aap-env.conf >/dev/null <<CONF
[Container]
Environment=AAP_HOST_URL=https://$aap_route
Environment=AAP_OAUTH_CLIENT_ID=$client_id
CONF
sudo sed -i 's/^        clientId: .*/        clientId: $client_id/' /etc/portal/configs/app-config/app-config.production.yaml
sudo podman secret rm portal_aap_oauth_client_secret 2>/dev/null || true
echo '$secret_b64' | base64 -d | sudo podman secret create portal_aap_oauth_client_secret -
sudo systemctl daemon-reload" >/dev/null 2>&1 || {
    warn "Failed to sync OAuth credentials to portal VM"
    return 1
  }
}

generate_cloud_init() {
  local aap_creds="$1"
  local oauth_creds="$2"

  # Parse AAP creds: route|password|api_token
  local aap_route admin_pass aap_token
  aap_route="${aap_creds%%|*}"
  admin_pass="${aap_creds#*|}"
  admin_pass="${admin_pass%|*}"
  aap_token="${aap_creds##*|}"

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

  # Create user-data (ADR-002 partial: simplified runcmd, port 443)
  cat >"$PORTAL_DIR/user-data" <<EOF
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
  builtin:
    password: "auto"
    admin_password: "auto"

security:
  backend_secret: "auto"  # Auto-generated

network:
  base_url: "https://localhost:8443"

write_files:
  - path: /etc/containers/systemd/portal.container.d/10-port-override.conf
    owner: root:root
    permissions: '0644'
    content: |
      [Container]
      PublishPort=443:7007
  - path: /etc/containers/systemd/portal.container.d/20-aap-env.conf
    owner: root:root
    permissions: '0644'
    content: |
      [Container]
      Environment=AAP_HOST_URL=https://$aap_route
      Environment=AAP_OAUTH_CLIENT_ID=$client_id
  - path: /etc/portal/configs/dynamic-plugins/zz-disable-scm-auth.yaml
    owner: root:root
    permissions: '0644'
    content: |
      # Disable SCM auth backend plugins (match package paths in dynamic-plugins.override.yaml)
      plugins:
        - package: ./ansible-plugins/backstage-plugin-auth-backend-module-github-provider
          disabled: true
        - package: ./ansible-plugins/backstage-plugin-auth-backend-module-gitlab-provider
          disabled: true
bootcmd:
  - grep -q "$aap_route" /etc/hosts || echo "10.0.2.2 $aap_route" >> /etc/hosts

runcmd:
  - grep -q "$aap_route" /etc/hosts || echo "10.0.2.2 $aap_route" >> /etc/hosts
  - rm -f /etc/portal/configs/app-config/zz-disable-scm-oauth.yaml
  - rm -f /etc/portal/configs/app-config/zz-auth-rhaap-only.yaml
  - sed -i '/backstage-plugin-auth-backend-module-github-provider/,+1 s/disabled: false/disabled: true/' /etc/portal/configs/dynamic-plugins/dynamic-plugins.override.yaml
  - sed -i '/backstage-plugin-auth-backend-module-gitlab-provider/,+1 s/disabled: false/disabled: true/' /etc/portal/configs/dynamic-plugins/dynamic-plugins.override.yaml
  - for i in $(seq 1 60); do curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 3 "https://$aap_route/api/gateway/v1/" | grep -q 200 && break; sleep 2; done
  - sudo rm -f /var/lib/portal/dynamic-plugins-root/install-dynamic-plugins.lock
  - systemctl restart portal.service
EOF

  # Create meta-data
  echo "instance-id: $PORTAL_VM_NAME" >"$PORTAL_DIR/meta-data"

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

start_socat_proxy() {
  if pgrep -f "socat.*TCP-LISTEN:443.*127.0.0.1:443" >/dev/null 2>&1; then
    return 0
  fi

  # CRC may bind 127.0.0.1:443 only; QEMU slirp reaches the host via 10.0.2.2
  if lsof -iTCP:443 -sTCP:LISTEN 2>/dev/null | grep -qE '(\*|0\.0\.0\.0).*443'; then
    return 0
  fi

  if command -v socat >/dev/null 2>&1; then
    info "Starting socat proxy for AAP connectivity (CRC binds localhost:443 only)..."
    nohup socat TCP-LISTEN:443,bind=0.0.0.0,fork,reuseaddr TCP:127.0.0.1:443 \
      >"$PORTAL_DIR/socat-https.log" 2>&1 &
    echo $! >"$PORTAL_DIR/socat.pid"
  else
    warn "socat not installed; VM may not reach AAP when CRC binds 127.0.0.1:443"
    warn "Install with: brew install socat"
  fi
}

vm_aap_reachable() {
  local aap_route="$1"

  if [ ! -f "$PORTAL_DIR/id_ed25519" ]; then
    return 1
  fi

  local code
  code=$(ssh -i "$PORTAL_DIR/id_ed25519" -p 2223 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    -o BatchMode=yes admin@localhost \
    "curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 -H 'Host: $aap_route' https://10.0.2.2/api/gateway/v1/" 2>/dev/null || echo "000")

  [ "$code" = "200" ]
}

ensure_aap_networking() {
  local aap_route="$1"

  start_socat_proxy

  if [ ! -f "$PORTAL_DIR/id_ed25519" ]; then
    return 0
  fi

  if ! ssh -i "$PORTAL_DIR/id_ed25519" -p 2223 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    -o BatchMode=yes admin@localhost true 2>/dev/null; then
    warn "Portal VM SSH not ready; networking check skipped"
    return 0
  fi

  info "Ensuring VM can reach AAP at $aap_route via 10.0.2.2..."
  ssh -i "$PORTAL_DIR/id_ed25519" -p 2223 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@localhost \
    "grep -q '$aap_route' /etc/hosts || echo '10.0.2.2 $aap_route' | sudo tee -a /etc/hosts >/dev/null" \
    >/dev/null 2>&1 || true

  local attempt=1
  while [ "$attempt" -le 30 ]; do
    if vm_aap_reachable "$aap_route"; then
      info "VM → AAP connectivity OK"
      return 0
    fi
    if [ "$attempt" -eq 1 ]; then
      warn "VM cannot reach AAP yet; waiting (check CRC/VPN and socat)..."
    fi
    start_socat_proxy
    sleep 2
    attempt=$((attempt + 1))
  done

  warn "VM still cannot reach AAP — portal may show GitHub-only login until networking is fixed"
  return 1
}

repair_portal_auth() {
  local aap_route="$1"
  local client_id="$2"
  local client_secret="$3"

  if [ ! -f "$PORTAL_DIR/id_ed25519" ]; then
    return 0
  fi

  if ! ssh -i "$PORTAL_DIR/id_ed25519" -p 2223 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    -o BatchMode=yes admin@localhost true 2>/dev/null; then
    warn "Portal VM SSH not ready; auth repair skipped"
    return 0
  fi

  ensure_aap_networking "$aap_route" || true
  sync_oauth_to_vm "$aap_route" "$client_id" "$client_secret" || true

  info "Repairing portal auth config and restarting portal..."
  ssh -i "$PORTAL_DIR/id_ed25519" -p 2223 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@localhost \
    "sudo rm -f /etc/portal/configs/app-config/zz-disable-scm-oauth.yaml
sudo rm -f /etc/portal/configs/app-config/zz-auth-rhaap-only.yaml
sudo sed -i '/backstage-plugin-auth-backend-module-github-provider/,+1 s/disabled: false/disabled: true/' /etc/portal/configs/dynamic-plugins/dynamic-plugins.override.yaml
sudo sed -i '/backstage-plugin-auth-backend-module-gitlab-provider/,+1 s/disabled: false/disabled: true/' /etc/portal/configs/dynamic-plugins/dynamic-plugins.override.yaml
sudo rm -f /var/lib/portal/dynamic-plugins-root/install-dynamic-plugins.lock
sudo systemctl restart portal.service" >/dev/null 2>&1 || \
    warn "Portal auth repair failed; try: aap-demo disable portal-vm && aap-demo enable portal-vm"
}

start_portal_vm() {
  local aap_route="${1:-}"
  local client_id="${2:-}"
  local client_secret="${3:-}"
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
      if [ -n "$aap_route" ] && [ -n "$client_id" ] && [ -n "$client_secret" ]; then
        repair_portal_auth "$aap_route" "$client_id" "$client_secret"
      else
        start_socat_proxy
      fi
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
  local cpu_arg="-cpu Nehalem" # x86-64-v2 compatible
  if sysctl kern.hv_support 2>/dev/null | grep -q ": 1" && qemu-system-x86_64 -accel help 2>&1 | grep -q hvf; then
    accel_arg="-accel hvf"
    cpu_arg="-cpu host"
    info "Using HVF acceleration"
  else
    warn "HVF not available, using TCG (slower)"
  fi

  # Start QEMU (ADR-002 partial: hostfwd only, guestfwd needs socat fallback)
  # Portal reaches AAP via /etc/hosts override in cloud-init (10.0.2.2 → AAP route)
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
    >"$PORTAL_DIR/qemu.log" 2>&1 &

  local qemu_pid=$!
  echo "$qemu_pid" >"$PORTAL_DIR/qemu.pid"

  if [ -n "$aap_route" ]; then
    ensure_aap_networking "$aap_route" || true
  else
    start_socat_proxy
  fi

  info "✓ Portal VM started (PID: $qemu_pid)"
  echo ""
  echo "Boot progress: tail -f $PORTAL_DIR/serial.log"
  echo ""
  warn "⚠️  x86 emulation on ARM is slow - boot may take 3-10 minutes"
  echo ""
  echo "After boot completes:"
  echo "  Portal UI:  https://localhost:8443"
  echo "  AAP route:  https://$AAP_ROUTE (portal connects to this)"
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

# Parse: route|password|api_token
AAP_ROUTE="${AAP_CREDS%%|*}"
ADMIN_PASS="${AAP_CREDS#*|}"
ADMIN_PASS="${ADMIN_PASS%|*}"

OAUTH_CREDS=$(create_oauth_app "$AAP_ROUTE" "$ADMIN_PASS")
OAUTH_CLIENT_ID="${OAUTH_CREDS%%|*}"
OAUTH_CLIENT_SECRET="${OAUTH_CREDS##*|}"

info "Generating cloud-init configuration..."
generate_cloud_init "$AAP_CREDS" "$OAUTH_CREDS"

start_portal_vm "$AAP_ROUTE" "$OAUTH_CLIENT_ID" "$OAUTH_CLIENT_SECRET"
