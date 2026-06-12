#!/usr/bin/env bash
# =============================================================================
# crc-create.sh — Create an AAP Demo cluster via CRC (OpenShift Local)
# =============================================================================
#
# Uses CRC to create and manage the VM. Supports both MicroShift and
# OpenShift presets.
#
# =============================================================================

set -eo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Colors
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[0;33m'
_BOLD='\033[1m'
_NC='\033[0m'

echo ""
printf "${_BOLD}aap-demo create${_NC} - Creating CRC cluster...\n"
echo ""

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# Check CRC is installed
if ! command -v crc &>/dev/null; then
  printf "${_RED}▸${_NC} CRC (OpenShift Local) is required but not found\n"
  echo ""
  echo "  Download from: https://console.redhat.com/openshift/create/local"
  if [ "$(uname)" != "Darwin" ]; then
    echo "  Extract and install: tar xf crc-linux-*.tar.xz && sudo cp crc-linux-*/crc /usr/local/bin/"
  fi
  exit 1
fi

# Ensure CRC daemon is running (Linux only — macOS/Windows manage the daemon)
_is_mingw() {
  case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) return 0 ;; *) return 1 ;; esac
}

if ! _is_mingw && [ "$(uname)" != "Darwin" ] && ! [ -S ~/.crc/crc-http.sock ]; then
  echo "Starting CRC daemon..."
  crc daemon &>/dev/null &
  disown
  sleep 3
fi

# Check if already running
CRC_STATUS_JSON=$(crc status --output json 2>/dev/null || echo '{}')
CRC_STATUS=$(echo "$CRC_STATUS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('crcStatus','Unknown'))" 2>/dev/null || echo "Unknown")

if [ "$CRC_STATUS" = "Running" ]; then
  echo "CRC is already running"
  echo "  Use 'aap-demo destroy' to remove it first, or 'aap-demo deploy' to deploy AAP"
  exit 1
fi

# ---------------------------------------------------------------------------
# Preset selection (if not already configured)
# ---------------------------------------------------------------------------
CURRENT_PRESET=$(crc config get preset 2>/dev/null || echo "")
[ -n "$CURRENT_PRESET" ] && CURRENT_PRESET=$(echo "$CURRENT_PRESET" | awk '{print $NF}')

if [ "$CRC_STATUS" = "Unknown" ] || [ -z "$CURRENT_PRESET" ] || [ "$CURRENT_PRESET" = "openshift" ]; then
  # Check if preset was saved in aap-demo config
  SAVED_PRESET=""
  if [ -f "${HOME}/.aap-demo/config" ]; then
    SAVED_PRESET=$(grep '^CRC_PRESET=' "${HOME}/.aap-demo/config" 2>/dev/null | cut -d= -f2 || true)
  fi

  if [ -z "$SAVED_PRESET" ]; then
    if [ -t 0 ]; then
      echo ""
      printf "${_BOLD}Select CRC preset:${_NC}\n"
      echo ""
      printf "  ${_BOLD}1) MicroShift — Recommended${_NC}\n"
      echo "     Lightweight single-node Kubernetes (OpenShift API subset)"
      echo "     + Fast boot (~2 min), ~10 system pods"
      echo "     + Minimal resource usage (4 CPUs, 4GB RAM minimum)"
      echo "     + OLM, Routes, SCCs supported"
      echo "     - No built-in console (aap-demo provides one as addon)"
      echo "     - DevSpaces not supported (devworkspace-operator incompatible)"
      echo ""
      printf "  ${_BOLD}2) OpenShift — Full Platform${_NC}\n"
      echo "     Full OpenShift Container Platform (single-node)"
      echo "     + Complete OpenShift API compatibility"
      echo "     + Built-in console, OAuth, monitoring available"
      echo "     + DevSpaces fully supported"
      echo "     - Heavier (~96 system pods)"
      echo "     - Requires more resources (4 CPUs, 9GB RAM minimum)"
      echo "     - Slower boot (~5 min)"
      echo ""
      printf "Choice [1]: "
      read -r preset_choice </dev/tty
      echo ""
    else
      preset_choice=""
    fi

    case "${preset_choice:-1}" in
      1 | microshift) SAVED_PRESET="microshift" ;;
      2 | openshift) SAVED_PRESET="openshift" ;;
      *) SAVED_PRESET="microshift" ;;
    esac

    # Save to config
    mkdir -p "$(dirname "${HOME}/.aap-demo/config")"
    if [ -f "${HOME}/.aap-demo/config" ]; then
      if grep -q '^CRC_PRESET=' "${HOME}/.aap-demo/config"; then
        /usr/local/bin/sed -i "s/^CRC_PRESET=.*/CRC_PRESET=${SAVED_PRESET}/" "${HOME}/.aap-demo/config"
      else
        echo "CRC_PRESET=${SAVED_PRESET}" >>"${HOME}/.aap-demo/config"
      fi
    else
      echo "CRC_PRESET=${SAVED_PRESET}" >>"${HOME}/.aap-demo/config"
    fi
    printf "Saved preset: ${SAVED_PRESET}\n"
  fi

  crc config set preset "$SAVED_PRESET" 2>/dev/null
  CURRENT_PRESET="$SAVED_PRESET"
