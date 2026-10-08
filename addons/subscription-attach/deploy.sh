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
#   SUBSCRIPTION_INTERACTIVE - Set to 'true' to choose subscription interactively
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

# No additional tool requirements - uses curl and jq (already checked above)

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

  local valid_key license_type subscription_name
  valid_key=$(echo "$config_response" | jq -r '.license_info.valid_key // false' 2>/dev/null)
  license_type=$(echo "$config_response" | jq -r '.license_info.license_type // "UNLICENSED"' 2>/dev/null)
  subscription_name=$(echo "$config_response" | jq -r '.license_info.subscription_name // "Unknown"' 2>/dev/null)

  if [ "$valid_key" = "true" ] && [ "$license_type" != "UNLICENSED" ]; then
    info "✓ AAP already has a valid subscription: $subscription_name"
    return 0
  fi

  return 1
}

# ==============================================================================
# SUBSCRIPTION ATTACHMENT
# ==============================================================================

attach_subscription() {
  local aap_route aap_url aap_username aap_password
  local patch_payload patch_response config_response
  local valid_key license_type subscription_name

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

  # Step 1: POST /api/controller/v2/config/subscriptions/ to get available subscriptions
  info "Retrieving available subscriptions from Red Hat..."

  local subscriptions_payload subscriptions_response subscription_id

  subscriptions_payload=$(jq -n \
    --arg username "$REDHAT_SUBSCRIPTION_USERNAME" \
    --arg password "$REDHAT_SUBSCRIPTION_PASSWORD" \
    '{
      subscriptions_username: $username,
      subscriptions_password: $password
    }')

  subscriptions_response=$(curl -sk -u "${aap_username}:${aap_password}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$subscriptions_payload" \
    "${aap_url}/api/controller/v2/config/subscriptions/" 2>/dev/null || echo "")

  if [ -z "$subscriptions_response" ]; then
    error "Failed to retrieve subscriptions from Red Hat"
    warn "API request failed - check AAP status and network connectivity"
    return 1
  fi

  # Check for API errors
  if echo "$subscriptions_response" | jq -e '.detail' >/dev/null 2>&1; then
    local error_detail
    error_detail=$(echo "$subscriptions_response" | jq -r '.detail' 2>/dev/null || echo "Unknown error")
    error "Failed to retrieve subscriptions"
    warn "API error: $error_detail"
    warn "This usually means incorrect credentials or no subscriptions available"
    return 1
  fi

  # Check if response is an array
  if ! echo "$subscriptions_response" | jq -e '. | type == "array"' >/dev/null 2>&1; then
    error "Unexpected response format from subscriptions API"
    warn "Expected array of subscriptions, got: $(echo "$subscriptions_response" | jq -r 'type')"
    return 1
  fi

  # Interactive selection or automatic default
  if [ "${SUBSCRIPTION_INTERACTIVE:-false}" = "true" ] && [ -t 0 ]; then
    # Interactive mode: Show available subscriptions and let user choose
    info "Available Red Hat Ansible Automation Platform subscriptions:"
    echo ""

    local sub_list sub_count i sub_id sub_name
    sub_list=$(echo "$subscriptions_response" | jq -c '[.[] | select(.product_name == "Red Hat Ansible Automation Platform" and .valid_key == true)]' 2>/dev/null)
    sub_count=$(echo "$sub_list" | jq 'length' 2>/dev/null)

    if [ "$sub_count" -eq 0 ]; then
      error "No valid Red Hat Ansible Automation Platform subscriptions found"
      return 1
    fi

    for i in $(seq 0 $((sub_count - 1))); do
      sub_name=$(echo "$sub_list" | jq -r ".[$i].subscription_name" 2>/dev/null)
      sub_id=$(echo "$sub_list" | jq -r ".[$i].subscription_id" 2>/dev/null)
      printf "%d) %s (ID: %s)\n" $((i + 1)) "$sub_name" "$sub_id"
    done

    echo ""
    read -r -p "Select subscription number [1-${sub_count}]: " selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$sub_count" ]; then
      error "Invalid selection: $selection"
      return 1
    fi

    subscription_id=$(echo "$sub_list" | jq -r ".[$(($selection - 1))].subscription_id" 2>/dev/null)
  else
    # Automatic mode: Prefer Developer subscription, fall back to any AAP subscription
    subscription_id=$(echo "$subscriptions_response" | jq -r '
      # First try: Developer subscription
      ([.[] | select(
        .product_name == "Red Hat Ansible Automation Platform" and
        .valid_key == true and
        (.subscription_name | contains("Developer"))
      )] | .[0].subscription_id) //
      # Fallback: Any valid AAP subscription
      ([.[] | select(
        .product_name == "Red Hat Ansible Automation Platform" and
        .valid_key == true
      )] | .[0].subscription_id) //
      empty
    ' 2>/dev/null)
  fi

  if [ -z "$subscription_id" ]; then
    error "No valid Red Hat Ansible Automation Platform subscription found"
    warn "Available subscriptions:"
    echo "$subscriptions_response" | jq -r '.[] | "  - \(.subscription_name) (\(.product_name)) [ID: \(.subscription_id)]"' 2>/dev/null || true
    return 1
  fi

  local selected_name
  selected_name=$(echo "$subscriptions_response" | jq -r --arg id "$subscription_id" '.[] | select(.subscription_id == $id) | .subscription_name' 2>/dev/null)
  info "✓ Selected subscription: $selected_name (ID: $subscription_id)"

  # Step 2: POST /api/controller/v2/config/attach/ to attach the selected subscription
  info "Attaching subscription to AAP..."

  local attach_payload attach_response

  attach_payload=$(jq -n --arg id "$subscription_id" '{subscription_id: $id}')

  attach_response=$(curl -sk -u "${aap_username}:${aap_password}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$attach_payload" \
    "${aap_url}/api/controller/v2/config/attach/" 2>/dev/null || echo "")

  if [ -z "$attach_response" ]; then
    error "Failed to attach subscription"
    warn "API request failed - check AAP status"
    return 1
  fi

  # Check attach response for errors or success
  if echo "$attach_response" | jq -e '.detail' >/dev/null 2>&1; then
    local error_detail
    error_detail=$(echo "$attach_response" | jq -r '.detail' 2>/dev/null || echo "Unknown error")
    error "Failed to attach subscription"
    warn "API error: $error_detail"
    return 1
  fi

  # Debug: Uncomment to see the full attach API response for troubleshooting
  # if echo "$attach_response" | jq -e '.' >/dev/null 2>&1; then
  #   info "Attach API response: $(echo "$attach_response" | jq -c '.')"
  # fi

  # Verify attachment was successful (poll a few times as it may take a moment)
  info "Verifying subscription attachment..."

  local verify_attempt max_verify_attempts=5
  for verify_attempt in $(seq 1 $max_verify_attempts); do
    sleep 2

    config_response=$(curl -sk -u "${aap_username}:${aap_password}" \
      --connect-timeout 10 --max-time 30 \
      "${aap_url}/api/controller/v2/config/" 2>/dev/null || echo "")

    valid_key=$(echo "$config_response" | jq -r '.license_info.valid_key // false' 2>/dev/null)
    license_type=$(echo "$config_response" | jq -r '.license_info.license_type // "UNLICENSED"' 2>/dev/null)

    if [ "$valid_key" = "true" ] && [ "$license_type" != "UNLICENSED" ]; then
      subscription_name=$(echo "$config_response" | jq -r '.license_info.subscription_name // "Unknown"' 2>/dev/null)
      echo ""
      info "✓ Subscription attached successfully!"
      info "  Type: $license_type"
      info "  Subscription: $subscription_name"
      return 0
    fi

    # Not verified yet, show progress
    info "  Waiting for license to appear... (attempt $verify_attempt/$max_verify_attempts)"
  done

  # Verification timed out
  warn "Subscription attachment may have failed - license not showing as valid after $((max_verify_attempts * 2)) seconds"
  warn "This can happen if the subscription was already attached or if there was an API error"
  warn "Check AAP UI at: ${aap_url}"
  warn "Current license status: valid_key=$valid_key, license_type=$license_type"
  return 1
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
