#!/usr/bin/env bash
# =============================================================================
# aap-demo - AAP 2.7 Deployment Tool
# =============================================================================
#
# Deploy Ansible Automation Platform 2.7 to OpenShift Local.
#
# Usage:
#   ./aap-demo.sh                     # Deploy AAP 2.7
#   ./aap-demo.sh clean               # Remove AAP deployment
#   ./aap-demo.sh destroy             # Delete entire cluster
#   ./aap-demo.sh stop                # Stop OpenShift Local cluster
#   ./aap-demo.sh start               # Start stopped cluster
#   ./aap-demo.sh repair              # Repair after crash
#   ./aap-demo.sh setup               # Setup only (no deploy)
#   ./aap-demo.sh create              # Create cluster only
#
# Environment variables:
#   NAMESPACE    - Kubernetes namespace (default: aap-operator)
#   QUIET        - Suppress disclaimer (true/false)
#   FORCE        - Force reinstall even if AAP exists (true/false)
#
# =============================================================================

set -e

_err() { printf '\033[0;31mERROR:\033[0m %s\n' "$*" >&2; }

trap '_err "aap-demo.sh failed unexpectedly at line $LINENO (exit code $?)"' ERR

# Resolve symlinks to get actual script directory
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# KUBECONFIG is set later by setup_kubeconfig() after argument parsing

# AAP version
# shellcheck disable=SC2034
AAP_VERSION="2.7"
AAP_CHANNEL="stable-2.7"

# Default values
_NAMESPACE_EXPLICIT="${NAMESPACE:+true}"
NAMESPACE="${NAMESPACE:-aap-operator}"
QUIET="${QUIET:-false}"
FORCE="${FORCE:-false}"

# Config file for persistent settings
AAP_DEMO_CONFIG="${AAP_DEMO_CONFIG:-$HOME/.aap-demo/config}"
AAP_DEMO_CONFIG_FILE="$AAP_DEMO_CONFIG"

# Source config file (command-line env vars take precedence)
if [ -f "$AAP_DEMO_CONFIG" ]; then
  while IFS='=' read -r key value || [ -n "$key" ]; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
    # Only set if not already set in environment
    if [ -z "${!key+x}" ]; then
      export "$key=$value"
    fi
  done <"$AAP_DEMO_CONFIG"
fi

# Infrastructure type (OpenShift Local only)
INFRA_TYPE="crc"
KUBECTL_CONTEXT=""
KUBECTL_KUBECONFIG=""

# Parse command line arguments
COMMAND=""
EXTRA_ARGS=()
PENDING_FLAG=""

for arg in "$@"; do
  # Handle pending flag value
  if [ -n "$PENDING_FLAG" ]; then
    case "$PENDING_FLAG" in
      branch)
        UPDATE_BRANCH="$arg"
        ;;
      context)
        KUBECTL_CONTEXT="$arg"
        ;;
      kubeconfig)
        KUBECTL_KUBECONFIG="$arg"
        ;;
    esac
    PENDING_FLAG=""
    continue
  fi

  case "$arg" in
    --branch=*)
      UPDATE_BRANCH="${arg#*=}"
      ;;
    --branch)
      PENDING_FLAG="branch"
      ;;
    --context=*)
      KUBECTL_CONTEXT="${arg#*=}"
      ;;
    --context)
      PENDING_FLAG="context"
      ;;
    --kubeconfig=*)
      KUBECTL_KUBECONFIG="${arg#*=}"
      ;;
    --kubeconfig)
      PENDING_FLAG="kubeconfig"
      ;;
    deploy | deploy-all | deploy-operator | deploy-aap | repair | clean | destroy | stop | start | setup | create | watch | status | update | config | redeploy | redeploy-all | redhat-status | rh-status | kubeconfig | ssh | idle | diagnose | must-gather | enable | disable | test | help | --help | -h)
      COMMAND="$arg"
      ;;
    --ai | --reset)
      # Flags for diagnose --ai and destroy --reset
      EXTRA_ARGS+=("$arg")
      ;;
    console | registry | mcp-server | registry-ui | olm | portal)
      # Addon names for enable/disable commands
      EXTRA_ARGS+=("$arg")
      ;;
    true | false)
      # Boolean args for idle command
      EXTRA_ARGS+=("$arg")
      ;;
    github)
      # Pass-through arg for config command
      EXTRA_ARGS+=("$arg")
      ;;
    *=*)
      # Handle KEY=VALUE arguments
      # shellcheck disable=SC2163
      export "$arg"
      ;;
    *)
      # Commands that accept arbitrary path args
      if [ "$COMMAND" = "must-gather" ] || [ "$COMMAND" = "clean" ] || [ "$COMMAND" = "test" ]; then
        EXTRA_ARGS+=("$arg")
      elif [ -n "$COMMAND" ]; then
        echo "Unknown argument for '$COMMAND': $arg"
        echo "Run '$0 help' for usage"
        exit 1
      else
        echo "Unknown argument: $arg"
        echo "Run '$0 help' for usage"
        exit 1
      fi
      ;;
  esac
done

# Check for unprocessed pending flag
if [ -n "$PENDING_FLAG" ]; then
  echo "ERROR: --$PENDING_FLAG requires a value"
  exit 1
fi

# Load infrastructure abstraction layer
source "${SCRIPT_DIR}/includes/infra-api.sh"

# -----------------------------------------------------------------------------
# Prerequisite Checks
# -----------------------------------------------------------------------------

check_kubectl() {
  if command -v kubectl &>/dev/null; then
    return 0
  fi

  # OpenShift Local / MicroShift hosts often have oc but not kubectl (common on Windows).
  if command -v oc &>/dev/null; then
    kubectl() {
      oc "$@"
    }
    return 0
  fi

  if command -v crc &>/dev/null; then
    local _crc_oc_path
    _crc_oc_path=$(crc oc-env 2>/dev/null | grep 'PATH=' | sed 's/.*PATH="\([^:]*\):.*/\1/' | head -1)
    if [ -n "$_crc_oc_path" ] && [ -d "$_crc_oc_path" ] && [ -x "$_crc_oc_path/oc" ]; then
      export PATH="$_crc_oc_path:$PATH"
      kubectl() {
        oc "$@"
      }
      return 0
    fi
  fi

  _err "kubectl not found"
  echo ""
  echo "Install kubectl or the OpenShift CLI (oc):"
  echo ""
  case "$(uname -s)" in
    Darwin)
      echo "  # macOS (Homebrew)"
      echo "  brew install kubectl"
      echo ""
      echo "  # macOS (manual)"
      if [ "$(uname -m)" = "arm64" ]; then
        echo "  curl -LO https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/arm64/kubectl"
      else
        echo "  curl -LO https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
      fi
      echo "  chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
      ;;
    MINGW* | MSYS* | CYGWIN*)
      echo "  winget install --id RedHat.OpenShift-Client -e --source winget"
      echo "  # oc works as kubectl for aap-demo commands"
      ;;
    *)
      echo "  # Linux"
      echo "  sudo dnf install kubectl"
      echo "  OR"
      echo "  curl -LO https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
      echo "  chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
      ;;
  esac
  echo ""
  echo "Or download from: https://kubernetes.io/docs/tasks/tools/"
  return 1
}

# -----------------------------------------------------------------------------
# Infrastructure Type Handling
# -----------------------------------------------------------------------------

# Setup KUBECONFIG based on infrastructure type
setup_kubeconfig() {
  check_kubectl || exit 1
  # Apply --kubeconfig override first (takes precedence)
  if [ -n "$KUBECTL_KUBECONFIG" ]; then
    if [ ! -f "$KUBECTL_KUBECONFIG" ]; then
      echo "ERROR: Kubeconfig file not found: $KUBECTL_KUBECONFIG"
      exit 1
    fi
    export KUBECONFIG="$KUBECTL_KUBECONFIG"
  else
    # Use OpenShift Local kubeconfig — only refresh if current one doesn't work
    if [ -f "$HOME/.crc/machines/crc/kubeconfig" ]; then
      export KUBECONFIG="$HOME/.crc/machines/crc/kubeconfig"
    fi
    # Test if kubeconfig works, refresh from VM if not
    if ! kubectl cluster-info &>/dev/null 2>&1; then
      if [ -f "$HOME/.crc/machines/crc/id_ed25519" ]; then
        if ssh -p 2222 -i "$HOME/.crc/machines/crc/id_ed25519" \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
          -o ConnectTimeout=2 -o BatchMode=yes \
          core@127.0.0.1 'sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig' \
          >"$HOME/.crc/machines/crc/kubeconfig.tmp" 2>/dev/null; then
          mv "$HOME/.crc/machines/crc/kubeconfig.tmp" "$HOME/.crc/machines/crc/kubeconfig"
          export KUBECONFIG="$HOME/.crc/machines/crc/kubeconfig"
        else
          rm -f "$HOME/.crc/machines/crc/kubeconfig.tmp"
        fi
      fi
    fi
  fi

  # Apply context override if specified
  if [ -n "$KUBECTL_CONTEXT" ]; then
    if ! kubectl config use-context "$KUBECTL_CONTEXT" >/dev/null 2>&1; then
      echo "ERROR: Context '$KUBECTL_CONTEXT' not found"
      echo ""
      echo "Available contexts:"
      kubectl config get-contexts -o name 2>/dev/null | sed 's/^/  /' || echo "  (none)"
      exit 1
    fi
  fi
}