fi

printf "${_GREEN}▸${_NC} CRC preset: ${CURRENT_PRESET}\n"

# ---------------------------------------------------------------------------
# Configure CRC resources
# ---------------------------------------------------------------------------
CRC_CPUS="${CRC_CPUS:-${VM_CPUS:-8}}"
CRC_MEMORY="${CRC_MEMORY:-${VM_MEMORY:-16384}}"
CRC_DISK="${CRC_DISK:-${VM_DISK_SIZE:-100}}"
CRC_PV_SIZE="${CRC_PV_SIZE:-${VM_PV_SIZE:-50}}"

# Validate resource values are positive integers
for _var_name in CRC_CPUS CRC_MEMORY CRC_DISK CRC_PV_SIZE; do
  _var_val="${!_var_name}"
  if ! [[ "$_var_val" =~ ^[0-9]+$ ]] || [ "$_var_val" -le 0 ]; then
    printf "${_RED}▸${_NC} Invalid ${_var_name}: '${_var_val}' (must be a positive integer)\n"
    exit 1
  fi
done

# PV size must be less than disk size to leave room for the root filesystem
if [ "$CRC_PV_SIZE" -ge "$CRC_DISK" ]; then
  printf "${_RED}▸${_NC} CRC_PV_SIZE (${CRC_PV_SIZE}GB) must be less than CRC_DISK (${CRC_DISK}GB)\n"
  exit 1
fi

crc config set cpus "$CRC_CPUS" 2>/dev/null || true
crc config set memory "$CRC_MEMORY" 2>/dev/null || true
crc config set disk-size "$CRC_DISK" 2>/dev/null || true
crc config set persistent-volume-size "$CRC_PV_SIZE" 2>/dev/null || true

printf "${_GREEN}▸${_NC} Resources: ${CRC_CPUS} CPUs, $((CRC_MEMORY / 1024))GB RAM, ${CRC_DISK}GB disk (${CRC_PV_SIZE}GB for PVs)\n"

# ---------------------------------------------------------------------------
# Setup CRC (if needed)
# ---------------------------------------------------------------------------
if [ "$CRC_STATUS" = "Unknown" ]; then
  printf "${_GREEN}▸${_NC} Running CRC setup...\n"
  crc setup --show-progressbars 2>&1 | { grep -E "^level=info|^  " | sed 's/level=info msg="/  /' | sed 's/"$//'; } || true
fi

# ---------------------------------------------------------------------------
# Find pull secret
# ---------------------------------------------------------------------------
PULL_SECRET_PATH="${PULL_SECRET_PATH:-}"
if [ -z "$PULL_SECRET_PATH" ]; then
  for ps in "$HOME/.aap-demo/pull-secret.json" "$HOME/.aap-demo/pull-secret.txt"; do
    if [ -f "$ps" ]; then
      PULL_SECRET_PATH="$ps"
      break
    fi
  done
fi

if [ -z "$PULL_SECRET_PATH" ] || [ ! -f "$PULL_SECRET_PATH" ]; then
  printf "${_RED}▸${_NC} Pull secret not found\n"
  echo ""
  echo "  Download from: https://console.redhat.com/openshift/install/pull-secret"
  echo "  Save to: ~/.aap-demo/pull-secret.txt"
  exit 1
fi

printf "${_GREEN}▸${_NC} Pull secret: ${PULL_SECRET_PATH}\n"

