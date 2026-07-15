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

detect_galaxy_credentials() {
  # Detect console.redhat.com offline token
  if [ -f "$GALAXY_TOKEN_FILE" ]; then
    GALAXY_TOKEN=$(cat "$GALAXY_TOKEN_FILE")
    export GALAXY_TOKEN
  fi

  # Detect PAH configuration
  if [ -f "$PAH_CONFIG_FILE" ]; then
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

    export PAH_URL PAH_TOKEN PAH_USER PAH_PASS
  fi
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
  detect_galaxy_credentials

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
