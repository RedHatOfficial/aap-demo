#!/usr/bin/env bash
# AAP Session-based Authentication Helper
# Required for AAP 2.7+ gateway-based API access

set -euo pipefail

# Session cookie storage
SESSION_COOKIE_FILE="/tmp/.aap-demo-session-cookie"

aap_login() {
  local username="$1"
  local password="$2"
  local base_url="$3"

  info "Logging into AAP gateway..."

  # Get CSRF token first
  local csrf_token
  csrf_token=$(curl -k -s -c "$SESSION_COOKIE_FILE" \
    "${base_url}/api/login/" | jq -r '.csrfToken // empty')

  if [ -z "$csrf_token" ]; then
    # Try alternate endpoint
    csrf_token=$(curl -k -s -c "$SESSION_COOKIE_FILE" -b "$SESSION_COOKIE_FILE" \
      "${base_url}/api/gateway/v1/csrf/" | jq -r '.csrfToken // empty')
  fi

  if [ -z "$csrf_token" ]; then
    error "Failed to get CSRF token"
    return 1
  fi

  # Login with credentials
  local login_response
  login_response=$(curl -k -s -b "$SESSION_COOKIE_FILE" -c "$SESSION_COOKIE_FILE" \
    -H "Content-Type: application/json" \
    -H "X-CSRFToken: $csrf_token" \
    -X POST \
    -d "{\"username\":\"${username}\",\"password\":\"${password}\"}" \
    "${base_url}/api/login/")

  # Check if login was successful
  if echo "$login_response" | jq -e '.token or .access_token or .key' >/dev/null 2>&1; then
    info "Login successful"
    export AAP_CSRF_TOKEN="$csrf_token"
    return 0
  else
    error "Login failed: $(echo "$login_response" | jq -r '.detail // .')"
    return 1
  fi
}

aap_api_session() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  local url="${AAP_URL}/${endpoint}"
  local args=(
    -X "$method"
    -b "$SESSION_COOKIE_FILE"
    -c "$SESSION_COOKIE_FILE"
    -H "Content-Type: application/json"
    -H "X-CSRFToken: ${AAP_CSRF_TOKEN}"
    --insecure
    --silent
    --show-error
  )

  if [ -n "$data" ]; then
    args+=(-d "$data")
  fi

  curl "${args[@]}" "$url"
}