# ---------------------------------------------------------------------------
# Start CRC
# ---------------------------------------------------------------------------
printf "${_GREEN}▸${_NC} Starting CRC...\n"
if ! crc start -p "$PULL_SECRET_PATH" >/tmp/crc-start.log 2>&1; then
  # Retry: pipe pull secret via --pull-secret-file - (non-TTY workaround)
  echo "  Retrying with stdin pull secret..."
  if ! cat "$PULL_SECRET_PATH" | crc start --pull-secret-file - >/tmp/crc-start.log 2>&1; then
    cat /tmp/crc-start.log
    echo "ERROR: crc start failed"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Fix DNS resolver (MicroShift preset bug)
# ---------------------------------------------------------------------------
if [ "$CURRENT_PRESET" = "microshift" ] && [ -f /etc/resolver/testing ]; then
  printf "${_GREEN}▸${_NC} Fixing CRC DNS resolver...\n"
  sudo rm -f /etc/resolver/testing
  echo "  ✓ Removed broken /etc/resolver/testing"
fi

# ---------------------------------------------------------------------------
# Configure nip.io baseDomain (MicroShift only)
# ---------------------------------------------------------------------------
CRC_SSH_KEY="${HOME}/.crc/machines/crc/id_ed25519"
CRC_SSH_OPTS="-i ${CRC_SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

if [ "$CURRENT_PRESET" = "microshift" ]; then
  printf "${_GREEN}▸${_NC} Configuring nip.io baseDomain...\n"

  # Write config drop-in (overrides CRC's 00-microshift-dns.yaml)
  ssh -p 2222 $CRC_SSH_OPTS core@127.0.0.1 "sudo tee /etc/microshift/config.d/99-aap-demo-dns.yaml > /dev/null <<EOF
dns:
  baseDomain: 127.0.0.1.nip.io
EOF" 2>/dev/null

  # Always wipe and restart on create — ensures nip.io is applied cleanly.
  # CRC starts MicroShift with crc.testing before we can write the dropin,
  # so we must wipe the data generated with the wrong domain.
  {
    printf "${_GREEN}▸${_NC} Restarting MicroShift with nip.io domain (clean start)...\n"
    ssh -p 2222 $CRC_SSH_OPTS core@127.0.0.1 'sudo systemctl stop microshift 2>/dev/null; sudo rm -rf /var/lib/microshift; sudo systemctl start microshift' 2>/dev/null

    # Wait for API
    printf "${_GREEN}▸${_NC} Waiting for MicroShift API..."
    for i in $(seq 1 60); do
      if ssh -p 2222 $CRC_SSH_OPTS core@127.0.0.1 'sudo kubectl --kubeconfig /var/lib/microshift/resources/kubeadmin/kubeconfig cluster-info' &>/dev/null; then
        echo " ready"
        break
      fi
      printf "."
      sleep 5
    done

    # Refresh kubeconfig
    ssh -p 2222 $CRC_SSH_OPTS core@127.0.0.1 'sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig' >~/.crc/machines/crc/kubeconfig 2>/dev/null
    echo "  ✓ nip.io baseDomain configured (data wiped)"
  }
fi

# ---------------------------------------------------------------------------
# CoreDNS configuration is deferred to the end of the create flow.
# MicroShift's DNS controller overwrites the configmap during startup,
# so we must wait for all other setup to complete first.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Trust ingress CA
# ---------------------------------------------------------------------------
printf "${_GREEN}▸${_NC} Trusting ingress CA...\n"

CA_CERT="/tmp/crc-ingress-ca.crt"
ssh -p 2222 $CRC_SSH_OPTS core@127.0.0.1 'sudo cat /var/lib/microshift/certs/ingress-ca/ca.crt' >"$CA_CERT" 2>/dev/null

if [ -s "$CA_CERT" ]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    # Remove any previous ingress-ca certs to avoid accumulation
    while sudo security delete-certificate -c "ingress-ca" /Library/Keychains/System.keychain 2>/dev/null; do :; done
    if sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CA_CERT" 2>/dev/null; then
      echo "  ✓ Ingress CA trusted (macOS keychain)"
    else
      printf "${_YELLOW}▸${_NC} Could not add CA (may need admin password)\n"
    fi
  else
    # Linux: copy to system trust store and update (replaces previous)
    if sudo cp "$CA_CERT" /etc/pki/ca-trust/source/anchors/crc-ingress-ca.crt 2>/dev/null \
      && sudo update-ca-trust 2>/dev/null; then
      echo "  ✓ Ingress CA trusted (system ca-trust)"
    else
      printf "${_YELLOW}▸${_NC} Could not add CA to system trust store\n"
    fi
  fi
  rm -f "$CA_CERT"
fi