# Verify cluster state
verify_cluster_type() {
  local state
  state=$(infra_get_state)
  if [ "$state" = "not_created" ]; then
    echo "WARNING: No cluster exists"
    echo "  Run 'aap-demo create' first"
    echo ""
  elif [ "$state" = "stopped" ]; then
    echo "WARNING: Cluster exists but is stopped"
    echo "  Run 'crc start' to start it"
    echo ""
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Preflight: mkcert CA check (macOS and Linux)
# -----------------------------------------------------------------------------
check_mkcert_ca() {
  # Skip if mkcert is disabled
  [ "${AAP_DEMO_MKCERT:-true}" != "true" ] && return 0

  # Skip if mkcert not installed (will be installed during setup)
  command -v mkcert &>/dev/null || return 0

  local CA_INSTALLED=false

  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS: check system and login keychains
    if security find-certificate -a -c "mkcert" /Library/Keychains/System.keychain 2>/dev/null | grep -q "mkcert" \
      || security find-certificate -a -c "mkcert" ~/Library/Keychains/login.keychain-db 2>/dev/null | grep -q "mkcert"; then
      CA_INSTALLED=true
    fi
  else
    # Linux: check if CA file exists in system trust store
    CAROOT="$(mkcert -CAROOT 2>/dev/null)"
    if [ -f "$CAROOT/rootCA.pem" ]; then
      # Check if it's been added to system trust
      # shellcheck disable=SC2144
      if compgen -G "/etc/ssl/certs/mkcert*" >/dev/null \
        || compgen -G "/usr/local/share/ca-certificates/mkcert*" >/dev/null \
        || compgen -G "/etc/pki/ca-trust/source/anchors/mkcert*" >/dev/null; then
        CA_INSTALLED=true
      elif trust list 2>/dev/null | grep -q "mkcert"; then
        CA_INSTALLED=true
      elif [ -f "$CAROOT/rootCA.pem" ]; then
        # CA file exists, assume mkcert -install was run
        CA_INSTALLED=true
      fi
    fi
  fi

  if [ "$CA_INSTALLED" = false ]; then
    echo ""
    echo "  Trusted SSL Setup Required"
    echo "  --------------------------"
    echo "  aap-demo uses mkcert to generate locally-trusted SSL certificates."
    echo "  This eliminates browser security warnings for *.apps.127.0.0.1.nip.io"
    echo ""
    echo "  To add the certificate authority to your system trust store, run:"
    echo ""
    echo "      mkcert -install"
    echo ""
    echo "  You will be prompted for your system administrator password (sudo)."
    echo "  This is a one-time setup per machine."
    echo ""
    echo "  Firefox: Install certutil first (brew install nss / apt install libnss3-tools)"
    echo ""
    echo "  To skip trusted SSL: AAP_DEMO_MKCERT=false aap-demo deploy"
    echo ""
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
show_welcome() {
  cat <<'EOF'
aap-demo - Deploy AAP 2.7 to OpenShift Local

Usage: aap-demo [options] <command>

Commands:
  deploy          Deploy AAP 2.7
  deploy-operator Deploy operator only
  status          Show cluster and AAP status
  idle [true|false] Scale down/up AAP to save resources
  diagnose [--ai] Check environment health (--ai for Claude analysis)
  must-gather      Collect diagnostic info (AAP + cluster)
  clean           Remove AAP deployment

Cluster management:
  create          Create OpenShift Local cluster
  destroy         Delete cluster (--reset to clear config)
  stop            Stop cluster
  ssh             SSH into cluster node

Addons:
  enable portal   Enable Self-Service Portal
  enable mcp-server Enable MCP server for AI assistants

Examples:
  aap-demo deploy                 # Deploy AAP 2.7
  aap-demo enable portal          # Enable Self-Service Portal addon

Run 'aap-demo help' for full documentation.
EOF
}

show_help() {
  cat <<'EOF'
aap-demo - Deploy AAP 2.7 to OpenShift Local

USAGE:
    aap-demo [OPTIONS] <COMMAND>

OPTIONS:
    --kubeconfig=FILE   Path to kubeconfig file (default: ~/.kube/config)
    --context=NAME      kubectl context to use (default: current context)
    NAMESPACE=<name>    Kubernetes namespace (default: aap-operator)
    QUIET=true          Suppress disclaimer
    FORCE=true          Force reinstall even if AAP exists

COMMANDS (all infrastructure types):
    deploy          Deploy AAP 2.7 (operator + CR)
    deploy-operator Deploy operator only, skip AAP CR
    deploy-aap      Apply AAP CR only (assumes operator installed)
                    Options: CR=name PUBLIC_URL=https://...
    status          Show cluster and AAP status
    clean           Remove AAP deployment
    watch           Watch AAP deployment status
    redeploy        Clean AAP and redeploy
    idle [true|false] Scale down/up AAP to save resources
                    No arg: show current state
                    true:   scale down all components
                    false:  scale up all components
    diagnose [--ai] Check environment health and identify common issues
                    Checks: cluster, storage, SCCs, pods, PVCs, DNS
                    --ai: analyze issues with Claude AI (requires 'claude' CLI)
    test [markers]  Run ATF test suite against deployed AAP
                    Default markers: interop (comma-separate for multiple)
                    NAMESPACE=<ns>: target a specific namespace
                    Requires: aapqa collections (auto-installed from GitLab)
    must-gather [dir] Collect AAP and cluster diagnostics
                    Uses AAP must-gather image for AAP-specific collection
                    Output saved to must-gather.local.<timestamp> (or specified dir)
    enable [addon]  Enable an addon (olm, console, registry, mcp-server, portal)
    disable [addon] Disable an addon
    redhat-status   Check Red Hat registry status (alias: rh-status)
    config          Configure aap-demo settings
    update          Pull latest code and reinstall
    help            Show this help

COMMANDS:
    create          Create OpenShift Local cluster
    destroy [--reset] Delete local cluster (--reset also clears config)
    stop            Stop local cluster gracefully
    start           Start stopped cluster (re-applies CoreDNS config)
    ssh             SSH into cluster node
    repair          Repair cluster after crash
    setup           Run setup only (storage, coredns, mkcert)
    kubeconfig      Extract and merge kubeconfig
    redeploy-all    Destroy cluster and redeploy fresh

ENVIRONMENT:
    AAP_DEMO_ANSIBLE    Use Ansible by default (true/false)

EXAMPLES:
    aap-demo create                  # Create OpenShift Local cluster
    aap-demo deploy                  # Deploy AAP 2.7
    aap-demo status                  # Show cluster and AAP status
    aap-demo stop                    # Stop cluster
    aap-demo start                   # Start stopped cluster
    aap-demo ssh                     # SSH into cluster node
    aap-demo enable console          # Enable web console addon

REQUIREMENTS:
    - OpenShift Local — https://console.redhat.com/openshift/create/local
    - On Linux: libvirt-daemon, libvirt-daemon-driver-storage, qemu-kvm

    For all deployments:
    - kubectl
    - Pull secret at ~/.aap-demo/pull-secret.txt (from console.redhat.com)

EOF
}

# -----------------------------------------------------------------------------
# Pull Secret Selection
# -----------------------------------------------------------------------------
determine_pull_secret() {
  for path in "${PULL_SECRET_PATH:-}" "$HOME/.aap-demo/pull-secret" "$HOME/.aap-demo/pull-secret.txt" "$HOME/.aap-demo/pull-secret.json"; do
    if [ -n "$path" ] && [ -f "$path" ]; then
      echo "$path"
      return
    fi
  done
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

cmd_repair() {
  echo "CRC repair: run 'crc stop && crc start'"
}

# Shared function: display cluster info for warnings
_show_cluster_info() {
  local _CLUSTER _API _AAP_COUNT _POD_COUNT
  _CLUSTER=$(kubectl config current-context 2>/dev/null) || _CLUSTER="unknown"
  _API=$(kubectl cluster-info --request-timeout=2s 2>/dev/null | head -1 | sed 's/.*is running at //' | sed 's/\x1b\[[0-9;]*m//g') || _API="unknown"
  _AAP_COUNT=$(kubectl get aap -n "${NAMESPACE:-aap-operator}" --no-headers --request-timeout=2s 2>/dev/null | wc -l | tr -d ' ') || _AAP_COUNT="0"
  _POD_COUNT=$(kubectl get pods -A --no-headers --request-timeout=2s 2>/dev/null | wc -l | tr -d ' ') || _POD_COUNT="0"

  echo "  Infra:            crc"
  echo "  Cluster Context:  ${_CLUSTER}"
  echo "  API Server:       ${_API}"
  echo "  Namespace:        ${NAMESPACE:-aap-operator}"
  echo "  AAP Instances:    ${_AAP_COUNT}"
  if [ -n "${1:-}" ]; then
    echo "  Total Pods:       ${_POD_COUNT}"
  fi
  return 0
}

# Prune unused container images on cluster VM
_prune_unused_images() {

  _infra_ensure_backend 2>/dev/null || return 0

  echo ""
  echo "Pruning unused container images..."
  local _prune_output
  _prune_output=$(infra_exec_cmd bash -c 'sudo crictl rmi --prune 2>&1' 2>/dev/null) || _prune_output=""
  local _pruned
  _pruned=$(echo "$_prune_output" | grep -ci "deleted" 2>/dev/null) || _pruned=0

  if [ "$_pruned" -gt 0 ] 2>/dev/null; then
    echo "  ✓ Pruned ${_pruned} unused images"
  else
    echo "  ✓ No unused images to prune"
  fi
}

# Check disk space on the CRC VM
# Warns at >80% usage, errors at >95%
_check_disk_space() {

  _infra_ensure_backend 2>/dev/null || return 0

  local disk_usage=""
  disk_usage=$(infra_exec_cmd bash -c "df /var --output=pcent 2>/dev/null | tail -1 | tr -d ' %'" 2>/dev/null) || true

  if [ -z "$disk_usage" ]; then
    return 0
  fi

  if [ "$disk_usage" -ge 95 ] 2>/dev/null; then
    echo ""
    echo "ERROR: Cluster VM disk is ${disk_usage}% full"
    echo ""
    echo "  Free space by pruning unused container images:"
    echo "    aap-demo ssh"
    echo "    sudo crictl rmi --prune"
    echo ""
    echo "  Or destroy and recreate with a larger disk:"
    echo "    aap-demo destroy && aap-demo create"
    return 1
  elif [ "$disk_usage" -ge 80 ] 2>/dev/null; then
    echo ""
    printf "  \033[1;33mWARNING: Cluster VM disk is ${disk_usage}%% full\033[0m\n"
    echo "  Consider pruning unused images: aap-demo ssh && sudo crictl rmi --prune"
    echo ""
  fi
  return 0
}

# Verify cluster is accessible — used before deploy, enable, and other cluster operations
_verify_cluster() {
  setup_kubeconfig
  if kubectl cluster-info &>/dev/null 2>&1; then
    return 0
  fi

  # Cluster not accessible — try to recover
  local cluster_state
  cluster_state=$(infra_get_state 2>/dev/null || echo "not_created")

  if [ "$cluster_state" = "stopped" ]; then
    echo "Cluster is stopped. Starting..."
    _start_crc_cluster
    setup_kubeconfig
    if kubectl cluster-info &>/dev/null 2>&1; then
      return 0
    fi
  elif [ "$cluster_state" = "not_created" ]; then
    echo ""
    echo "No cluster found."
    echo ""
    if [ -t 0 ]; then
      printf "Create one now? [Y/n]: "
      read -t 15 -r _create_choice || true
      if [ -z "$_create_choice" ] || [[ "$_create_choice" =~ ^[Yy] ]]; then
        cmd_create || return 1
        setup_kubeconfig
        if kubectl cluster-info &>/dev/null 2>&1; then
          return 0
        fi
      fi
    else
      echo "  Run: aap-demo create"
    fi
  fi

  echo ""
  echo "ERROR: Cluster is not accessible"
  echo "  Run: aap-demo create   # Create a new cluster"
  echo "  Run: crc start    # Start a stopped cluster"
  echo "  Run: aap-demo status   # Check cluster status"
  return 1
}

cmd_clean() {
  setup_kubeconfig
  _clean_operator
}

_clean_operator() {
  local ns="${NAMESPACE:-aap-operator}"

  echo ""
  printf "\033[1maap-demo clean\033[0m - Removing AAP operator deployment...\n"
  echo ""

  echo "WARNING: AAP CLEANUP - DESTRUCTIVE OPERATION!"
  echo ""
  _show_cluster_info
  echo ""

  local _aap_count
  _aap_count=$(kubectl get aap -n "$ns" --no-headers --request-timeout=2s 2>/dev/null | wc -l | tr -d ' ')
  if [ "${_aap_count:-0}" -gt 0 ] 2>/dev/null; then
    echo "  AAP resources that will be DELETED:"
    kubectl get aap -n "$ns" --no-headers --request-timeout=2s 2>/dev/null | awk '{print "    - " $1}'
    echo ""
  fi

  echo "This will DELETE the namespace '$ns' and all resources within it!"
  echo ""

  if [ "${QUIET:-false}" != "true" ]; then
    echo "Press Ctrl+C to cancel, or press Enter to continue immediately..."
    echo "Auto-continuing in 10 seconds..."
    read -t 10 -r || true
    echo ""
  fi

  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    # Clean up OLM resources created by operator-sdk run bundle
    if command -v operator-sdk &>/dev/null; then
      echo "  Cleaning up OLM resources..."
      operator-sdk cleanup ansible-automation-platform-operator -n "$ns" 2>/dev/null || true
      # Ensure OLM operators weren't scaled down by cleanup
      kubectl scale deploy catalog-operator olm-operator -n olm --replicas=1 2>/dev/null || true
    fi

    # Remove ownerReferences from child CRs to prevent cascade deletion deadlock
    # (blockOwnerDeletion: true causes namespace termination to hang)
    for aap_cr in $(kubectl get aap -n "$ns" --no-headers -o name 2>/dev/null); do
      echo "  Removing owner references from children..."
      kubectl patch "$aap_cr" -n "$ns" --type merge -p '{"spec":{"remove_owner_references_from_children": true}}' 2>/dev/null || true
      # Give the operator a moment to reconcile and strip ownerRefs
      sleep 3
      echo "  Deleting AAP CR..."
      kubectl delete "$aap_cr" -n "$ns" --timeout=30s 2>/dev/null || true
    done

    echo "Deleting namespace $ns..."
    kubectl delete namespace "$ns" --timeout=60s 2>/dev/null || true
    echo "✓ AAP operator deployment removed"

    # Prune unused container images on cluster VM to reclaim disk space
    _prune_unused_images
  else
    echo "Namespace $ns not found - nothing to clean"
  fi
}

cmd_config() {
  local key="${1:-}"
  local value="${2:-}"

  # Ensure config directory exists
  mkdir -p "$(dirname "$AAP_DEMO_CONFIG")"
}

cmd_redhat_status() {
  echo ""
  printf "\033[1maap-demo redhat-status\033[0m - Checking Red Hat service status...\n"
  echo ""

  RSS_URL="https://status.redhat.com/history.rss"

  # Fetch RSS feed
  RSS_CONTENT=$(curl -s --connect-timeout 5 "$RSS_URL" 2>/dev/null)
  if [ -z "$RSS_CONTENT" ]; then
    echo "Unable to fetch status from $RSS_URL"
    exit 1
  fi

  # Parse active incidents (not Resolved/Completed)
  # Filter for registry-related issues
  echo "Active Incidents:"
  echo "================="

  # Extract items and check for active registry issues
  ACTIVE_FOUND=false
  while IFS= read -r item; do
    # Skip resolved/completed items
    if echo "$item" | grep -qi "Resolved\|Completed"; then
      continue
    fi

    # Check if it's registry-related or recent (within last 24h would need date parsing)
    if echo "$item" | grep -qi "registry\|quay\|rhsso\|login\|403\|authentication"; then
      TITLE=$(echo "$item" | sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p' | head -1 | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g')
      STATUS=$(echo "$item" | grep -oE "(Investigating|Identified|Monitoring|In progress|Update)" | head -1)
      LINK=$(echo "$item" | sed -n 's/.*<link>\([^<]*\)<\/link>.*/\1/p' | head -1)

      if [ -n "$TITLE" ]; then
        ACTIVE_FOUND=true
        echo ""
        printf "  \033[1;33m⚠ %s\033[0m\n" "$TITLE"
        [ -n "$STATUS" ] && echo "    Status: $STATUS"
        [ -n "$LINK" ] && echo "    Details: $LINK"
      fi
    fi
  done <<<"$(echo "$RSS_CONTENT" | tr '\n' ' ' | sed 's/<item>/\n<item>/g')"

  if [ "$ACTIVE_FOUND" = false ]; then
    printf "  \033[1;32m✓ No active registry-related incidents\033[0m\n"
  fi

  echo ""
  echo "Full status: https://status.redhat.com"
}

cmd_idle() {
  local value="${1:-}"

  # Check if AAP CR exists
  local AAP_NAME
  AAP_NAME=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$AAP_NAME" ]; then
    echo "✗ No AAP instance found in namespace $NAMESPACE"
    exit 1
  fi

  local CURRENT
  CURRENT=$(kubectl get aap "$AAP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.idle_aap}' 2>/dev/null)

  # No argument: show current state
  if [ -z "$value" ]; then
    if [ "$CURRENT" = "true" ]; then
      echo "AAP '$AAP_NAME' is idle (scaled down)"
      echo "  Resume with: aap-demo idle false"
    else
      echo "AAP '$AAP_NAME' is running"
      echo "  Scale down with: aap-demo idle true"
    fi
    return 0
  fi

  case "$value" in
    true)
      if [ "$CURRENT" = "true" ]; then
        echo "AAP '$AAP_NAME' is already idle"
        return 0
      fi
      echo ""
      printf "\033[1maap-demo idle true\033[0m - Scaling down AAP deployment...\n"
      kubectl patch aap "$AAP_NAME" -n "$NAMESPACE" --type merge -p '{"spec":{"idle_aap":true}}'
      echo ""
      echo "✓ AAP '$AAP_NAME' set to idle"
      echo "  The operator will scale down all components (this may take a minute)"
      echo "  Resume with: aap-demo idle false"
      ;;
    false)
      if [ "$CURRENT" != "true" ]; then
        echo "AAP '$AAP_NAME' is already running"
        return 0
      fi
      echo ""
      printf "\033[1maap-demo idle false\033[0m - Scaling up AAP deployment...\n"
      kubectl patch aap "$AAP_NAME" -n "$NAMESPACE" --type merge -p '{"spec":{"idle_aap":false}}'
      echo ""
      echo "✓ AAP '$AAP_NAME' waking up"
      echo "  The operator will scale up all components (this may take a few minutes)"
      echo "  Monitor with: aap-demo watch"
      ;;
    *)
      echo "Usage: aap-demo idle [true|false]"
      echo "  true   Scale down all AAP components"
      echo "  false  Scale up all AAP components"
      echo "  (no arg) Show current idle state"
      exit 1
      ;;
  esac
}

cmd_must_gather() {
  echo ""
  printf "\033[1maap-demo must-gather\033[0m - Collecting diagnostic information...\n"
  echo ""

  local dest_dir="${1:-must-gather.local.$(date +%Y%m%d%H%M%S)}"
  local aap_image="registry.redhat.io/ansible-automation-platform-26/aap-must-gather-rhel9:latest"

  echo "Output directory: ${dest_dir}"
  echo ""

  mkdir -p "${dest_dir}/aap-demo"

  # Collect aap-demo specific diagnostics
  echo "Collecting aap-demo diagnostics..."
  cp "${HOME}/.aap-demo/config" "${dest_dir}/aap-demo/config" 2>/dev/null || true
  crc status >"${dest_dir}/aap-demo/crc-status.txt" 2>&1 || true
  crc version >"${dest_dir}/aap-demo/crc-version.txt" 2>&1 || true
  kubectl get sc -o yaml >"${dest_dir}/aap-demo/storageclasses.yaml" 2>/dev/null || true
  kubectl get pvc -n "$NAMESPACE" -o yaml >"${dest_dir}/aap-demo/pvcs.yaml" 2>/dev/null || true
  kubectl get pods -n "$NAMESPACE" -o wide >"${dest_dir}/aap-demo/pods.txt" 2>/dev/null || true
  kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' >"${dest_dir}/aap-demo/events.txt" 2>/dev/null || true
  kubectl get aap -n "$NAMESPACE" -o yaml >"${dest_dir}/aap-demo/aap-cr.yaml" 2>/dev/null || true
  {
    echo "=== ClusterRoleBindings (SCC grants) for $NAMESPACE ==="
    kubectl get clusterrolebinding -o wide 2>/dev/null | grep -E "scc:.*(${NAMESPACE}|system:serviceaccounts:${NAMESPACE})" || echo "(none found)"
    echo ""
    echo "=== RoleBindings in $NAMESPACE ==="
    kubectl get rolebinding -n "$NAMESPACE" -o wide 2>/dev/null || echo "(none)"
  } >"${dest_dir}/aap-demo/scc-bindings.txt" 2>/dev/null || true
  kubectl get pods -n nfs-storage -o wide >"${dest_dir}/aap-demo/nfs-pods.txt" 2>/dev/null || true
  kubectl get configmap -n openshift-dns dns-default -o yaml >"${dest_dir}/aap-demo/coredns-config.yaml" 2>/dev/null || true
  echo "  ✓ aap-demo diagnostics collected"
  echo ""

  # Run AAP must-gather
  echo "Running AAP must-gather..."
  echo "  This will launch a pod to collect AAP-specific diagnostics."
  echo "  It may take several minutes to complete."
  echo ""

  oc adm must-gather \
    --image="${aap_image}" \
    --dest-dir="${dest_dir}" 2>&1 | while IFS= read -r line; do
    echo "  $line"
  done

  local exit_code=${PIPESTATUS[0]}

  echo ""
  if [ "$exit_code" -eq 0 ]; then
    echo "✓ Must-gather complete: ${dest_dir}"
  else
    echo "⚠ AAP must-gather failed (exit code: ${exit_code})"
    echo "  aap-demo diagnostics were still collected successfully."
  fi

  echo ""
  echo "Contents:"
  ls -1 "${dest_dir}" 2>/dev/null | sed 's/^/  /'
  echo ""
  echo "To share: tar czf must-gather.tar.gz ${dest_dir}"
}

cmd_diagnose() {
  echo ""
  printf "\033[1maap-demo diagnose\033[0m - Checking environment health...\n"
  echo ""

  local issues=0
  local warnings=0

  _check_pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; }
  _check_fail() {
    printf "  \033[31m✗\033[0m %s\n" "$1"
    issues=$((issues + 1))
  }
  _check_warn() {
    printf "  \033[33m⚠\033[0m %s\n" "$1"
    warnings=$((warnings + 1))
  }
  _check_info() { printf "  \033[36m·\033[0m %s\n" "$1"; }

  # =========================================================================
  # Cluster connectivity
  # =========================================================================
  echo "Cluster:"
  local crc_state
  crc_state=$(crc status -o json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('crcStatus','unknown'))" 2>/dev/null || echo "unknown")
  if [ "$crc_state" = "Running" ]; then
    local ms_version
    ms_version=$(crc status -o json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('openshiftVersion',''))" 2>/dev/null || echo "")
    _check_pass "OpenShift Local running"
  elif [ "$crc_state" = "Stopped" ]; then
    _check_fail "OpenShift Local is stopped — run: crc start"
  else
    _check_fail "OpenShift Local cluster not found — run: aap-demo create"
  fi

  if kubectl cluster-info &>/dev/null; then
    _check_pass "kubectl connected"
  else
    _check_fail "kubectl cannot connect to cluster"
    echo ""
    echo "Cannot proceed without cluster connectivity."
    echo "  Check KUBECONFIG: ${KUBECONFIG:-~/.kube/config}"
    return 1
  fi
  echo ""

  # =========================================================================
  # Storage
  # =========================================================================
  echo "Storage:"
  if kubectl get sc topolvm-provisioner &>/dev/null; then
    _check_pass "topolvm-provisioner StorageClass (default)"
  else
    _check_warn "topolvm-provisioner StorageClass not found"
  fi

  if kubectl get sc nfs-local-rwx &>/dev/null; then
    _check_pass "nfs-local-rwx StorageClass (RWX)"
    # Check NFS server health
    local nfs_ready
    nfs_ready=$(kubectl get deployment nfs-server -n nfs-storage -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${nfs_ready:-0}" -gt 0 ]; then
      _check_pass "NFS server pod running"
    else
      _check_fail "NFS server pod not running — run: aap-demo create (or kubectl rollout restart deployment/nfs-server -n nfs-storage)"
    fi
  else
    _check_warn "nfs-local-rwx StorageClass not found — hub RWX storage unavailable"
    _check_info "Fix: re-run 'aap-demo create' to deploy NFS provisioner, or create the StorageClass manually"
  fi

  # Check disk usage
  local disk_pct
  disk_pct=$(crc status -o json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); u=d.get('diskUse',0); t=d.get('diskSize',1); print(int(u/t*100))" 2>/dev/null || echo "0")
  if [ "$disk_pct" -gt 90 ]; then
    _check_fail "Disk usage: ${disk_pct}% — critically low space"
  elif [ "$disk_pct" -gt 80 ]; then
    _check_warn "Disk usage: ${disk_pct}% — consider pruning: aap-demo ssh && sudo crictl rmi --prune"
  else
    _check_pass "Disk usage: ${disk_pct}%"
  fi
  echo ""

  # =========================================================================
  # Security
  # =========================================================================
  echo "Security:"
  local ns_exists=false
  kubectl get namespace "$NAMESPACE" &>/dev/null && ns_exists=true

  local scc_anyuid=0 scc_privileged=0
  if $ns_exists; then
    # SCC grants create ClusterRoleBindings, not namespace RoleBindings
    local _crb_list
    _crb_list=$(kubectl get clusterrolebinding -o wide 2>/dev/null || true)
    scc_anyuid=$(echo "$_crb_list" | grep -c "scc:anyuid.*system:serviceaccounts:${NAMESPACE}" || true)
    scc_privileged=$(echo "$_crb_list" | grep -c "scc:privileged.*system:serviceaccounts:${NAMESPACE}" || true)
    # Fallback: check namespace rolebindings (older oc versions)
    if [ "${scc_anyuid:-0}" -eq 0 ]; then
      scc_anyuid=$(kubectl get rolebinding -n "$NAMESPACE" -o wide 2>/dev/null | grep -c "scc:anyuid" || true)
    fi
    if [ "${scc_privileged:-0}" -eq 0 ]; then
      scc_privileged=$(kubectl get rolebinding -n "$NAMESPACE" -o wide 2>/dev/null | grep -c "scc:privileged" || true)
    fi
  fi

  if [ "${scc_anyuid:-0}" -gt 0 ] && [ "${scc_privileged:-0}" -gt 0 ]; then
    _check_pass "SCCs granted (anyuid + privileged) in $NAMESPACE"
  elif [ "$scc_anyuid" -gt 0 ]; then
    _check_warn "Only anyuid SCC granted — privileged missing in $NAMESPACE"
  elif [ "$scc_privileged" -gt 0 ]; then
    _check_warn "Only privileged SCC granted — anyuid missing in $NAMESPACE"
  else
    if $ns_exists; then
      _check_fail "No SCCs granted in $NAMESPACE — pods will fail to start"
      _check_info "Fix: oc adm policy add-scc-to-group anyuid system:serviceaccounts:$NAMESPACE"
      _check_info "Fix: oc adm policy add-scc-to-group privileged system:serviceaccounts:$NAMESPACE"
    else
      _check_info "Namespace $NAMESPACE does not exist yet (will be created on deploy)"
    fi
  fi

  # Check supplementalGroups on gateway deployment (OpenShift Local needs group 0)
  if $ns_exists; then
    local _gw_deploy _gw_sg
    _gw_deploy=$(kubectl get deployment -n "$NAMESPACE" -o name 2>/dev/null | grep gateway | grep -v operator | head -1)
    if [ -n "$_gw_deploy" ]; then
      _gw_sg=$(kubectl get "$_gw_deploy" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.securityContext.supplementalGroups}' 2>/dev/null || echo "")
      if [ "$_gw_sg" = "[0]" ]; then
        _check_pass "Gateway has supplementalGroups: [0]"
      else
        _check_fail "Gateway missing supplementalGroups: [0] — supervisord will crash with EACCES"
        _check_info "Fix: kubectl patch $_gw_deploy -n $NAMESPACE --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/securityContext/supplementalGroups\",\"value\":[0]}]'"
      fi
    fi
  fi

  # Check namespace PSA labels
  local psa_enforce
  if $ns_exists; then
    psa_enforce=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || echo "")
    if [ "$psa_enforce" = "privileged" ]; then
      _check_pass "Namespace PSA labels: privileged"
    elif [ -n "$psa_enforce" ]; then
      _check_warn "Namespace PSA enforce: $psa_enforce (expected: privileged)"
    else
      _check_fail "Namespace $NAMESPACE missing PSA labels"
    fi
  fi
  echo ""

  # =========================================================================
  # AAP deployment
  # =========================================================================
  echo "AAP Deployment:"
  local aap_name
  aap_name=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [ -z "$aap_name" ]; then
    _check_info "No AAP instance found in $NAMESPACE"
  else
    # Check idle state
    local idle_state
    idle_state=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.spec.idle_aap}' 2>/dev/null)
    if [ "$idle_state" = "true" ]; then
      _check_info "AAP '$aap_name' is idle (scaled down)"
    else
      # Check AAP status conditions
      local aap_status
      aap_status=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null)
      local aap_failure
      aap_failure=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failure")].status}' 2>/dev/null)

      if [ "$aap_status" = "True" ]; then
        _check_pass "AAP '$aap_name' deployed successfully"
      elif [ "$aap_failure" = "True" ]; then
        local fail_msg
        fail_msg=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failure")].message}' 2>/dev/null)
        _check_fail "AAP '$aap_name' has failures: ${fail_msg:-unknown}"
      else
        _check_warn "AAP '$aap_name' is still reconciling"
      fi
    fi

    # Check pods
    local total_pods running_pods problem_pods
    total_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -cv "Completed" || true)
    running_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Running" || true)
    problem_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -cE "CrashLoopBackOff|Error|ImagePullBackOff|Pending" || true)

    if [ "${problem_pods:-0}" -gt 0 ]; then
      _check_fail "$problem_pods pod(s) in error state ($running_pods/${total_pods:-0} running)"
      local problem_list
      problem_list=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -E "CrashLoopBackOff|Error|ImagePullBackOff|Pending" || true)
      if [ -n "$problem_list" ]; then
        while IFS= read -r line; do
          _check_info "  $line"
        done <<<"$problem_list"
      fi
    elif [ "${total_pods:-0}" -gt 0 ]; then
      _check_pass "All pods healthy ($running_pods/$total_pods running)"
    fi

    # Check PVCs
    local pending_pvcs
    pending_pvcs=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Pending" || true)
    if [ "${pending_pvcs:-0}" -gt 0 ]; then
      _check_fail "$pending_pvcs PVC(s) pending"
      local pending_list
      pending_list=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep "Pending" || true)
      if [ -n "$pending_list" ]; then
        while IFS= read -r line; do
          _check_info "  $line"
        done <<<"$pending_list"
      fi
    else
      local bound_pvcs
      bound_pvcs=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Bound" || true)
      if [ "$bound_pvcs" -gt 0 ]; then
        _check_pass "All PVCs bound ($bound_pvcs)"
      fi
    fi
  fi
  echo ""

  # =========================================================================
  # DNS
  # =========================================================================
  echo "DNS:"
  local coredns_running
  coredns_running=$(kubectl get pods -n openshift-dns --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  if [ "$coredns_running" -gt 0 ]; then
    _check_pass "CoreDNS running ($coredns_running pods)"
  else
    _check_warn "CoreDNS pods not found in openshift-dns"
  fi
  echo ""

  # =========================================================================
  # Summary
  # =========================================================================
  echo "─────────────────────────────────────"
  if [ "$issues" -eq 0 ] && [ "$warnings" -eq 0 ]; then
    printf "\033[32m✓ All checks passed — environment is healthy\033[0m\n"
  elif [ "$issues" -eq 0 ]; then
    printf "\033[33m⚠ %d warning(s), no critical issues\033[0m\n" "$warnings"
  else
    printf "\033[31m✗ %d issue(s), %d warning(s)\033[0m\n" "$issues" "$warnings"
    echo ""
    echo "For detailed diagnostics: aap-demo must-gather"
    echo "For AI-assisted analysis:  aap-demo diagnose --ai"
  fi

  # AI analysis mode
  if [ "${_DIAGNOSE_AI:-false}" = "true" ]; then
    echo ""

    if ! command -v claude &>/dev/null; then
      echo "✗ 'claude' CLI not found"
      echo "  Install: https://docs.anthropic.com/en/docs/claude-code"
      return 1
    fi

    echo "─────────────────────────────────────"
    printf "\033[1mAI Analysis\033[0m (powered by Claude)\n"
    echo ""

    echo "(Diagnostic data is sent to the Claude API for analysis)"
    echo ""

    # Collect additional context for AI — cache pod list to avoid duplicate kubectl calls
    local pod_output
    pod_output=$(kubectl get pods -n "$NAMESPACE" -o wide --no-headers 2>/dev/null || echo "No pods")
    local problem_pod_names
    problem_pod_names=$(echo "$pod_output" | grep -E "CrashLoopBackOff|Error|ImagePullBackOff|Pending" | awk '{print $1}' || true)
    local problem_pod_logs=""
    if [ -n "$problem_pod_names" ]; then
      while IFS= read -r pod; do
        problem_pod_logs="${problem_pod_logs}--- ${pod} ---
$(kubectl logs "$pod" -n "$NAMESPACE" --tail=20 2>/dev/null || true)
"
      done <<<"$problem_pod_names"
    fi

    local ai_context
    ai_context="AAP Demo Diagnose Results:
Issues: $issues, Warnings: $warnings
Infra: OpenShift Local (CRC)
Namespace: $NAMESPACE

Cluster State:
$pod_output

PVC State:
$(kubectl get pvc -n "$NAMESPACE" 2>/dev/null || echo "No PVCs")

Storage Classes:
$(kubectl get sc 2>/dev/null || echo "No storage classes")

AAP CR Status:
$(kubectl get aap -n "$NAMESPACE" -o yaml 2>/dev/null | grep -A20 "status:" || echo "No AAP CR")

Recent Events:
$(kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || echo "No events")

Problem Pods:
$(echo "$pod_output" | grep -E "CrashLoopBackOff|Error|ImagePullBackOff|Pending" || echo "None")

Problem Pod Logs:
${problem_pod_logs:-None}"

    echo "$ai_context" | claude -p \
      "You are an AAP Demo troubleshooting assistant. Analyze the diagnostic output below and:
1. Identify the root cause of any issues
2. Provide specific fix commands the user can run
3. If the issue appears to be a bug in aap-demo itself, suggest filing a GitHub issue at https://github.com/ansible-automation-platform/aap-demo/issues

Be concise and actionable. Focus on what the user needs to do next.

Diagnostic data:" 2>&1 || {
      echo ""
      echo "⚠ AI analysis failed. The diagnostic data above should help with manual troubleshooting."
    }
  fi
}

