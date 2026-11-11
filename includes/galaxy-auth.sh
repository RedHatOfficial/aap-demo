#!/usr/bin/env bash
# =============================================================================
# galaxy-auth.sh — Galaxy / PAH credential detection and remote configuration
# =============================================================================
# Source this file; do not execute it directly.
# Requires: _RED, _GREEN, _YELLOW, _NC colour vars and _err() from caller.

if [ -n "${_GALAXY_AUTH_LOADED:-}" ]; then return 0; fi
_GALAXY_AUTH_LOADED=1

# Fallbacks when sourced outside aap-demo.sh (e.g. addon subprocesses)
if ! declare -f _err >/dev/null 2>&1; then
  _err() { printf 'ERROR: %s\n' "$*" >&2; }
fi
_YELLOW="${_YELLOW:-}"
_NC="${_NC:-}"
GALAXY_AUTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=credential-vault.sh
source "${GALAXY_AUTH_DIR}/credential-vault.sh"
# shellcheck source=secure-curl.sh
source "${GALAXY_AUTH_DIR}/secure-curl.sh"

galaxy_offline_token_status() {
  local token="$1" client_id="${2:-cloud-services}" response http_code
  [ -n "$token" ] || return 1
  _aap_demo_vault_require_tools || return 2

  response=$(printf '%s' "$token" | curl --silent --show-error \
    --connect-timeout 15 --max-time 45 \
    --write-out '\n%{http_code}' \
    --request POST \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "client_id=${client_id}" \
    --data-urlencode "refresh_token@-" \
    "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token" \
    2>/dev/null) || {
      unset token
      return 2
    }
  unset token
  http_code="${response##*$'\n'}"
  case "$http_code" in
    200)
      "$AAP_DEMO_VAULT_PYTHON" -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except (ValueError, TypeError):
    raise SystemExit(2)
token = data.get("access_token") if isinstance(data, dict) else None
raise SystemExit(0 if isinstance(token, str) and token.strip() else 2)
' <<<"${response%$'\n'*}"
      ;;
    400 | 401 | 403) return 1 ;;
    *) return 2 ;;
  esac
}

prepare_galaxy_credentials() {
  local rc
  detect_galaxy_credentials || return $?

  if [ -z "${GALAXY_TOKEN:-}" ]; then
    return 1
  fi
  if galaxy_offline_token_status "$GALAXY_TOKEN"; then
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 2 ]; then
    _err "Unable to validate the Automation Hub token: Red Hat SSO is unavailable or returned an invalid response; credentials were preserved"
    return 2
  fi
  printf "  ⚠ Stored Automation Hub token is invalid; removing it from encrypted storage\n" >&2
  aap_demo_vault_delete "ah_offline_token" || return 2
  GALAXY_TOKEN=""
  export GALAXY_TOKEN
  return 1
}

ensure_galaxy_credentials() {
  local rc
  if prepare_galaxy_credentials; then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -ne 2 ] || return 2

  printf 'Generate an Automation Hub offline token at:\n  https://console.redhat.com/ansible/automation-hub/token\n'
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "https://console.redhat.com/ansible/automation-hub/token" >/dev/null 2>&1 \
      || printf 'WARNING: Could not open a browser; visit the URL above.\n' >&2
  elif command -v open >/dev/null 2>&1; then
    open "https://console.redhat.com/ansible/automation-hub/token" >/dev/null 2>&1 \
      || printf 'WARNING: Could not open a browser; visit the URL above.\n' >&2
  fi
  if ! { exec 9<"$AAP_DEMO_SECRET_PROMPT_DEVICE"; } 2>/dev/null; then
    _err "An interactive terminal is required to enter the Automation Hub token"
    return 1
  fi
  while true; do
    printf "Automation Hub offline token (hidden): " >>"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
    if ! IFS= read -r -s GALAXY_TOKEN <&9; then
      exec 9<&-
      unset GALAXY_TOKEN
      _err "Token input was cancelled; no new token was saved"
      return 1
    fi
    printf '\n' >>"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
    if [ -z "$GALAXY_TOKEN" ]; then
      _err "Token must not be empty; please try again"
      continue
    fi
    if galaxy_offline_token_status "$GALAXY_TOKEN"; then
      exec 9<&-
      aap_demo_vault_set "ah_offline_token" "$GALAXY_TOKEN" || return 2
      export GALAXY_TOKEN
      return 0
    else
      rc=$?
    fi
    unset GALAXY_TOKEN
    # Retry rejected credentials, not network/server errors that could reject a good token.
    if [ "$rc" -eq 2 ]; then
      exec 9<&-
      _err "Red Hat SSO is unavailable or returned an invalid response; no new token was saved"
      return 2
    fi
    _err "Red Hat SSO rejected the Automation Hub offline token (expired or revoked); please try again"
  done
}