# ---------------------------------------------------------------------------
# Set up kubeconfig
# ---------------------------------------------------------------------------
printf "${_GREEN}▸${_NC} Configuring kubeconfig...\n"

eval "$(crc oc-env 2>/dev/null)"
mkdir -p "$HOME/.aap-demo"

if [ "$CURRENT_PRESET" = "microshift" ]; then
  cp ~/.crc/machines/crc/kubeconfig "$HOME/.aap-demo/kubeconfig.microshift" 2>/dev/null

  # Set as default kubeconfig (simple copy, no merge)
  # The CRC kubeconfig uses localhost:6443 which is fast and reliable
  mkdir -p "$HOME/.kube"
  cp "$HOME/.crc/machines/crc/kubeconfig" "$HOME/.kube/config"
  chmod 600 "$HOME/.kube/config"
fi

echo "  ✓ KUBECONFIG merged into ~/.kube/config"

# ---------------------------------------------------------------------------
# Register podman connection (MicroShift only)
# ---------------------------------------------------------------------------
if [ "$CURRENT_PRESET" = "microshift" ]; then
  printf "${_GREEN}▸${_NC} Registering podman remote connection...\n"
  podman system connection add aap-demo \
    --identity "$CRC_SSH_KEY" \
    "ssh://core@127.0.0.1:2222/run/podman/podman.sock" 2>/dev/null || true
  echo "  podman --connection aap-demo build ."
fi

# ---------------------------------------------------------------------------
# Install metrics-server (enables oc adm top, kubectl top)
# ---------------------------------------------------------------------------
if [ "$CURRENT_PRESET" = "microshift" ]; then
  printf "${_GREEN}▸${_NC} Installing metrics-server...\n"
  export KUBECONFIG="$HOME/.crc/machines/crc/kubeconfig"
  if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
    echo "  Already installed"
  else
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml 2>/dev/null
    # MicroShift needs --kubelet-insecure-tls
    kubectl patch deployment metrics-server -n kube-system --type=json \
      -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' 2>/dev/null
    echo "  ✓ metrics-server installed"
  fi
fi

# ---------------------------------------------------------------------------
# Create nfs-local-rwx StorageClass (RWX via topolvm on single-node)
# ---------------------------------------------------------------------------
if [ "$CURRENT_PRESET" = "microshift" ]; then
  if kubectl get sc nfs-local-rwx &>/dev/null; then
    echo "  nfs-local-rwx StorageClass already exists"
  else
    printf "${_GREEN}▸${_NC} Setting up NFS storage for RWX support...\n"
    # Deploy in-cluster NFS server backed by topolvm, then
    # nfs-subdir-external-provisioner creates nfs-local-rwx StorageClass.
    # This provides real RWX volumes for hub file storage and CI compat.

    # Grant SCCs for NFS server (needs privileged)
    oc adm policy add-scc-to-group privileged system:serviceaccounts:nfs-storage 2>/dev/null || true

    # Resolve default StorageClass for NFS backing PVC
    DEFAULT_SC=$(kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | awk '{print $1}')
    [ -z "$DEFAULT_SC" ] && DEFAULT_SC="topolvm-provisioner"
    sed "s/__DEFAULT_SC__/${DEFAULT_SC}/g" "${SCRIPT_DIR}/config/manifests/nfs-server.yaml" | kubectl apply -f -
    echo "  Waiting for NFS server..."
    kubectl wait --for=condition=Available deployment/nfs-server -n nfs-storage --timeout=120s 2>/dev/null || {
      echo "  Waiting for NFS backing PVC to bind..."
      sleep 10
      kubectl wait --for=condition=Available deployment/nfs-server -n nfs-storage --timeout=120s
    }
    # Kubelet resolves NFS server by IP (can't use cluster DNS for mount)
    NFS_IP=$(kubectl get svc nfs-server -n nfs-storage -o jsonpath='{.spec.clusterIP}')
    sed "s/__NFS_SERVER_IP__/${NFS_IP}/g" "${SCRIPT_DIR}/config/manifests/nfs-provisioner.yaml" | kubectl apply -f -
    kubectl wait --for=condition=Available deployment/nfs-provisioner -n nfs-storage --timeout=120s
    echo "  ✓ nfs-local-rwx StorageClass created (in-cluster NFS server)"
  fi
fi

