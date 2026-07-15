#!/usr/bin/env bash
# =============================================================================
# galaxy-auth.sh — Galaxy / PAH credential detection, validation, and
#                  ansible.cfg generation for aap-demo
# =============================================================================
# Source this file; do not execute it directly.
# Requires: _RED, _GREEN, _YELLOW, _NC colour vars and _err() from caller.

if [ -n "${_GALAXY_AUTH_LOADED:-}" ]; then return 0; fi
_GALAXY_AUTH_LOADED=1

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

validate_galaxy_token() {
  if [ -z "$GALAXY_TOKEN" ]; then
    return 0 # Not configured, skip validation
  fi

  # Check token format (offline tokens are typically 1500+ chars)
  local token_len=${#GALAXY_TOKEN}
  if [ "$token_len" -lt 100 ]; then
    printf "${_RED}▸${_NC} Invalid galaxy token format (too short: $token_len chars)\n"
    echo ""
    echo "Quick setup:"
    echo "  aap-demo setup-pah      # Configure PAH remotes with token"
    echo ""
    echo "  1. Visit: https://console.redhat.com/ansible/automation-hub/token"
    echo "  2. Click 'Load token'"
    echo "  3. Copy Offline Token (~1500 characters)"
    echo "  4. Save: echo \"TOKEN\" > ~/.aap-demo/galaxy-token"
    echo ""
    echo "Documentation: docs/collection-authentication.md"
    return 1
  fi

  return 0
}

validate_pah_config() {
  if [ -z "$PAH_URL" ]; then
    return 0 # Not configured, skip validation
  fi

  # Check URL format
  if ! [[ "$PAH_URL" =~ ^https?:// ]]; then
    printf "${_RED}▸${_NC} Invalid PAH URL format: $PAH_URL\n"
    echo "  URL must start with http:// or https://"
    return 1
  fi

  # Check authentication method
  if [ -z "$PAH_TOKEN" ] && [ -z "$PAH_USER" ]; then
    printf "${_RED}▸${_NC} PAH config missing authentication\n"
    echo "  Provide either 'token' or 'username'/'password' in $PAH_CONFIG_FILE"
    return 1
  fi

  return 0
}

generate_ansible_cfg() {
  local cfg_file="${1:-ansible.cfg}"
  local galaxy_servers=""

  # Build galaxy_server_list based on available credentials
  if [ -n "$PAH_URL" ]; then
    galaxy_servers+="pah,"
  fi
  if [ -n "$GALAXY_TOKEN" ]; then
    galaxy_servers+="console,"
  fi
  galaxy_servers+="community"

  # Remove trailing comma
  galaxy_servers="${galaxy_servers%,}"

  # Generate ansible.cfg with [galaxy] section
  cat >"$cfg_file" <<'EOF'
[defaults]
roles_path = ./ansible/roles
inventory = ./ansible/inventory/localhost.yml
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 3600

EOF

  # Add galaxy configuration
  cat >>"$cfg_file" <<EOF
[galaxy]
server_list = ${galaxy_servers}

EOF

  # Append PAH server configuration
  if [ -n "$PAH_URL" ]; then
    cat >>"$cfg_file" <<EOF
[galaxy_server.pah]
url = ${PAH_URL}
EOF

    if [ -n "$PAH_TOKEN" ]; then
      cat >>"$cfg_file" <<EOF
token = ${PAH_TOKEN}

EOF
    elif [ -n "$PAH_USER" ] && [ -n "$PAH_PASS" ]; then
      cat >>"$cfg_file" <<EOF
username = ${PAH_USER}
password = ${PAH_PASS}

EOF
    fi
  fi

  # Append console.redhat.com server configuration
  if [ -n "$GALAXY_TOKEN" ]; then
    cat >>"$cfg_file" <<EOF
[galaxy_server.console]
url = https://console.redhat.com/api/automation-hub/content/published/
token = ${GALAXY_TOKEN}

EOF
  fi

  # Append community galaxy server
  cat >>"$cfg_file" <<'EOF'
[galaxy_server.community]
url = https://galaxy.ansible.com/

EOF

  # Secure file permissions and warn about plaintext tokens
  chmod 600 "$cfg_file"
  if [ -n "$GALAXY_TOKEN" ] || [ -n "$PAH_TOKEN" ] || [ -n "$PAH_PASS" ]; then
    printf "${_YELLOW}▸${_NC} Warning: Tokens stored in plaintext in $cfg_file\n"
    printf "  Do not commit this file. Consider using ANSIBLE_GALAXY_SERVER_*_TOKEN env vars instead.\n"
  fi

  printf "${_GREEN}▸${_NC} Generated ansible.cfg with galaxy servers: $galaxy_servers\n"
}

install_collections() {
  local requirements_file="${1:-config/requirements.yml}"

  if [ "$SKIP_COLLECTIONS" = "true" ]; then
    printf "${_YELLOW}▸${_NC} Skipping collection installation (SKIP_COLLECTIONS=true)\n"
    return 0
  fi

  if [ ! -f "$requirements_file" ]; then
    printf "${_YELLOW}▸${_NC} No $requirements_file found, skipping collection installation\n"
    return 0
  fi

  local galaxy_opts=()
  if [ "${GALAXY_IGNORE_CERTS:-false}" = "true" ]; then
    galaxy_opts+=(--ignore-certs)
    printf "${_YELLOW}▸${_NC} SSL cert verification disabled (GALAXY_IGNORE_CERTS=true)\n"
  fi

  # On macOS, Python's bundled certs often miss corporate/system CAs.
  # /etc/ssl/cert.pem is the Keychain-sourced bundle — point requests at it.
  local ssl_env=()
  if [[ "$OSTYPE" == "darwin"* ]] && [ -f /etc/ssl/cert.pem ] && [ -z "${SSL_CERT_FILE:-}" ]; then
    ssl_env=(SSL_CERT_FILE=/etc/ssl/cert.pem REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem)
  fi

  echo "Installing collections from $requirements_file..."
  if env "${ssl_env[@]}" ansible-galaxy collection install -r "$requirements_file" "${galaxy_opts[@]}" 2>&1; then
    echo "  ✓ Collections installed successfully"
    return 0
  else
    _err "Failed to install collections"
    echo "  Check authentication to galaxy servers or run with SKIP_COLLECTIONS=true"
    echo "  Token setup: https://console.redhat.com/ansible/automation-hub/token"
    echo "  SSL errors: set GALAXY_IGNORE_CERTS=true to skip cert verification"
    return 1
  fi
}

configure_pah_remotes() {
  echo "Configuring Private Automation Hub remotes..."
  # Requires AAP 2.7+ (uses Pulp v3 API)

  # Check jq availability

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

  # Configure console.redhat.com remotes if token present
  if [ -n "$GALAXY_TOKEN" ]; then
    # Configure rh-certified remote
    printf "  Configuring rh-certified remote... "

    local remote_href
    remote_href=$(curl -sk --max-time 10 -u "admin:${admin_pass}" \
      "${api_base}/remotes/ansible/collection/?name=rh-certified" 2>/dev/null \
      | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

    if [ -n "$remote_href" ]; then
      # Update existing token
      curl -sk --max-time 10 -u "admin:${admin_pass}" \
        -X PATCH \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg token "${GALAXY_TOKEN}" '{token: $token}')" \
        "${api_base}${remote_href}" >/dev/null 2>&1
      echo "✓"
    else
      # Create rh-certified remote
      local create_result
      create_result=$(curl -sk --max-time 10 -u "admin:${admin_pass}" \
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
        repo_href=$(curl -sk --max-time 10 -u "admin:${admin_pass}" \
          "${api_base}/repositories/ansible/ansible/?name=rh-certified" 2>/dev/null \
          | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

        if [ -n "$repo_href" ]; then
          curl -sk --max-time 10 -u "admin:${admin_pass}" \
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
    repo_href=$(curl -sk --max-time 10 -u "admin:${admin_pass}" \
      "${api_base}/repositories/ansible/ansible/?name=rh-certified" 2>/dev/null \
      | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

    if [ -n "$repo_href" ]; then
      curl -sk --max-time 10 -u "admin:${admin_pass}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d '{"mirror": false}' \
        "${api_base}${repo_href}sync/" >/dev/null 2>&1
      echo "✓ (background)"
    fi

    # Create and configure rh-validated remote
    printf "  Configuring rh-validated remote... "

    # Check if rh-validated remote exists
    local validated_remote
    validated_remote=$(curl -sk --max-time 10 -u "admin:${admin_pass}" \
      "${api_base}/remotes/ansible/collection/?name=rh-validated" 2>/dev/null \
      | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

    if [ -z "$validated_remote" ]; then
      # Create rh-validated remote
      local create_result
      create_result=$(curl -sk --max-time 10 -u "admin:${admin_pass}" \
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
      # Update existing remote token
      curl -sk --max-time 10 -u "admin:${admin_pass}" \
        -X PATCH \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg token "${GALAXY_TOKEN}" '{token: $token}')" \
        "${api_base}${validated_remote}" >/dev/null 2>&1
    fi

    if [ -n "$validated_remote" ]; then
      echo "✓"

      # Link remote to validated repository
      printf "  Linking validated remote to repository... "
      local validated_repo
      validated_repo=$(curl -sk --max-time 10 -u "admin:${admin_pass}" \
        "${api_base}/repositories/ansible/ansible/?name=validated" 2>/dev/null \
        | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

      if [ -n "$validated_repo" ]; then
        curl -sk --max-time 10 -u "admin:${admin_pass}" \
          -X PATCH \
          -H "Content-Type: application/json" \
          -d "{\"remote\": \"${validated_remote}\"}" \
          "${api_base}${validated_repo}" >/dev/null 2>&1
        echo "✓"

        # Trigger sync
        printf "  Syncing validated... "
        curl -sk --max-time 10 -u "admin:${admin_pass}" \
          -X POST \
          -H "Content-Type: application/json" \
          -d '{"mirror": false}' \
          "${api_base}${validated_repo}sync/" >/dev/null 2>&1
        echo "✓ (background)"
      fi
    fi
  else
    printf "  ${_YELLOW}▸${_NC} No galaxy token found, skipping console.redhat.com remotes\n"
  fi

  # Configure PAH remote if configured
  if [ -n "$PAH_URL" ] && [ -n "$PAH_TOKEN" ]; then
    printf "  Configuring Private Automation Hub remote... "

    # Create PAH remote
    local create_result
    create_result=$(curl -sk --max-time 10 -u "admin:${admin_pass}" \
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
