#!/usr/bin/env bash
# Subscription Attach Addon
#
# Automatically attaches a Red Hat subscription to AAP using Red Hat developer
# account credentials. This addon is automatically invoked after AAP deployment
# via addon-wire.sh integration.
#
# Environment variables:
#   REDHAT_SUBSCRIPTION_USERNAME - Red Hat account username (email)
#   REDHAT_SUBSCRIPTION_PASSWORD - Red Hat account password
#   REDHAT_SUBSCRIPTION_CREDENTIALS_FILE - Path to saved credentials
#   QUIET - Skip interactive prompts (default: false)
#
# Usage:
#   ./deploy.sh          # Attach subscription (auto-called by addon-wire)
#   ./deploy.sh --delete # No-op (subscription remains in AAP)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"

# Credential file paths
REDHAT_SUBSCRIPTION_CREDENTIALS_FILE="${REDHAT_SUBSCRIPTION_CREDENTIALS_FILE:-$HOME/.aap-demo/redhat-subscription-credentials}"
REDHAT_SUBSCRIPTION_USERNAME="${REDHAT_SUBSCRIPTION_USERNAME:-}"
REDHAT_SUBSCRIPTION_PASSWORD="${REDHAT_SUBSCRIPTION_PASSWORD:-}"

# Helper functions
info() {
  printf '%s\n' "$*"
}

warn() {
  printf '⚠  %s\n' "$*" >&2
}

error() {
  printf '❌ ERROR: %s\n' "$*" >&2
}

# ==============================================================================
# DELETE HANDLER
# ==============================================================================

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  info "Subscription remains attached to AAP - no cleanup needed"
  exit 0
fi

# ==============================================================================
# PREREQUISITE CHECKS
# ==============================================================================

# Check cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
  error "Cannot connect to cluster"
  warn "Please ensure your cluster is running: aap-demo status"
  exit 1
fi

# Check if AAP is deployed
if ! kubectl get aap -n "$NAMESPACE" &>/dev/null; then
  error "AAP not found in namespace $NAMESPACE"
  warn "Please deploy AAP first: aap-demo deploy"
  exit 1
fi

# Check required tools
for tool in curl jq kubectl; do
  if ! command -v "$tool" &>/dev/null; then
    error "Required tool not found: $tool"
    exit 1
  fi
done

# Check for ansible-playbook
if ! command -v ansible-playbook &>/dev/null; then
  error "ansible-playbook not found"
  warn "Please install Ansible: pip install ansible-core"
  exit 1
fi

# ==============================================================================
# CREDENTIAL MANAGEMENT
# ==============================================================================

load_redhat_credentials_from_file() {
  local creds_file="$1"

  if [ ! -f "$creds_file" ]; then
    return 1
  fi

  # Parse YAML credentials file (simple key: value format)
  if command -v yq &>/dev/null 2>&1; then
    REDHAT_SUBSCRIPTION_USERNAME=$(yq eval '.username' "$creds_file" 2>/dev/null || echo "")
    REDHAT_SUBSCRIPTION_PASSWORD=$(yq eval '.password' "$creds_file" 2>/dev/null || echo "")
  else
    # Fallback to grep/sed if yq not available
    REDHAT_SUBSCRIPTION_USERNAME=$(grep -E '^username:' "$creds_file" | sed 's/^username: *//' || echo "")
    REDHAT_SUBSCRIPTION_PASSWORD=$(grep -E '^password:' "$creds_file" | sed 's/^password: *//' || echo "")
  fi

  if [ -n "$REDHAT_SUBSCRIPTION_USERNAME" ] && [ -n "$REDHAT_SUBSCRIPTION_PASSWORD" ]; then
    export REDHAT_SUBSCRIPTION_USERNAME REDHAT_SUBSCRIPTION_PASSWORD
    return 0
  fi

  return 1
}