# ---------------------------------------------------------------------------
# Deploy saved addons (from ~/.aap-demo/config ADDONS=)
# ---------------------------------------------------------------------------
SAVED_ADDONS=""
if [ -f "${HOME}/.aap-demo/config" ]; then
  SAVED_ADDONS=$(grep '^ADDONS=' "${HOME}/.aap-demo/config" 2>/dev/null | cut -d= -f2 | tr ',' ' ' || true)
fi

if [ -n "$SAVED_ADDONS" ]; then
  printf "${_GREEN}▸${_NC} Deploying saved addons: ${SAVED_ADDONS}...\n"
  for addon in $SAVED_ADDONS; do
    addon_dir="${SCRIPT_DIR}/addons/${addon}"
    if [ ! -f "$addon_dir/deploy.sh" ]; then
      echo "  Skipping $addon (deploy.sh not found)"
      continue
    fi
    # Skip addons that require AAP (marked with ADDON_REQUIRES_AAP=true)
    if grep -q "^# ADDON_REQUIRES_AAP=true" "$addon_dir/deploy.sh"; then
      echo "  Skipping $addon (requires AAP — will deploy after 'aap-demo deploy')"
      continue
    fi
    echo "  Enabling: $addon"
    if ! bash "$addon_dir/deploy.sh" 2>&1 | sed 's/^/    /'; then
      printf "    ${_YELLOW}WARNING: addon '$addon' failed to deploy (continuing)${_NC}\n"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Configure CoreDNS for route resolution inside pods
# (Deferred to end of create flow — MicroShift's DNS controller overwrites
# the configmap during startup, so we must wait for it to finish first)
# ---------------------------------------------------------------------------
printf "${_GREEN}▸${_NC} Configuring CoreDNS for in-cluster route resolution...\n"

export KUBECONFIG="$HOME/.crc/machines/crc/kubeconfig"

# Determine route domain
if [ "$CURRENT_PRESET" = "microshift" ]; then
  ROUTE_DOMAIN="apps.crc.testing"
  CURRENT_DOMAIN=$(ssh -p 2222 $CRC_SSH_OPTS core@127.0.0.1 'grep -h baseDomain /etc/microshift/config.d/99-aap-demo-dns.yaml /etc/microshift/config.yaml 2>/dev/null | head -1' 2>/dev/null | awk '{print $2}' || true)
  if [ -n "$CURRENT_DOMAIN" ]; then
    ROUTE_DOMAIN="apps.${CURRENT_DOMAIN}"
  fi
else
  ROUTE_DOMAIN="apps-crc.testing"
fi

ESCAPED_DOMAIN=$(echo "$ROUTE_DOMAIN" | sed 's/\./\\./g')

# Check if CoreDNS already configured with our rewrite rule
CURRENT_COREFILE=$(kubectl get configmap dns-default -n openshift-dns -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
if echo "$CURRENT_COREFILE" | grep -q "router-internal-default"; then
  echo "  ✓ CoreDNS already configured for ${ROUTE_DOMAIN}"
else
  echo "  Patching CoreDNS ConfigMap..."
  COREFILE=$(
    cat <<COREFILE_EOF
.:5353 {
    bufsize 1232
    errors
    log . {
        class error
    }
    health {
        lameduck 20s
    }
    ready
    rewrite stop {
        name regex (.*)\.${ESCAPED_DOMAIN} router-internal-default.openshift-ingress.svc.cluster.local
        answer auto
    }
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
    }
    prometheus 127.0.0.1:9153
    forward . /etc/resolv.conf {
        policy sequential
    }
    cache 900 {
        denial 9984 30
    }
    reload
}
COREFILE_EOF
  )
  kubectl patch configmap dns-default -n openshift-dns --type merge \
    -p "{\"data\":{\"Corefile\":$(echo "$COREFILE" | jq -Rs .)}}"
  kubectl rollout restart daemonset/dns-default -n openshift-dns 2>/dev/null || true
  kubectl rollout status daemonset/dns-default -n openshift-dns --timeout=60s 2>/dev/null || true

  # Wait for rollout to complete, then verify config persisted
  # MicroShift's DNS operator may reconcile the configmap — re-patch if needed
  sleep 5
  if kubectl get configmap dns-default -n openshift-dns -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -q "router-internal-default"; then
    echo "  ✓ CoreDNS configured: ${ROUTE_DOMAIN} → router service"
  else
    echo "  CoreDNS config was overwritten by DNS operator — re-patching..."
    kubectl patch configmap dns-default -n openshift-dns --type merge \
      -p "{\"data\":{\"Corefile\":$(echo "$COREFILE" | jq -Rs .)}}"
    kubectl rollout restart daemonset/dns-default -n openshift-dns 2>/dev/null || true
    kubectl rollout status daemonset/dns-default -n openshift-dns --timeout=60s 2>/dev/null || true
    sleep 5
    if kubectl get configmap dns-default -n openshift-dns -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -q "router-internal-default"; then
      echo "  ✓ CoreDNS configured (re-patched): ${ROUTE_DOMAIN} → router service"
    else
      printf "  ${_YELLOW}WARNING: CoreDNS config not persisting — DNS operator keeps overwriting${_NC}\n"
      echo "  If pods can't resolve nip.io routes, run: aap-demo start"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Set sysctl for performance (inotify limits for operator watchers)