protect_galaxy_credential_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    return 0
  fi
  if ! chmod 600 "$path" 2>/dev/null; then
    _err "Cannot restrict permissions on credential file: $path"
    return 1
  fi
}

detect_galaxy_credentials() {
  local token_status=0
  GALAXY_TOKEN_FILE="${GALAXY_TOKEN_FILE:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/galaxy-token}"
  PAH_CONFIG_FILE="${PAH_CONFIG_FILE:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/pah-config.yml}"

  GALAXY_TOKEN=$(aap_demo_vault_get "ah_offline_token") || token_status=$?
  [ "$token_status" -ne 2 ] || return 2
  # Detect console.redhat.com offline token
  if [ -z "$GALAXY_TOKEN" ] && [ -s "$GALAXY_TOKEN_FILE" ]; then
    protect_galaxy_credential_file "$GALAXY_TOKEN_FILE" || return 1
    GALAXY_TOKEN=$(cat "$GALAXY_TOKEN_FILE")
    if galaxy_offline_token_status "$GALAXY_TOKEN"; then
      if aap_demo_vault_set "ah_offline_token" "$GALAXY_TOKEN"; then
        rm -f "$GALAXY_TOKEN_FILE"
      else
        _err "Unable to migrate $GALAXY_TOKEN_FILE into encrypted credential storage"
        return 2
      fi
    else
      token_status=$?
      GALAXY_TOKEN=""
      _err "Unable to validate the legacy Automation Hub token; it was not saved"
      return "$token_status"
    fi
  fi
  export GALAXY_TOKEN

  # Detect PAH configuration
  if [ -f "$PAH_CONFIG_FILE" ]; then
    protect_galaxy_credential_file "$PAH_CONFIG_FILE" || return 1
    # Parse YAML for URL and authentication
    if command -v yq >/dev/null 2>&1; then
      PAH_URL=$(yq eval '.url' "$PAH_CONFIG_FILE" 2>/dev/null)
      PAH_TOKEN=$(yq eval '.token' "$PAH_CONFIG_FILE" 2>/dev/null)
      PAH_USER=$(yq eval '.username' "$PAH_CONFIG_FILE" 2>/dev/null)
      PAH_PASS=$(yq eval '.password' "$PAH_CONFIG_FILE" 2>/dev/null)
    else
      # Fallback: basic grep parsing
      PAH_URL=$(grep -E '^\s*url:' "$PAH_CONFIG_FILE" | sed 's/^[^:]*: *//' | tr -d '"' | tr -d "'")
      PAH_TOKEN=$(grep -E '^\s*token:' "$PAH_CONFIG_FILE" | sed 's/^[^:]*: *//' | tr -d '"' | tr -d "'")
      PAH_USER=$(grep -E '^\s*username:' "$PAH_CONFIG_FILE" | sed 's/^[^:]*: *//' | tr -d '"' | tr -d "'")
      PAH_PASS=$(grep -E '^\s*password:' "$PAH_CONFIG_FILE" | sed 's/^[^:]*: *//' | tr -d '"' | tr -d "'")
    fi

    local migrated=false
    if [ -n "${PAH_TOKEN:-}" ] && [ "$PAH_TOKEN" != "null" ]; then
      aap_demo_vault_set "aap_demo.pah.token" "$PAH_TOKEN" || return 1
      migrated=true
    fi
    if [ -n "${PAH_USER:-}" ] && [ "$PAH_USER" != "null" ]; then
      aap_demo_vault_set "aap_demo.pah.username" "$PAH_USER" || return 1
      migrated=true
    fi
    if [ -n "${PAH_PASS:-}" ] && [ "$PAH_PASS" != "null" ]; then
      aap_demo_vault_set "aap_demo.pah.password" "$PAH_PASS" || return 1
      migrated=true
    fi
    if [ "$migrated" = true ]; then
      python3 - "$PAH_CONFIG_FILE" <<'PY'
import os
import sys
import tempfile
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    data = yaml.safe_load(stream) or {}
for key in ("token", "username", "password"):
    data.pop(key, None)
directory = os.path.dirname(path) or "."
fd, temporary = tempfile.mkstemp(prefix=".pah-config.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        yaml.safe_dump(data, stream, default_flow_style=False, sort_keys=True)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
    fi
  fi
  PAH_TOKEN=$(aap_demo_vault_get "aap_demo.pah.token" 2>/dev/null || true)
  PAH_USER=$(aap_demo_vault_get "aap_demo.pah.username" 2>/dev/null || true)
  PAH_PASS=$(aap_demo_vault_get "aap_demo.pah.password" 2>/dev/null || true)
  export PAH_URL PAH_TOKEN PAH_USER PAH_PASS
}

configure_pah_remotes() {
  echo "Configuring Private Automation Hub remotes..."
  # Requires AAP 2.7+ (uses Pulp v3 API)

  if ! command -v jq >/dev/null 2>&1; then
    _err "jq is required for PAH remote configuration"
    echo "  Install: brew install jq (macOS) or sudo dnf install jq (RHEL/Fedora)"
    return 1
  fi

  # Detect credentials
  detect_galaxy_credentials || return 1

  # Get AAP route and admin password
  local aap_route
  aap_route=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
  if [ -z "$aap_route" ]; then
    _err "AAP route not found"
    return 1
  fi

  local admin_pass
  admin_pass=$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  if [ -z "$admin_pass" ]; then
    _err "Admin password not found"
    return 1
  fi

  local api_base="https://${aap_route}/api/galaxy/pulp/api/v3"
  # Build Basic auth header to avoid curl misparse when password contains ':'
  local auth_header
  auth_header="Authorization: Basic $(printf 'admin:%s' "${admin_pass}" | base64)"

  # Configure console.redhat.com remotes if token present
  if [ -n "$GALAXY_TOKEN" ]; then
    # Configure rh-certified remote
    printf "  Configuring rh-certified remote... "

    local remote_href
    remote_href=$(curl -sk --max-time 10 -H "${auth_header}" \
      "${api_base}/remotes/ansible/collection/?name=rh-certified" 2>/dev/null \
      | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

    if [ -n "$remote_href" ]; then
      # Update existing token
      curl -sk --max-time 10 -H "${auth_header}" \
        -X PATCH \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg token "${GALAXY_TOKEN}" '{token: $token}')" \
        "${api_base}${remote_href}" >/dev/null 2>&1
      echo "✓"
    else
      # Create rh-certified remote
      local create_result
      create_result=$(curl -sk --max-time 10 -H "${auth_header}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{
          \"name\": \"rh-certified\",
          \"url\": \"https://console.redhat.com/api/automation-hub/content/published/\",
          \"token\": \"${GALAXY_TOKEN}\",
          \"tls_validation\": true
        }" \
        "${api_base}/remotes/ansible/collection/" 2>/dev/null)

      remote_href=$(echo "$create_result" | python3 -c "import sys, json; print(json.loads(sys.stdin.read() or '{}').get('pulp_href', ''))" 2>/dev/null)

      if [ -n "$remote_href" ]; then
        echo "✓"

        # Link to rh-certified repository
        local repo_href
        repo_href=$(curl -sk --max-time 10 -H "${auth_header}" \
          "${api_base}/repositories/ansible/ansible/?name=rh-certified" 2>/dev/null \
          | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

        if [ -n "$repo_href" ]; then
          curl -sk --max-time 10 -H "${auth_header}" \
            -X PATCH \
            -H "Content-Type: application/json" \
            -d "{\"remote\": \"${remote_href}\"}" \
            "${api_base}${repo_href}" >/dev/null 2>&1
        fi
      fi
    fi

    # Trigger sync
    printf "  Syncing rh-certified... "
    local repo_href
    repo_href=$(curl -sk --max-time 10 -H "${auth_header}" \
      "${api_base}/repositories/ansible/ansible/?name=rh-certified" 2>/dev/null \
      | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

    if [ -n "$repo_href" ]; then
      curl -sk --max-time 10 -H "${auth_header}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d '{"mirror": false}' \
        "${api_base}${repo_href}sync/" >/dev/null 2>&1
      echo "✓ (background)"
    fi

    # Configure rh-validated remote
    printf "  Configuring rh-validated remote... "

    local validated_remote
    validated_remote=$(curl -sk --max-time 10 -H "${auth_header}" \
      "${api_base}/remotes/ansible/collection/?name=rh-validated" 2>/dev/null \
      | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

    if [ -z "$validated_remote" ]; then
      local create_result
      create_result=$(curl -sk --max-time 10 -H "${auth_header}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{
          \"name\": \"rh-validated\",
          \"url\": \"https://console.redhat.com/api/automation-hub/content/validated/\",
          \"token\": \"${GALAXY_TOKEN}\",
          \"tls_validation\": true
        }" \
        "${api_base}/remotes/ansible/collection/" 2>/dev/null)

      validated_remote=$(echo "$create_result" | python3 -c "import sys, json; print(json.loads(sys.stdin.read() or '{}').get('pulp_href', ''))" 2>/dev/null)
    else
      curl -sk --max-time 10 -H "${auth_header}" \
        -X PATCH \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg token "${GALAXY_TOKEN}" '{token: $token}')" \
        "${api_base}${validated_remote}" >/dev/null 2>&1
    fi

    if [ -n "$validated_remote" ]; then
      echo "✓"

      printf "  Linking validated remote to repository... "
      local validated_repo
      validated_repo=$(curl -sk --max-time 10 -H "${auth_header}" \
        "${api_base}/repositories/ansible/ansible/?name=validated" 2>/dev/null \
        | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

      if [ -n "$validated_repo" ]; then
        curl -sk --max-time 10 -H "${auth_header}" \
          -X PATCH \
          -H "Content-Type: application/json" \
          -d "{\"remote\": \"${validated_remote}\"}" \
          "${api_base}${validated_repo}" >/dev/null 2>&1
        echo "✓"

        printf "  Syncing validated... "
        curl -sk --max-time 10 -H "${auth_header}" \
          -X POST \
          -H "Content-Type: application/json" \
          -d '{"mirror": false}' \
          "${api_base}${validated_repo}sync/" >/dev/null 2>&1
        echo "✓ (background)"
      fi
    fi
  else
    printf "  %s▸%s No galaxy token found, skipping console.redhat.com remotes\n" "${_YELLOW}" "${_NC}"
  fi

  # Configure PAH remote if configured
  if [ -n "$PAH_URL" ] && [ -n "$PAH_TOKEN" ]; then
    printf "  Configuring Private Automation Hub remote... "

    local create_result
    create_result=$(curl -sk --max-time 10 -H "${auth_header}" \
      -X POST \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"external-pah\",
        \"url\": \"${PAH_URL}\",
        \"token\": \"${PAH_TOKEN}\",
        \"tls_validation\": true
      }" \
      "${api_base}/remotes/ansible/collection/" 2>&1)

    if echo "$create_result" | grep -q '"pulp_href"'; then
      echo "✓"
    else
      echo "⚠ (may already exist or invalid config)"
    fi
  fi

  echo "  ✓ PAH configuration complete"
}