cmd_test() {
  setup_kubeconfig

  local markers="interop"
  local run_all=false

  # Parse arguments: --all or markers
  for arg in "$@"; do
    case "$arg" in
      --all) run_all=true ;;
      *) markers="$arg" ;;
    esac
  done

  local artifacts_dir="${SCRIPT_DIR}/artifacts/atf"
  local test_namespace="$NAMESPACE"

  echo ""
  printf "\033[1maap-demo test\033[0m\n"
  echo ""

  # Find all namespaces with AAP deployments
  local aap_namespaces=()
  # Operator deploys: namespaces with AAP CRDs
  local ns_list
  ns_list=$(kubectl get aap --all-namespaces --no-headers 2>/dev/null | awk '{print $1}' || true)
  # Sort alphabetically by namespace name

  if [ ${#aap_namespaces[@]} -eq 0 ]; then
    _err "No AAP deployments found on cluster"
    echo "  Deploy AAP first: aap-demo deploy"
    return 1
  fi

  # If NAMESPACE was explicitly set via flag or env, use it directly
  # Otherwise, if multiple deployments, prompt
  if [ "$_NAMESPACE_EXPLICIT" = "true" ]; then
    # Explicit namespace override
    test_namespace="$NAMESPACE"
  elif [ ${#aap_namespaces[@]} -eq 1 ]; then
    # Single match — use it directly
    test_namespace=$(echo "${aap_namespaces[0]}" | awk '{print $1}')
  elif [ -t 0 ]; then
    echo "  Multiple AAP deployments found:"
    echo ""
    local i=1
    for entry in "${aap_namespaces[@]}"; do
      printf "    %d) %s\n" "$i" "$entry"
      i=$((i + 1))
    done
    echo ""
    # Print padding lines then move cursor back up so prompt isn't at terminal bottom
    local _term_lines
    _term_lines=$(tput lines 2>/dev/null || echo "24")
    [ "$_term_lines" -gt 8 ] && printf '\n\n\n\n\033[4A'
    printf "  Select deployment [1]: "
    read -r choice </dev/tty
    echo ""
    choice="${choice:-1}"
    if [ "$choice" -ge 1 ] && [ "$choice" -le ${#aap_namespaces[@]} ] 2>/dev/null; then
      test_namespace=$(echo "${aap_namespaces[$((choice - 1))]}" | awk '{print $1}')
    fi
  else
    # Non-interactive, multiple matches — use first
    test_namespace=$(echo "${aap_namespaces[0]}" | awk '{print $1}')
  fi

  # Check for ansible-playbook
  if ! command -v ansible-playbook &>/dev/null; then
    _err "ansible-playbook not found"
    echo "  Install: pip install ansible-core"
    return 1
  fi

  # Install ATF collections if not present
  if ! ansible-galaxy collection list 2>/dev/null | grep -q "aapqa.atf"; then
    echo "Installing ATF collections..."
    ansible-galaxy collection install \
      git+https://gitlab.cee.redhat.com/aap-ci/aapqa-provisioner.git#/ansible_collections/aapqa/atf,devel \
      git+https://gitlab.cee.redhat.com/aap-ci/aapqa-provisioner.git#/ansible_collections/aapqa/core,devel \
      2>&1 || {
      _err "Failed to install ATF collections"
      echo "  These require access to gitlab.cee.redhat.com (VPN may be needed)"
      return 1
    }
    echo "  ✓ ATF collections installed"
  else
    echo "  ✓ ATF collections already installed"
  fi

  # Run --all: iterate every deployment
  if [ "$run_all" = "true" ]; then
    echo "  Running ATF against all ${#aap_namespaces[@]} deployment(s)..."
    echo ""
    local overall_rc=0
    for entry in "${aap_namespaces[@]}"; do
      local ns
      ns=$(echo "$entry" | awk '{print $1}')
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      printf "\033[1mTesting: %s\033[0m\n" "$entry"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      _run_atf "$ns" "$markers" "$artifacts_dir" || overall_rc=1
      echo ""
    done
    if [ "$overall_rc" -eq 0 ]; then
      echo "✓ ATF tests passed on all deployments"
    else
      _err "ATF tests failed on one or more deployments"
    fi
    return $overall_rc
  fi

  # Single deployment target (|| captures exit code so set -e doesn't suppress clean error output)
  local _test_rc=0
  _run_atf "$test_namespace" "$markers" "$artifacts_dir" || _test_rc=$?
  return $_test_rc
}

_run_atf() {
  local test_namespace="$1"
  local markers="$2"
  local artifacts_dir="$3/${test_namespace}"

  # Get AAP instance name
  local aap_name
  aap_name=$(kubectl get aap -n "$test_namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -z "$aap_name" ]; then
    aap_name="aap"
  fi

  # Auto-detect gateway hostname from route
  local gateway_host
  gateway_host=$(kubectl get route "${aap_name}" -n "$test_namespace" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [ -z "$gateway_host" ]; then
    gateway_host=$(kubectl get route -n "$test_namespace" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  fi
  if [ -z "$gateway_host" ]; then
    _err "Could not detect gateway route in namespace $test_namespace"
    return 1
  fi

  # Auto-detect admin password from secret
  local admin_password
  admin_password=$(kubectl get secret "${aap_name}-admin-password" -n "$test_namespace" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  # Fallback: search for any *-admin-password secret in the namespace
  if [ -z "$admin_password" ]; then
    local _pw_secret
    _pw_secret=$(kubectl get secrets -n "$test_namespace" -o name 2>/dev/null | grep "admin-password" | head -1)
    if [ -n "$_pw_secret" ]; then
      admin_password=$(kubectl get "$_pw_secret" -n "$test_namespace" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    fi
  fi
  if [ -z "$admin_password" ]; then
    _err "Could not retrieve admin password in namespace $test_namespace"
    return 1
  fi

  # Auto-detect AAP version (ATF needs a valid PEP 440 version, not 'devel')
  local aap_version=""
  # Try CSV version first (e.g., aap-operator.v2.6.0-0.1772556720)
  aap_version=$(kubectl get csv -n "$test_namespace" -o jsonpath='{.items[0].spec.version}' 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+' || true)
  if [ -z "$aap_version" ]; then
    # Fallback: gateway API ping (may report base version, not dev version)
    local _curl_tls="--cacert /tmp/crc-ingress-ca.crt"
    [ ! -f /tmp/crc-ingress-ca.crt ] && _curl_tls="-k"
    aap_version=$(curl -s $_curl_tls "https://${gateway_host}/api/gateway/v1/ping/" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+' || true)
  fi
  aap_version="${aap_version:-2.7}"

  echo "  Namespace: ${test_namespace}"
  echo "  Gateway:   https://${gateway_host}"
  echo "  Version:   ${aap_version}"
  echo "  Markers:   ${markers}"
  echo "  Artifacts: ${artifacts_dir}"
  echo ""

  # Create artifacts directory (per-namespace)
  mkdir -p "${artifacts_dir}"

  # Fetch test suite definition (always re-fetch to get latest from devel branch)
  curl -fsSL -o "${artifacts_dir}/aap_test_suite.yml" \
    "https://gitlab.cee.redhat.com/aap-ci/aapqa-provisioner/-/raw/devel/input/atf/test_suites/aap_test_suite.yml" 2>/dev/null || {
    _err "Failed to fetch test suite definition (VPN may be needed)"
    return 1
  }

  # Generate ATF installer inventory (restricted permissions — contains admin password)
  (
    umask 077
    cat >"${artifacts_dir}/atf_installer_inventory" <<INVEOF
[automationcontroller]

[automationhub]

[automationedacontroller]

[automationgateway]
${gateway_host}

[all:vars]
gateway_base_url=https://${gateway_host}
automationgateway_admin_password=${admin_password}
INVEOF
  )

  # Run ATF
  echo "Running ATF tests..."
  echo ""
  local extra_args=()
  if [ -f "$HOME/.aap-demo/atf-vault-password" ]; then
    extra_args+=("--vault-password-file=$HOME/.aap-demo/atf-vault-password")
  fi
  # Override ansible_distribution on macOS — ATF only has vars for RHEL
  # System packages are skipped anyway (atf_install_system_packages=false)
  if [ "$(uname)" = "Darwin" ]; then
    extra_args+=("-e" "ansible_distribution=RedHat" "-e" "ansible_distribution_major_version=9")
  fi
  ansible-playbook "${SCRIPT_DIR}/test/test-aap.yaml" \
    -i "${artifacts_dir}/atf_installer_inventory" \
    "${extra_args[@]}" \
    -e "inventory_dir=${artifacts_dir}" \
    -e "aap_name=${aap_name}" \
    -e "aap_namespace=${test_namespace}" \
    -e "aap_hostname=${gateway_host}" \
    -e "aap_version=${aap_version}" \
    -e "atf_artifacts_dir=${artifacts_dir}" \
    -e "atf_tsd_host_file=${artifacts_dir}/tsd.json" \
    -e "atf_tsd_file=${artifacts_dir}/tsd.json" \
    -e "atf_test_markers=${markers}" \
    -e "atf_install_collections=false" \
    -e "atf_install_system_packages=false" \
    -e "atf_install_external_dependencies=false" \
    -e "atf_create_ssh_keys=false" \
    -e "atf_setup=true" \
    -e "aap_topology=ocp-a" \
    -e "aap_install_method=operator-ocp" \
    -e "atf_git_clone_protocol=https" \
    -e "@${artifacts_dir}/aap_test_suite.yml"

  local rc=$?
  echo ""
  if [ "$rc" -eq 0 ]; then
    echo "✓ ATF tests passed: ${test_namespace} (markers: ${markers})"
  else
    _err "ATF tests failed: ${test_namespace} (exit code: ${rc})"
    echo "  Artifacts: ${artifacts_dir}"
  fi
  return $rc
}

cmd_ssh() {
  CRC_SSH_KEY="${HOME}/.crc/machines/crc/id_ed25519"
  exec ssh -p 2222 -i "$CRC_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@127.0.0.1
}

cmd_kubeconfig() {
  echo ""
  printf "\033[1maap-demo kubeconfig\033[0m - Syncing local aap-demo kubeconfig...\n"
  echo ""

  # Temp file tracking for cleanup
  TEMP_FILES=()
  cleanup_temp_files() {
    for f in "${TEMP_FILES[@]}"; do
      rm -f "$f" 2>/dev/null
    done
  }
  trap cleanup_temp_files EXIT

  # Skip ~/.kube in CI (permission issues)
  SKIP_KUBE_DIR=false
  if [ "${CI:-false}" = "true" ] || [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
    SKIP_KUBE_DIR=true
  fi

  # Check cluster is reachable
  local cluster_name
  cluster_name=$(infra_get_name 2>/dev/null || echo "")
  if [ -z "$cluster_name" ]; then
    echo "  ERROR: Cluster not running"
    echo "         Run 'aap-demo create' first"
    exit 1
  fi

  # Extract kubeconfig with validation
  echo "  Extracting kubeconfig from ${cluster_name}..."
  mkdir -p "$HOME/.aap-demo"
  TEMP_KUBECONFIG=$(mktemp)
  TEMP_FILES+=("$TEMP_KUBECONFIG")
  chmod 600 "$TEMP_KUBECONFIG"

  if ! infra_get_kubeconfig "$TEMP_KUBECONFIG" 2>/dev/null; then
    echo "  ERROR: Failed to extract kubeconfig"
    echo "         OpenShift Local may still be initializing. Wait and retry."
    exit 1
  fi

  # Validate extracted kubeconfig
  if ! KUBECONFIG="$TEMP_KUBECONFIG" kubectl config view >/dev/null 2>&1; then
    echo "  ERROR: Extracted kubeconfig is invalid"
    echo "         OpenShift Local may still be initializing. Wait and retry."
    exit 1
  fi

  # Rename context/cluster/user to unique names before saving
  # OpenShift Local defaults to generic names (microshift, user) that collide
  local ctx_name="aap-demo"
  KUBECONFIG="$TEMP_KUBECONFIG" kubectl config rename-context microshift "$ctx_name" >/dev/null 2>&1 || true
  KUBECONFIG="$TEMP_KUBECONFIG" kubectl config set-context "$ctx_name" --cluster="$ctx_name" --user="$ctx_name" >/dev/null 2>&1 || true
  # Rename cluster entry
  local server
  server=$(KUBECONFIG="$TEMP_KUBECONFIG" kubectl config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
  KUBECONFIG="$TEMP_KUBECONFIG" kubectl config set-cluster "$ctx_name" --server="$server" --insecure-skip-tls-verify=true >/dev/null 2>&1
  KUBECONFIG="$TEMP_KUBECONFIG" kubectl config unset clusters.microshift >/dev/null 2>&1 || true
  # Copy user credentials to new name
  local client_cert client_key
  client_cert=$(KUBECONFIG="$TEMP_KUBECONFIG" kubectl config view --raw -o jsonpath='{.users[?(@.name=="user")].user.client-certificate-data}' 2>/dev/null)
  client_key=$(KUBECONFIG="$TEMP_KUBECONFIG" kubectl config view --raw -o jsonpath='{.users[?(@.name=="user")].user.client-key-data}' 2>/dev/null)
  if [ -n "$client_cert" ]; then
    KUBECONFIG="$TEMP_KUBECONFIG" kubectl config set-credentials "$ctx_name" \
      --client-certificate=<(echo "$client_cert" | base64 -d) \
      --client-key=<(echo "$client_key" | base64 -d) \
      --embed-certs=true >/dev/null 2>&1
    KUBECONFIG="$TEMP_KUBECONFIG" kubectl config unset users.user >/dev/null 2>&1 || true
  fi
  KUBECONFIG="$TEMP_KUBECONFIG" kubectl config use-context "$ctx_name" >/dev/null 2>&1

  mv "$TEMP_KUBECONFIG" "$HOME/.crc/machines/crc/kubeconfig"
  TEMP_FILES=() # Clear since file was moved successfully
  chmod 600 "$HOME/.crc/machines/crc/kubeconfig"
  echo "  ✓ Saved to ~/.crc/machines/crc/kubeconfig"

  # Merge into ~/.kube/config (unless in CI)
  if [ "$SKIP_KUBE_DIR" = "false" ]; then
    mkdir -p "$HOME/.kube"
    chmod 700 "$HOME/.kube"

    if [ -f "$HOME/.kube/config" ]; then
      # Remove old aap-demo entries first (prevents stale certs after repair)
      echo "  Removing old aap-demo entries..."
      KUBECONFIG="$HOME/.kube/config" kubectl config delete-context "$ctx_name" 2>/dev/null || true
      KUBECONFIG="$HOME/.kube/config" kubectl config delete-cluster "$ctx_name" 2>/dev/null || true
      KUBECONFIG="$HOME/.kube/config" kubectl config delete-user "$ctx_name" 2>/dev/null || true
      # Also clean legacy names
      KUBECONFIG="$HOME/.kube/config" kubectl config delete-context microshift 2>/dev/null || true
      KUBECONFIG="$HOME/.kube/config" kubectl config delete-cluster microshift 2>/dev/null || true

      # Merge into existing config
      echo "  Merging into existing ~/.kube/config..."
      TEMP_MERGED=$(mktemp)
      TEMP_FILES+=("$TEMP_MERGED")
      chmod 600 "$TEMP_MERGED"

      if ! KUBECONFIG="$HOME/.kube/config:$HOME/.crc/machines/crc/kubeconfig" kubectl config view --flatten >"$TEMP_MERGED" 2>/dev/null; then
        echo "  ERROR: Failed to merge kubeconfigs"
        exit 1
      fi

      if ! KUBECONFIG="$TEMP_MERGED" kubectl config view >/dev/null 2>&1; then
        echo "  ERROR: Merged kubeconfig is invalid"
        exit 1
      fi

      mv "$TEMP_MERGED" "$HOME/.kube/config"
      TEMP_FILES=()
      chmod 600 "$HOME/.kube/config"
      echo "  ✓ Merged context into ~/.kube/config"
    else
      cp "$HOME/.crc/machines/crc/kubeconfig" "$HOME/.kube/config"
      chmod 600 "$HOME/.kube/config"
      echo "  ✓ Created ~/.kube/config"
    fi

    # Set aap-demo as current context
    if KUBECONFIG="$HOME/.kube/config" kubectl config use-context "$ctx_name" >/dev/null 2>&1; then
      echo "  ✓ Current context set to $ctx_name"
    else
      echo "  WARNING: Could not set context to $ctx_name"
    fi
  fi

  trap - EXIT
  echo ""
  echo "  kubectl now connects to OpenShift Local cluster."
  echo "  Context: $ctx_name"
}

cmd_status() {
  echo ""
  printf "\033[1mAAP Demo Status\033[0m\n"
  echo "==============="
  echo ""

  # Check cluster status via infra abstraction
  local cluster_state
  cluster_state=$(infra_get_state 2>/dev/null || echo "not_created")
  local cluster_name
  cluster_name=$(infra_get_name 2>/dev/null || echo "")

  printf "Infra:       OpenShift Local (CRC)\n"

  if [ "$cluster_state" = "running" ]; then
    printf "Cluster:     \033[1;32mrunning\033[0m"
    [ -n "$cluster_name" ] && printf " (%s)" "$cluster_name"
    echo ""
  elif [ "$cluster_state" = "stopped" ]; then
    printf "Cluster:     \033[1;33mstopped\033[0m\n"
    echo ""
    echo "Start with: crc start"
    return 0
  else
    printf "Cluster:     \033[1;31mnot running\033[0m\n"
    echo ""
    echo "Start with: aap-demo create"
    return 0
  fi

  # Show kubeconfig
  echo "Kubeconfig:  $KUBECONFIG"
  local _script_dir _script_branch _script_remote
  _script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
  _script_branch=$(cd "$_script_dir" && git branch --show-current 2>/dev/null || echo "unknown")
  _script_remote=$(cd "$_script_dir" && git remote get-url origin 2>/dev/null || echo "")
  echo "Source:      $_script_dir (branch: $_script_branch)"
  [ -n "$_script_remote" ] && echo "Repo:        $_script_remote"

  # VM stats
  echo ""
  echo "VM:"
  echo "---"
  local vm_info
  vm_info=$(infra_exec_cmd bash -c '
        # RHEL version
        RHEL=$(cat /etc/redhat-release 2>/dev/null || echo "unknown")
        # OpenShift version
        USHIFT=$(microshift version 2>/dev/null | awk "/MicroShift Version:/{print \$3}" || rpm -q microshift --qf "%{VERSION}" 2>/dev/null || echo "unknown")
        # CPU
        CPUS=$(nproc)
        # Memory
        MEM_TOTAL=$(free -h | awk "/Mem:/{print \$2}")
        MEM_USED=$(free -h | awk "/Mem:/{print \$3}")
        MEM_AVAIL=$(free -h | awk "/Mem:/{print \$7}")
        # Load
        LOAD=$(cat /proc/loadavg | awk "{print \$1, \$2, \$3}")
        # Disk
        DISK=$(df -h /var 2>/dev/null | awk "NR==2{print \$3\"/\"\$2\" (\" \$5 \" used)\"}")
        echo "  OS:           $RHEL"
        echo "  OpenShift:    $USHIFT"
        echo "  CPUs:         $CPUS"
        echo "  Memory:       ${MEM_USED} / ${MEM_TOTAL} (${MEM_AVAIL} available)"
        echo "  Load:         $LOAD"
        echo "  Disk:         $DISK"
    ' 2>/dev/null)
  echo "$vm_info"
  echo ""

  # List all namespaces with pod counts (exclude system namespaces)
  echo "Namespaces:"
  echo "-----------"
  NAMESPACES=$(kubectl get ns --no-headers -o custom-columns=':metadata.name' 2>/dev/null | sort)

  if [ -z "$NAMESPACES" ]; then
    echo "  (no application namespaces found)"
  else
    for ns in $NAMESPACES; do
      POD_TOTAL=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -cv Completed 2>/dev/null | tr -d "
" || echo 0)
      POD_RUNNING=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null || true)
      [ -z "$POD_RUNNING" ] && POD_RUNNING=0
      # Skip empty namespaces
      if [ "$POD_TOTAL" -eq 0 ] 2>/dev/null; then continue; fi
      AAP_CR=$(kubectl get aap -n "$ns" --no-headers 2>/dev/null | awk '{print $1}' | head -1 || true)

      if [ -n "$AAP_CR" ]; then
        AAP_STATUS=$(kubectl get aap "$AAP_CR" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || echo "")
        local _aap_url
        _aap_url=$(kubectl get route "$AAP_CR" -n "$ns" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
        if [ "$AAP_STATUS" = "True" ]; then
          printf "  %-30s %s/%s pods   \033[1;32m%s\033[0m" "$ns" "$POD_RUNNING" "$POD_TOTAL" "$AAP_CR"
        else
          AAP_RUNNING=$(kubectl get aap "$AAP_CR" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Running")].status}' 2>/dev/null || echo "")
          if [ "$AAP_RUNNING" = "True" ]; then
            printf "  %-30s %s/%s pods   \033[1;33m%s (Deploying)\033[0m" "$ns" "$POD_RUNNING" "$POD_TOTAL" "$AAP_CR"
          else
            printf "  %-30s %s/%s pods   %s" "$ns" "$POD_RUNNING" "$POD_TOTAL" "$AAP_CR"
          fi
        fi
        [ -n "$_aap_url" ] && printf "  %s" "$_aap_url"
        echo ""
      else
        printf "  %-30s %s/%s pods\n" "$ns" "$POD_RUNNING" "$POD_TOTAL"
      fi
    done
  fi
  echo ""

  # Show AAP deployment routes (exclude addon and system namespaces)
  echo "AAP Deployments:"
  echo "----------------"
  ROUTES=$(kubectl get route -A --no-headers 2>/dev/null \
    | grep -v -E '^(openshift-|kube-|aap-demo-)' \
    | awk '{printf "  https://%s\n", $3}')
  if [ -n "$ROUTES" ]; then
    echo "$ROUTES"
  else
    echo "  (no AAP routes found)"
  fi
  echo ""

  # Show credentials for AAP namespaces
  local _cred_namespaces _cred_found
  _cred_namespaces=$(kubectl get aap -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u)
  _cred_found=false
  if [ -n "$_cred_namespaces" ]; then
    for ns in $_cred_namespaces; do
      local ADMIN_PASSWORD=""
      local ADMIN_SECRET
      ADMIN_SECRET=$(kubectl get aap -n "$ns" -o jsonpath='{.items[0].status.adminPasswordSecret}' 2>/dev/null || true)
      if [ -n "$ADMIN_SECRET" ]; then
        ADMIN_PASSWORD=$(kubectl get secret -n "$ns" "$ADMIN_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
      fi
      if [ -z "$ADMIN_PASSWORD" ]; then
        for secret_name in myaap-admin-password aap-admin-password aap-controller-admin-password custom-admin-password; do
          ADMIN_PASSWORD=$(kubectl get secret -n "$ns" "$secret_name" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
          [ -n "$ADMIN_PASSWORD" ] && break
        done
      fi

      if [ -n "$ADMIN_PASSWORD" ]; then
        if [ "$_cred_found" = "false" ]; then
          echo "Credentials:"
          echo "------------"
          _cred_found=true
        fi
        printf "  %-20s admin / %s\n" "$ns:" "$ADMIN_PASSWORD"
      fi
    done
    [ "$_cred_found" = "true" ] && echo ""
  fi

  # Show enabled addons with URLs
  local saved_addons
  saved_addons=$(_addons_list)
  if [ -n "$saved_addons" ]; then
    echo "Enabled Addons:"
    echo "---------------"
    for a in $saved_addons; do
      local url=""
      case "$a" in
        console) url="https://console.apps.127.0.0.1.nip.io" ;;
        registry) url="https://registry.apps.127.0.0.1.nip.io" ;;
        mcp-server) url="https://aap-mcp-${NAMESPACE:-aap-operator}.apps.127.0.0.1.nip.io/mcp" ;;
        portal) url="https://aap-${NAMESPACE:-aap-operator}.apps.127.0.0.1.nip.io (integrated portal)" ;;
        registry-ui) url="https://registry-ui.apps.127.0.0.1.nip.io" ;;
        prometheus) url="https://prometheus.apps.127.0.0.1.nip.io" ;;
      esac
      if [ -n "$url" ]; then
        printf "  %-15s %s\n" "$a" "$url"
      else
        printf "  %s\n" "$a"
      fi
    done
    echo ""
  fi
}

cmd_redeploy() {
  # Ensure cluster is accessible (auto-create if needed)
  _verify_cluster || exit 1

  _clean_operator

  # Small pause
  sleep 2

  # Deploy fresh
  echo ""
  echo "Redeploying AAP..."
  echo ""

  deploy_latest
}

cmd_redeploy-all() {
  # Destroy existing cluster (warning shown by cmd_destroy)
  cmd_destroy

  # Small pause
  sleep 2

  # Run full deploy flow (creates cluster, setup, deploy)
  cmd_deploy
}

cmd_destroy() {
  echo ""
  printf "\033[1maap-demo destroy\033[0m - Deleting CRC cluster...\n"
  echo ""
  echo "✗  WARNING: This will DELETE the entire CRC cluster!"
  echo ""
  echo "  • All cluster data will be PERMANENTLY DESTROYED"
  echo "  • All PVC storage will be LOST"
  echo "  • All deployed applications will be removed"
  echo "  • You will need to redeploy AAP from scratch"
  echo ""
  if [ "${QUIET:-false}" != "true" ]; then
    echo "Press Ctrl+C to cancel, or press Enter to continue..."
    echo "Auto-continuing in 10 seconds..."
    read -t 10 -r || true
    echo ""
  fi
  if crc delete -f 2>/dev/null || crc delete 2>/dev/null; then
    podman system connection remove aap-demo 2>/dev/null || true
    echo "✓ CRC cluster deleted"
    if [ "${_DESTROY_RESET:-false}" = "true" ]; then
      rm -f "$AAP_DEMO_CONFIG"
      echo "✓ Config reset — next 'aap-demo create' will re-prompt for preset"
    fi
  else
    echo "✗ CRC delete failed — config preserved"
  fi
}

cmd_stop() {
  echo ""
  printf "\033[1maap-demo stop\033[0m - Stopping CRC cluster...\n"
  crc stop || true
  echo "✓ CRC cluster stopped"
  echo "To restart: aap-demo start"
}

cmd_start() {
  echo ""
  printf "\033[1maap-demo start\033[0m - Starting CRC cluster...\n"
  _start_crc_cluster
  setup_kubeconfig

  # Re-apply CoreDNS config (fixes DNS after restarts)
  if [ -f "${SCRIPT_DIR}/includes/crc-create.sh" ]; then
    bash -c "
      AAP_DEMO_CONFIGURE_COREDNS_ONLY=1
      source '${SCRIPT_DIR}/includes/crc-create.sh'
      configure_coredns
    " || true
  fi

  echo "✓ CRC cluster started"
  echo ""
  echo "Run 'aap-demo status' to check cluster health"
}

_start_crc_cluster() {
  crc start || true
  if [ -f /etc/resolver/testing ]; then
    sudo rm -f /etc/resolver/testing
  fi
}

cmd_create() {
  # Show notice (skip if already shown or quiet mode)
  if [ "$QUIET" != "true" ] && [ "${AAP_DEMO_NOTICE_SHOWN:-}" != "1" ]; then
    bash "${SCRIPT_DIR}/includes/aap-demo-notice.sh" || true
    AAP_DEMO_NOTICE_SHOWN=1
  fi

  if ! bash "${SCRIPT_DIR}/includes/crc-create.sh"; then
    _err "OpenShift Local cluster creation failed"
    exit 1
  fi

  # Install OLM by default (OpenShift Local doesn't include it, needed for operator dev and latest deploys)
  setup_kubeconfig
  bash "${SCRIPT_DIR}/addons/olm/deploy.sh" || {
    echo ""
    printf "  \033[1;33mWARNING: OLM install failed — you can retry with: aap-demo enable olm\033[0m\n"
  }
}

cmd_setup() {
  echo "CRC setup is handled during 'aap-demo create'"
}

cmd_deploy() {
  # Show notice/disclaimer
  if [ "$QUIET" != "true" ] && [ "${AAP_DEMO_NOTICE_SHOWN:-}" != "1" ]; then
    bash "${SCRIPT_DIR}/includes/aap-demo-notice.sh" || true
    AAP_DEMO_NOTICE_SHOWN=1
  fi

  # Ensure OpenShift Local is running
  local crc_state
  crc_state=$(infra_get_state 2>/dev/null || echo "not_created")
  if [ "$crc_state" = "not_created" ]; then
    echo "No cluster found. Creating one first..."
    cmd_create
  elif [ "$crc_state" = "stopped" ]; then
    echo "Cluster is stopped. Starting..."
    _start_crc_cluster
  fi

  # Install OLM if not present (OpenShift Local doesn't include it)
  KUBECONFIG="${KUBECONFIG:-$HOME/.crc/machines/crc/kubeconfig}" bash "${SCRIPT_DIR}/addons/olm/deploy.sh"

  # anyuid and privileged SCCs granted in setup_namespace() for all SAs in the namespace
  echo ""
  printf "\033[1maap-demo deploy\033[0m - Deploying AAP to OpenShift Local...\n"
  echo ""
  echo "Infrastructure: OpenShift Local"
  if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to cluster"
    echo "  Current context: $(kubectl config current-context 2>/dev/null || echo 'none')"
    echo "  Check your KUBECONFIG or use --context flag"
    exit 1
  fi
  echo "Connected to: $(kubectl config current-context 2>/dev/null)"
  echo ""

  # Check if AAP already exists
  if [ "$FORCE" != "true" ]; then
    AAP_EXISTS=$(kubectl get aap -n "$NAMESPACE" 2>/dev/null | grep -v NAME | head -1 | awk '{print $1}' || true)
    if [ -n "$AAP_EXISTS" ]; then
      echo ""
      echo "✓ AAP instance '$AAP_EXISTS' already exists in namespace $NAMESPACE"
      echo "  Skipping installation, validating existing deployment..."
      echo "  (Use FORCE=true to reinstall)"
      echo ""
      watch_aap
      exit 0
    fi
  fi

  # Refresh kubeconfig before deploy (certs may have changed during OLM install)
  _verify_cluster || exit 1

  # Deploy AAP 2.7
  deploy_latest
}

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

patch_operator_serviceaccounts() {
  if [ -n "$PULL_SECRET" ]; then
    echo ""
    echo "Patching operator ServiceAccounts with pull secret..."
    sleep 5
    for sa in $(kubectl get serviceaccount -n "$NAMESPACE" -o name 2>/dev/null | grep -E 'operator|controller' | sed 's|serviceaccount/||'); do
      kubectl patch serviceaccount "$sa" -n "$NAMESPACE" \
        -p '{"imagePullSecrets": [{"name": "redhat-operators-pull-secret"}]}' 2>/dev/null || true
    done
    echo "  ✓ Operator ServiceAccounts patched"
  fi
}

deploy_latest() {
  # Check disk space before deploying (latest catalog images are large)
  _check_disk_space || exit 1

  # Ensure OLM is installed (OpenShift Local doesn't include it)
  KUBECONFIG="${KUBECONFIG:-$HOME/.crc/machines/crc/kubeconfig}" bash "${SCRIPT_DIR}/addons/olm/deploy.sh"

  echo ""
  echo "Deploying AAP from latest catalog..."
  echo "  Version: 2.7"
  echo "  Namespace: $NAMESPACE"
  echo ""

  AAP_CHANNEL="stable-2.7"
  AAP_OCP_VERSION="${AAP_OCP_VERSION:-4.20}"

  # Validate OCP version format
  if ! [[ "$AAP_OCP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid AAP_OCP_VERSION: '$AAP_OCP_VERSION' (expected format: X.Y, e.g. 4.20)"
    exit 1
  fi

  # Setup namespace (creates aap-operator namespace + pull secret)
  setup_namespace
  verify_coredns

  # Create CatalogSource in aap-operator namespace
  # (not openshift-marketplace — upstream OLM doesn't create pods there on OpenShift Local)
  echo ""
  echo "Creating CatalogSource (OCP $AAP_OCP_VERSION)..."
  sed -e "s|redhat-operator-index:v[0-9.]*|redhat-operator-index:v${AAP_OCP_VERSION}|" \
    -e "s|namespace: aap-operator|namespace: $NAMESPACE|" \
    "${SCRIPT_DIR}/config/olm/catalogsource.yaml" | kubectl apply -f -

  # Wait for CatalogSource
  echo ""
  echo "Waiting for CatalogSource to be ready..."
  echo "  (This may take a few minutes while the catalog image is pulled)"
  CATSRC_READY=false
  for i in $(seq 1 60); do
    STATUS=$(kubectl get catalogsource redhat-operators -n "$NAMESPACE" \
      -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "Pending")
    if [ "$STATUS" = "READY" ]; then
      echo ""
      echo "  ✓ CatalogSource is ready"
      CATSRC_READY=true
      break
    fi
    POD_STATUS=$(kubectl get pods -n "$NAMESPACE" -l olm.catalogSource=redhat-operators \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    if [ "$STATUS" = "TRANSIENT_FAILURE" ]; then
      if [ "$POD_STATUS" = "Pending" ] || [ "$POD_STATUS" = "ContainerCreating" ]; then
        printf "\r  Pulling catalog image... ($i/60)    "
      else
        printf "\r  Catalog initializing... ($i/60)    "
      fi
    elif [ "$STATUS" = "CONNECTING" ]; then
      printf "\r  Connecting to catalog... ($i/60)    "
    else
      printf "\r  Waiting ($STATUS)... ($i/60)    "
    fi
    sleep 5
  done
  if [ "$CATSRC_READY" != "true" ]; then
    echo ""
    echo "  ⚠ CatalogSource not ready after 5 minutes, continuing anyway..."
  fi

  # Create OperatorGroup
  echo ""
  echo "Creating OperatorGroup..."
  sed -e "s|namespace: aap|namespace: $NAMESPACE|g" \
    -e "s|name: aap-og|name: ${NAMESPACE}-og|" \
    -e "s|- aap|- $NAMESPACE|" \
    "${SCRIPT_DIR}/config/olm/operatorgroup.yaml" | kubectl apply -f -

  # Create Subscription
  echo ""
  echo "Creating Subscription..."
  sed -e "s|namespace: aap|namespace: $NAMESPACE|" \
    -e "s|channel: stable-2.6|channel: $AAP_CHANNEL|" \
    "${SCRIPT_DIR}/config/olm/subscription.yaml" | kubectl apply -f -

  # Wait for CSV
  echo ""
  echo "Waiting for CSV to be created..."
  CSV_NAME=""
  for i in $(seq 1 60); do
    CSV_NAME=$(kubectl get csv -n "$NAMESPACE" 2>/dev/null | grep '^aap-operator\.' | awk '{print $1}' | head -1)
    if [ -n "$CSV_NAME" ]; then
      echo "Found CSV: $CSV_NAME"
      break
    fi
    echo "  Waiting for CSV... ($i/60)"
    sleep 10
  done

  if [ -z "$CSV_NAME" ]; then
    echo "✗ CSV not found after 10 minutes"
    echo "Check: kubectl get subscription -n $NAMESPACE"
    exit 1
  fi

  # Wait for CSV to succeed
  echo ""
  echo "Waiting for CSV to reach Succeeded phase..."
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded csv/"$CSV_NAME" -n "$NAMESPACE" --timeout=600s || true

  # Create AAP instance (unless CREATE_AAP=false for deploy-operator)
  if [ "${CREATE_AAP:-true}" != "false" ]; then
    create_aap_instance

    # Watch deployment
    watch_aap
  else
    echo ""
    echo "✓ AAP operator deployed!"
    echo ""
    echo "Install Method: AAP 2.7 (CatalogSource)"
    echo "CSV: $CSV_NAME"
    echo "Namespace: $NAMESPACE"
    echo ""
    echo "To deploy AAP instance: aap-demo deploy-aap"
  fi
}

verify_coredns() {
  # Verify CoreDNS has a working rewrite rule for nip.io routes.
  # Without this, pods can't resolve *.apps.127.0.0.1.nip.io and
  # hub's galaxy-status health check will fail with Connection refused.
  local corefile
  corefile=$(kubectl get configmap dns-default -n openshift-dns -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
  if [ -z "$corefile" ]; then
    return 0 # No CoreDNS configmap — skip check
  fi

  if [[ "$corefile" == *"rewrite"*"router-internal-default"* ]]; then
    # Verify the rewrite matches a real domain, not a garbled value
    if [[ "$corefile" == *"baseDomain:"* ]]; then
      printf "  \033[1;33mWARNING: CoreDNS rewrite rule is malformed (contains literal 'baseDomain:')\033[0m\n"
      echo "  Run 'aap-demo create' to fix, or manually patch the dns-default configmap."
      echo "  Without this fix, hub deployment will fail its route health check."
    fi
  else
    printf "  \033[1;33mWARNING: CoreDNS has no rewrite rule for in-cluster route resolution\033[0m\n"
    echo "  Pods may not be able to reach routes via nip.io."
    echo "  Run 'aap-demo create' to configure CoreDNS."
  fi
}

_grant_sccs() {
  local ns="$1"
  local _rc=0
  if command -v oc &>/dev/null; then
    local _scc_output
    _scc_output=$(oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${ns}" 2>&1) || {
      _err "Failed to grant anyuid SCC to namespace ${ns}"
      echo "  oc output: $_scc_output"
      echo "  Fix manually: oc adm policy add-scc-to-group anyuid system:serviceaccounts:${ns}"
      _rc=1
    }
    _scc_output=$(oc adm policy add-scc-to-group privileged "system:serviceaccounts:${ns}" 2>&1) || {
      _err "Failed to grant privileged SCC to namespace ${ns}"
      echo "  oc output: $_scc_output"
      echo "  Fix manually: oc adm policy add-scc-to-group privileged system:serviceaccounts:${ns}"
      _rc=1
    }
  else
    # Fallback: apply SCCs via kubectl (OpenShift Local where oc may not be available)
    echo "  'oc' not found — granting SCCs via kubectl..."
    for scc_name in anyuid privileged; do
      local crb_name="system:openshift:scc:${scc_name}:${ns}"
      if ! kubectl get clusterrolebinding "$crb_name" &>/dev/null; then
        kubectl create clusterrolebinding "$crb_name" \
          --clusterrole="system:openshift:scc:${scc_name}" \
          --group="system:serviceaccounts:${ns}" 2>&1 || {
          _err "Failed to create ClusterRoleBinding for ${scc_name} SCC"
          _rc=1
        }
      fi
    done
  fi
  return $_rc
}

setup_namespace() {
  echo "Setting up namespace..."
  # If namespace is terminating, wait for it to finish (max 30s) then force-clear
  local _ns_status
  _ns_status=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$_ns_status" = "Terminating" ]; then
    echo "  Namespace $NAMESPACE is terminating, waiting..."
    for i in $(seq 1 15); do
      sleep 2
      _ns_status=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      [ "$_ns_status" != "Terminating" ] && break
    done
    # Force-clear if still stuck
    if [ "$_ns_status" = "Terminating" ]; then
      echo "  Force-clearing stuck namespace..."
      kubectl get namespace "$NAMESPACE" -o json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); d[\"spec\"][\"finalizers\"]=[];print(json.dumps(d))" | kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f - 2>/dev/null || true
      sleep 2
    fi
  fi
  kubectl create namespace "$NAMESPACE" 2>/dev/null || true

  # Grant SCCs — required for pods to bind privileged ports
  if ! command -v oc &>/dev/null && command -v crc &>/dev/null; then
    local _crc_oc_path
    _crc_oc_path=$(crc oc-env 2>/dev/null | grep 'PATH=' | sed 's/.*PATH="\([^:]*\):.*/\1/' | head -1)
    [ -n "$_crc_oc_path" ] && [ -d "$_crc_oc_path" ] && export PATH="$_crc_oc_path:$PATH"
  fi
  _grant_sccs "$NAMESPACE"
  kubectl label namespace "$NAMESPACE" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged --overwrite

  # Create pull secret
  PULL_SECRET=""
  # Latest only needs registry.redhat.io credentials
  for path in "${PULL_SECRET_PATH:-}" "$HOME/.aap-demo/pull-secret" "$HOME/.aap-demo/pull-secret.txt" "$HOME/.aap-demo/pull-secret.json"; do
    if [ -n "$path" ] && [ -f "$path" ]; then
      PULL_SECRET="$path"
      break
    fi
  done

  if [ -n "$PULL_SECRET" ]; then
    echo "Using pull secret: $PULL_SECRET"
    kubectl delete secret redhat-operators-pull-secret -n "$NAMESPACE" 2>/dev/null || true
    kubectl create secret generic redhat-operators-pull-secret \
      --from-file=.dockerconfigjson="$PULL_SECRET" \
      --type=kubernetes.io/dockerconfigjson \
      -n "$NAMESPACE"

    # Add pull secret to default ServiceAccount (merge, don't replace)
    # This ensures pods using the default SA (e.g., postgres, redis) can pull images
    echo "Adding imagePullSecrets to default ServiceAccount..."
    EXISTING_SECRETS=$(kubectl get serviceaccount default -n "$NAMESPACE" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
    if echo "$EXISTING_SECRETS" | grep -q "redhat-operators-pull-secret"; then
      echo "  ✓ Pull secret already attached to default SA"
    else
      # Build merged imagePullSecrets array
      SECRETS_JSON='[{"name": "redhat-operators-pull-secret"}'
      for secret in $EXISTING_SECRETS; do
        SECRETS_JSON="${SECRETS_JSON}, {\"name\": \"${secret}\"}"
      done
      SECRETS_JSON="${SECRETS_JSON}]"
      kubectl patch serviceaccount default -n "$NAMESPACE" \
        -p "{\"imagePullSecrets\": ${SECRETS_JSON}}" 2>/dev/null || true
      echo "  ✓ Pull secret added to default SA"
    fi
  else
    echo "WARNING: No pull secret found"
  fi
}

deploy_operator_sdk() {
  local bundle_img="$1"

  echo ""
  echo "Running operator-sdk bundle..."

  # Check for operator-sdk
  if ! command -v operator-sdk >/dev/null 2>&1; then
    echo "ERROR: operator-sdk not found"
    echo "Install with: brew install operator-sdk"
    exit 1
  fi

  operator-sdk run bundle "$bundle_img" \
    --namespace "$NAMESPACE" \
    --security-context-config restricted \
    --timeout 10m \
    --pull-secret-name redhat-operators-pull-secret
}

create_aap_instance() {
  echo ""
  echo "Creating AAP instance..."

  # Determine CR file (default: minimal, can override with CR=name)
  local cr_name="${CR:-minimal}"
  local cr_file="${SCRIPT_DIR}/config/crs/aap-${cr_name}.yaml"

  if [ ! -f "$cr_file" ]; then
    echo "ERROR: CR file not found: $cr_file"
    echo "Available CRs:"
    ls -1 "${SCRIPT_DIR}/config/crs/" | sed 's/aap-//; s/.yaml//'
    exit 1
  fi

  # For noingress CRs, substitute PUBLIC_URL placeholder
  if [[ "$cr_name" == *"noingress"* ]]; then
    # Auto-construct URL from POD_NAME, POD_NAMESPACE, BASE_DOMAIN if PUBLIC_URL not provided
    if [ -z "$PUBLIC_URL" ]; then
      if [ -n "$POD_NAME" ] && [ -n "$POD_NAMESPACE" ] && [ -n "$BASE_DOMAIN" ]; then
        PUBLIC_URL="https://aap-${POD_NAME}-${POD_NAMESPACE}.${BASE_DOMAIN}"
        echo "Auto-constructed PUBLIC_URL: $PUBLIC_URL"
      else
        echo "ERROR: PUBLIC_URL required for noingress CR"
        echo ""
        echo "Option 1 - Full URL:"
        echo "  aap-demo deploy-aap CR=minimal-noingress PUBLIC_URL=https://aap.apps.example.com"
        echo ""
        echo "Option 2 - Auto-construct from components:"
        echo "  aap-demo deploy-aap CR=minimal-noingress POD_NAME=engkube-runner POD_NAMESPACE=engkube BASE_DOMAIN=apps.ocp.rdu.eng.ansible.com"
        echo "  -> https://aap-engkube-runner-engkube.apps.ocp.rdu.eng.ansible.com"
        exit 1
      fi
    fi
    echo "Using CR: $cr_name with PUBLIC_URL=$PUBLIC_URL"
    sed "s|__PUBLIC_BASE_URL__|${PUBLIC_URL}|g" "$cr_file" | kubectl apply -f - -n "$NAMESPACE"
  else
    echo "Using CR: $cr_name"
    # Adjust hub storage based on available StorageClasses
    if kubectl get sc nfs-local-rwx &>/dev/null; then
      kubectl apply -f "$cr_file" -n "$NAMESPACE"
    else
      # No RWX storage — fall back to default SC with ReadWriteOnce
      sed -e 's/file_storage_storage_class: nfs-local-rwx/# file_storage_storage_class: (using default)/' \
        -e 's/file_storage_access_mode: ReadWriteMany/file_storage_access_mode: ReadWriteOnce/' \
        "$cr_file" | kubectl apply -f - -n "$NAMESPACE"
      echo "  (Using ReadWriteOnce — nfs-local-rwx not available)"
    fi
  fi

  # Patch gateway deployment for OpenShift Local compatibility
  # The gateway pod needs NET_BIND_SERVICE capability but the operator
  # doesn't add it. On full OpenShift the privileged SCC grants all
  # capabilities automatically, but on OpenShift Local the SCC admission
  # controller picks restricted-v2 which doesn't include it.
  _patch_gateway_capability
}

_patch_gateway_capability() {
  local aap_name
  aap_name=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  [ -z "$aap_name" ] && return 0

  local deploy_name="${aap_name}-gateway"
  echo ""
  echo "Waiting for gateway deployment..."

  # Wait for gateway deployment to appear (operator creates it during reconciliation)
  local attempts=0
  while ! kubectl get deployment "$deploy_name" -n "$NAMESPACE" &>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 60 ]; then
      echo "  ⚠ Gateway deployment not found after 5 minutes — skipping capability patch"
      return 0
    fi
    sleep 5
  done

  # Check if already patched
  local existing_caps
  existing_caps=$(kubectl get deployment "$deploy_name" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[?(@.name=="api")].securityContext.capabilities.add}' 2>/dev/null || echo "")
  if [[ "$existing_caps" == *"NET_BIND_SERVICE"* ]]; then
    echo "  ✓ Gateway already has NET_BIND_SERVICE capability"
    return 0
  fi

  echo "  Patching gateway with NET_BIND_SERVICE capability..."
  if kubectl patch deployment "$deploy_name" -n "$NAMESPACE" --type=strategic \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"api","securityContext":{"capabilities":{"add":["NET_BIND_SERVICE"]}}}]}}}}' &>/dev/null; then
    echo "  ✓ Gateway patched — pod will restart with correct capabilities"
  else
    echo "  ⚠ Gateway patch failed — may need manual fix if gateway crashes"
  fi
}

watch_aap() {
  NAMESPACE="${NAMESPACE:-aap-operator}"
  export KUBECONFIG="${KUBECONFIG:-$HOME/.crc/machines/crc/kubeconfig}"

  TIMEOUT=3600 # 60 minutes
  INTERVAL=10  # seconds between refreshes
  WATCH_START=$(date +%s)

  while true; do
    # clear requires TERM to be set (fails in nohup/cron)
    if [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
      clear
    fi

    # Calculate elapsed time
    NOW=$(date +%s)
    ELAPSED=$((NOW - WATCH_START))

    # Get cluster info
    CLUSTER=$(kubectl config current-context 2>/dev/null || echo "unknown")

    echo "=== AAP Deployment Status (${ELAPSED}s elapsed) ==="
    echo "Cluster: $CLUSTER | Namespace: $NAMESPACE"
    echo "Press Ctrl+C to exit"
    echo ""

    # AAP CR status
    echo "AAP CR:"
    kubectl get aap -n "$NAMESPACE" 2>/dev/null || echo "  No AAP CR found"
    echo ""

    # AAP conditions
    echo "Conditions:"
    kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[*].status.conditions}' 2>/dev/null \
      | jq -r '.[] | "  \(.type): \(.status) - \(.reason // .message // "n/a")"' 2>/dev/null || echo "  No status yet"
    echo ""

    # Pods
    echo "Pods:"
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "  No pods found"
    echo ""

    # Routes
    echo "Routes:"
    kubectl get route -n "$NAMESPACE" 2>/dev/null || echo "  No routes found"
    echo ""

    # Always show credentials if admin secret exists
    ADMIN_SECRET=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].status.adminPasswordSecret}' 2>/dev/null || true)
    if [ -n "$ADMIN_SECRET" ]; then
      ADMIN_PASSWORD=$(kubectl get secret -n "$NAMESPACE" "$ADMIN_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
      if [ -n "$ADMIN_PASSWORD" ]; then
        AAP_URL=$(kubectl get route -n "$NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "(route not found)")
        echo "Credentials:"
        echo "  URL:      https://$AAP_URL"
        echo "  Username: admin"
        echo "  Password: $ADMIN_PASSWORD"
        echo ""
      fi
    fi

    # Check if deployment is complete
    SUCCESSFUL=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || echo "")
    if [ "$SUCCESSFUL" = "True" ]; then
      # Get admin password from secret
      ADMIN_PASSWORD=""
      ADMIN_SECRET=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].status.adminPasswordSecret}' 2>/dev/null || true)
      if [ -n "$ADMIN_SECRET" ]; then
        ADMIN_PASSWORD=$(kubectl get secret -n "$NAMESPACE" "$ADMIN_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
      fi
      # Fallback to common secret names
      if [ -z "$ADMIN_PASSWORD" ]; then
        for secret_name in aap-admin-password aap-controller-admin-password custom-admin-password; do
          ADMIN_PASSWORD=$(kubectl get secret -n "$NAMESPACE" "$secret_name" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
          if [ -n "$ADMIN_PASSWORD" ]; then
            break
          fi
        done
      fi

      echo "✓ AAP deployment successful!"
      echo ""
      # Show CSV and namespace
      CSV_NAME=$(kubectl get csv -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
      if [ -n "$CSV_NAME" ]; then
        echo "CSV: $CSV_NAME"
      fi
      echo "Namespace: $NAMESPACE"
      echo ""
      AAP_URL=$(kubectl get route -n "$NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "(route not found)")
      echo "AAP UI: https://$AAP_URL"
      echo ""
      echo "Username: admin"
      if [ -n "$ADMIN_PASSWORD" ]; then
        echo "Password: $ADMIN_PASSWORD"
      else
        echo "Password: (run: kubectl get secret -n $NAMESPACE aap-admin-password -o jsonpath='{.data.password}' | base64 -d)"
      fi
      echo ""

      return 0
    fi

    # Check timeout
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
      echo "WARNING: Deployment not complete after 60 minutes"
      echo "Check: kubectl get aap -n $NAMESPACE -o yaml"
      return 1
    fi

    sleep "$INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# Addon management: enable / disable
# ---------------------------------------------------------------------------
AVAILABLE_ADDONS="mcp-server portal"

_addons_config_file() {
  echo "${HOME}/.aap-demo/config"
}

_addons_list() {
  local config
  config="$(_addons_config_file)"
  if [ -f "$config" ]; then
    grep '^ADDONS=' "$config" 2>/dev/null | cut -d= -f2 | tr ',' ' '
  fi
}

_addons_save() {
  local addons="$1"
  local config
  config="$(_addons_config_file)"
  mkdir -p "$(dirname "$config")"
  if [ -f "$config" ] && grep -q '^ADDONS=' "$config"; then
    sed -i.bak "s/^ADDONS=.*/ADDONS=${addons}/" "$config" && rm -f "${config}.bak"
  else
    echo "ADDONS=${addons}" >>"$config"
  fi
}

_addons_add() {
  local addon="$1"
  local current
  current=$(_addons_list)
  # Don't add if already present
  if echo "$current" | grep -qw "$addon"; then
    return
  fi
  if [ -n "$current" ]; then
    _addons_save "$(echo "$current $addon" | tr ' ' ',')"
  else
    _addons_save "$addon"
  fi
}

_addons_remove() {
  local addon="$1"
  local current new
  current=$(_addons_list)
  new=$(echo "$current" | tr ' ' '\n' | grep -v "^${addon}$" | tr '\n' ',' | sed 's/,$//')
  _addons_save "$new"
}

cmd_enable() {
  local addon="${1:-}"
  if [ -z "$addon" ]; then
    echo "Usage: aap-demo enable <addon>"
    echo ""
    local saved
    saved=$(_addons_list)
    echo "Available addons:"
    for a in $AVAILABLE_ADDONS; do
      local status="available"
      if echo "$saved" | grep -qw "$a"; then
        status="enabled"
      elif [ ! -d "${SCRIPT_DIR}/addons/${a}" ]; then
        status="not found"
      fi
      printf "  %-15s %s\n" "$a" "($status)"
    done
    return 0
  fi

  local addon_dir="${SCRIPT_DIR}/addons/${addon}"
  if [ ! -d "$addon_dir" ]; then
    echo "Unknown addon: $addon"
    echo "Available: $AVAILABLE_ADDONS"
    return 1
  fi

  if [ ! -f "$addon_dir/deploy.sh" ]; then
    echo "Addon '$addon' has no deploy.sh"
    return 1
  fi

  echo "Enabling addon: $addon"
  _verify_cluster || return 1
  bash "$addon_dir/deploy.sh"
  _addons_add "$addon"
  echo "  Saved to config: ADDONS=$(_addons_list | tr ' ' ',')"
}

cmd_disable() {
  local addon="${1:-}"
  if [ -z "$addon" ]; then
    echo "Usage: aap-demo disable <addon>"
    echo ""
    echo "Available addons: $AVAILABLE_ADDONS"
    return 0
  fi

  local addon_dir="${SCRIPT_DIR}/addons/${addon}"
  if [ ! -d "$addon_dir" ]; then
    echo "Unknown addon: $addon"
    return 1
  fi

  if [ -f "$addon_dir/deploy.sh" ]; then
    echo "Disabling addon: $addon"
    setup_kubeconfig
    bash "$addon_dir/deploy.sh" --delete
    _addons_remove "$addon"
    echo "  Removed from config"
  else
    echo "Addon '$addon' has no deploy.sh"
    return 1
  fi
}

# Setup KUBECONFIG based on infrastructure type (skip for help/config commands)
case "$COMMAND" in
  help | --help | -h | config | update | "" | destroy)
    # These commands don't need cluster access
    ;;
  redeploy-all | deploy | deploy-all | redeploy | create)
    # These handle their own cluster state (auto-start if stopped)
    setup_kubeconfig
    ;;
  *)
    setup_kubeconfig
    verify_cluster_type || exit 1
    ;;
esac

case "$COMMAND" in
  help | --help | -h)
    show_help
    ;;
  repair)
    cmd_repair
    ;;
  clean)
    cmd_clean
    ;;
  destroy)
    for _arg in "${EXTRA_ARGS[@]}"; do
      [ "$_arg" = "--reset" ] && _DESTROY_RESET=true
    done
    cmd_destroy
    ;;
  stop)
    cmd_stop
    ;;
  start)
    cmd_start
    ;;
  create)
    cmd_create
    ;;
  setup)
    cmd_setup
    ;;
  watch)
    watch_aap
    ;;
  status)
    cmd_status
    ;;
  update)
    cmd_update
    ;;
  config)
    cmd_config "${EXTRA_ARGS[@]}"
    ;;
  redeploy)
    cmd_redeploy
    ;;
  redeploy-all)
    cmd_redeploy-all
    ;;
  redhat-status | rh-status)
    cmd_redhat_status
    ;;
  kubeconfig)
    cmd_kubeconfig
    ;;
  ssh)
    cmd_ssh
    ;;
  idle)
    cmd_idle "${EXTRA_ARGS[0]:-}"
    ;;
  diagnose)
    # Check for --ai flag
    for _arg in "${EXTRA_ARGS[@]}"; do
      [ "$_arg" = "--ai" ] && _DIAGNOSE_AI=true
    done
    cmd_diagnose
    ;;
  must-gather)
    cmd_must_gather "${EXTRA_ARGS[0]:-}"
    ;;
  test)
    cmd_test "${EXTRA_ARGS[@]}"
    ;;
  enable)
    cmd_enable "${EXTRA_ARGS[0]:-}"
    ;;
  disable)
    cmd_disable "${EXTRA_ARGS[0]:-}"
    ;;
  deploy | deploy-all)
    cmd_deploy
    ;;
  deploy-operator)
    CREATE_AAP=false cmd_deploy
    ;;
  deploy-aap)
    # Deploy just the AAP CR (assumes operator is already installed)
    create_aap_instance
    watch_aap
    ;;
  *)
    # Default: show welcome if no command specified, or error for unknown commands
    if [ -z "$COMMAND" ] || [ "$COMMAND" = "" ]; then
      show_welcome
    else
      echo "Unknown command: $COMMAND"
      echo "Run 'aap-demo help' for usage"
      exit 1
    fi
    ;;
esac