prompt_redhat_credentials() {
  # 1. Check saved credentials file
  if [ -f "$REDHAT_SUBSCRIPTION_CREDENTIALS_FILE" ]; then
    if load_redhat_credentials_from_file "$REDHAT_SUBSCRIPTION_CREDENTIALS_FILE"; then
      info "Red Hat credentials loaded from $REDHAT_SUBSCRIPTION_CREDENTIALS_FILE"
      return 0
    fi
  fi

  # 2. Check environment variables
  if [ -n "${REDHAT_SUBSCRIPTION_USERNAME:-}" ] && [ -n "${REDHAT_SUBSCRIPTION_PASSWORD:-}" ]; then
    info "Using Red Hat credentials from environment variables"
    return 0
  fi

  # 3. Skip prompt if QUIET mode or non-interactive
  if [ "${QUIET:-false}" = "true" ] || [ ! -t 0 ]; then
    info "Skipping Red Hat subscription configuration"
    info "  (set REDHAT_SUBSCRIPTION_USERNAME and REDHAT_SUBSCRIPTION_PASSWORD to enable)"
    return 1
  fi

  # 4. Interactive prompt with instructions
  echo ""
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Red Hat Developer Subscription (Optional)"
  info ""
  info "To automatically attach a subscription to AAP, provide your Red Hat"
  info "developer account credentials. This will lookup and attach your"
  info "developer subscription without manual UI interaction."
  info ""
  info "Get a free developer subscription at:"
  info "  https://developers.redhat.com/register"
  info ""
  info "Press Enter to skip (you can attach a subscription manually later)"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  read -r -p "Red Hat username (email) [leave empty to skip]: " REDHAT_SUBSCRIPTION_USERNAME

  if [ -z "$REDHAT_SUBSCRIPTION_USERNAME" ]; then
    info "Skipping subscription attachment - you can attach manually in AAP UI (Settings → Subscription)"
    return 1
  fi

  read -r -s -p "Red Hat password: " REDHAT_SUBSCRIPTION_PASSWORD
  echo ""

  if [ -z "$REDHAT_SUBSCRIPTION_PASSWORD" ]; then
    warn "Password cannot be empty - skipping subscription attachment"
    return 1
  fi

  # 5. Save credentials securely
  info "Saving credentials to $REDHAT_SUBSCRIPTION_CREDENTIALS_FILE"
  (
    umask 077
    mkdir -p "$(dirname "$REDHAT_SUBSCRIPTION_CREDENTIALS_FILE")"
    cat > "$REDHAT_SUBSCRIPTION_CREDENTIALS_FILE" <<EOF
username: $REDHAT_SUBSCRIPTION_USERNAME
password: $REDHAT_SUBSCRIPTION_PASSWORD
EOF
  )
  chmod 600 "$REDHAT_SUBSCRIPTION_CREDENTIALS_FILE"
  info "✓ Credentials saved securely"
  echo ""

  export REDHAT_SUBSCRIPTION_USERNAME REDHAT_SUBSCRIPTION_PASSWORD
  return 0
}

# ==============================================================================
# SUBSCRIPTION STATUS CHECK
# ==============================================================================

check_subscription_status() {
  local aap_route aap_url aap_username aap_password config_response

  # Get AAP route
  aap_route=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [ -z "$aap_route" ]; then
    error "Cannot find AAP route"
    return 1
  fi

  aap_url="https://${aap_route}"

  # Get AAP admin credentials
  aap_username="admin"
  aap_password=$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")

  if [ -z "$aap_password" ]; then
    error "Cannot retrieve AAP admin password"
    return 1
  fi

  # Check subscription status via API
  config_response=$(curl -sk -u "${aap_username}:${aap_password}" \
    --connect-timeout 10 --max-time 30 \
    "${aap_url}/api/controller/v2/config/" 2>/dev/null || echo "")

  if [ -z "$config_response" ]; then
    warn "Could not query AAP config API"
    return 1
  fi

  local valid_key license_type
  valid_key=$(echo "$config_response" | jq -r '.license_info.valid_key // false' 2>/dev/null)
  license_type=$(echo "$config_response" | jq -r '.license_info.license_type // "UNLICENSED"' 2>/dev/null)

  if [ "$valid_key" = "true" ] && [ "$license_type" != "UNLICENSED" ]; then
    info "✓ AAP already has a valid subscription (type: $license_type)"
    return 0
  fi

  return 1
}

# ==============================================================================
# SUBSCRIPTION ATTACHMENT
# ==============================================================================

attach_subscription() {
  local aap_route aap_url aap_username aap_password playbook_path

  info "Attaching Red Hat subscription to AAP..."

  # Get AAP connection details
  aap_route=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [ -z "$aap_route" ]; then
    error "Cannot find AAP route"
    return 1
  fi

  aap_url="https://${aap_route}"
  aap_username="admin"
  aap_password=$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")

  if [ -z "$aap_password" ]; then
    error "Cannot retrieve AAP admin password"
    return 1
  fi

  # Export environment variables for Ansible playbook
  export AAP_HOSTNAME="$aap_url"
  export AAP_USERNAME="$aap_username"
  export AAP_PASSWORD="$aap_password"
  export REDHAT_SUBSCRIPTION_USERNAME
  export REDHAT_SUBSCRIPTION_PASSWORD

  # Run Ansible playbook
  playbook_path="${SCRIPT_DIR}/attach-subscription.yml"

  if [ ! -f "$playbook_path" ]; then
    error "Playbook not found: $playbook_path"
    return 1
  fi

  info "Running subscription attachment playbook..."
  echo ""

  if ansible-playbook "$playbook_path"; then
    echo ""
    info "✓ Subscription attachment complete"
    return 0
  else
    echo ""
    error "Subscription attachment failed"
    warn "You can attach a subscription manually in AAP UI: ${aap_url}"
    warn "Navigate to: Settings → Subscription"
    return 1
  fi
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

main() {
  info "Checking AAP subscription status..."

  # Check if subscription already attached
  if check_subscription_status; then
    return 0
  fi

  info "No valid subscription found - attempting automatic attachment..."

  # Prompt for credentials if not already set
  if ! prompt_redhat_credentials; then
    warn "Red Hat credentials not provided - skipping subscription attachment"
    warn "To attach a subscription manually, log into AAP UI:"
    warn "  $(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo 'AAP_ROUTE')"
    warn "  Navigate to: Settings → Subscription"
    return 0
  fi

  # Attach subscription
  if ! attach_subscription; then
    warn "Subscription attachment failed - continuing anyway"
    return 0
  fi
}

main "$@"