# Operators use file watchers heavily for reconciliation. Default limits
# (128 instances) cause "too many open files" errors under heavy load.
# Matches infra-ci deployment settings.
# ---------------------------------------------------------------------------
printf "${_GREEN}▸${_NC} Setting sysctl for performance...
"
ssh -p 2222 $CRC_SSH_OPTS core@127.0.0.1 'sudo sysctl -w fs.inotify.max_user_watches=2099999999 fs.inotify.max_user_instances=2099999999 fs.inotify.max_queued_events=2099999999' 2>/dev/null
echo "  ✓ inotify limits configured"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
if [ "$CURRENT_PRESET" = "microshift" ]; then
  RED='\033[1;31m'
  NC='\033[0m'
  echo -e "${RED}           .MMM..:MMMMMMM${NC}"
  echo -e "${RED}          MMMMMMMMMMMMMMMMMM${NC}"
  echo -e "${RED}          MMMMMMMMMMMMMMMMMMMM.${NC}"
  echo -e "${RED}         MMMMMMMMMMMMMMMMMMMMMM${NC}"
  echo -e "${RED}        ,MMMMMMMMMMMMMMMMMMMMMM:${NC}"
  echo -e "${RED}        MMMMMMMMMMMMMMMMMMMMMMMM${NC}"
  echo -e "${RED}  .MMMM'  MMMMMMMMMMMMMMMMMMMMMM${NC}"
  echo -e "${RED} MMMMMM    \`MMMMMMMMMMMMMMMMMMMM.${NC}"
  echo -e "${RED}MMMMMMMM      MMMMMMMMMMMMMMMMMM .${NC}"
  echo -e "${RED}MMMMMMMMM.       \`MMMMMMMMMMMMM' MM.${NC}"
  echo -e "${RED}MMMMMMMMMMM.                     MMMM${NC}"
  echo -e "${RED}\`MMMMMMMMMMMMM.                 ,MMMMM.${NC}"
  echo -e "${RED} \`MMMMMMMMMMMMMMMMM.          ,MMMMMMMM.${NC}"
  echo -e "${RED}    MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM${NC}"
  echo -e "${RED}         MMMMMMMMMMMMMMMMMMMMMMMMMMMMMM${NC}"
  echo -e "${RED}            \`MMMMMMMMMMMMMMMMMMMMMMMM:${NC}"
  echo -e "${RED}                \`\`MMMMMMMMMMMMMMMMM'${NC}"
  echo ""
  echo -e "${RED}✓ CRC MicroShift cluster ready for AAP development!${NC}"
  echo ""
  echo "Features:"
  echo "  - baseDomain: apps.127.0.0.1.nip.io (nip.io routes auto-configured)"
  echo "  - CoreDNS template for in-cluster route resolution"
  echo "  - LVMS storage (topolvm-provisioner, ${CRC_PV_SIZE}GB for PVCs)"
  echo "  - nfs-local-rwx StorageClass (RWX support for hub file storage)"
  echo "  - Pull secret configured for registry.redhat.io"
  echo "  - Shared Podman storage with CRI-O (no registry push required)"
  echo "  - Ingress CA trusted on host system"
  echo "  - metrics-server installed"
  if [ -n "$SAVED_ADDONS" ]; then
    echo "  - Addons deployed: $SAVED_ADDONS"
  fi
  echo ""
  echo "  Routes:     *.apps.127.0.0.1.nip.io"
else
  echo ""
  echo "✓ CRC OpenShift cluster created and ready!"
  echo ""
  echo "  Routes:     *.apps-crc.testing"
fi

echo "  Kubeconfig: export KUBECONFIG=~/.crc/machines/crc/kubeconfig"
echo "  SSH:        aap-demo ssh"
echo ""
echo "  Next: aap-demo deploy    # Deploy AAP"
