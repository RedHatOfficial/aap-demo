# shellcheck shell=bash

# =============================================================================
# fleet-aap.sh — Register/deregister fleet nodes in AAP via REST API
# =============================================================================

if [ -n "${_FLEET_AAP_LOADED:-}" ]; then return 0; fi
_FLEET_AAP_LOADED=1

FLEET_AAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../includes/secure-curl.sh
source "${FLEET_AAP_DIR}/../../includes/secure-curl.sh"

FLEET_DIR="${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet"

_FLEET_AAP_URL=""
_FLEET_AAP_PASSWORD=""
_FLEET_AAP_CURL_TLS=""

# -----------------------------------------------------------------------------
# AAP API connection
# -----------------------------------------------------------------------------

_fleet_aap_get_auth() {
  if [ -n "$_FLEET_AAP_URL" ] && [ -n "$_FLEET_AAP_PASSWORD" ]; then
    return 0
  fi

  local ns="${NAMESPACE:-aap-operator}"

  # Discover gateway URL
  local aap_name
  aap_name=$(kubectl get aap -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -z "$aap_name" ]; then
    _err "No AAP instance found in namespace $ns"
    return 1
  fi

  local gateway_host
  gateway_host=$(kubectl get route "$aap_name" -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [ -z "$gateway_host" ]; then
    gateway_host=$(kubectl get route -n "$ns" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  fi
  if [ -z "$gateway_host" ]; then
    _err "Could not find AAP gateway route"
    return 1
  fi
  _FLEET_AAP_URL="https://${gateway_host}"

  # Discover admin password
  local pw_secret
  pw_secret=$(kubectl get aap "$aap_name" -n "$ns" -o jsonpath='{.status.adminPasswordSecret}' 2>/dev/null || echo "")
  if [ -n "$pw_secret" ]; then
    _FLEET_AAP_PASSWORD=$(kubectl get secret "$pw_secret" -n "$ns" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  fi
  if [ -z "$_FLEET_AAP_PASSWORD" ]; then
    for secret_name in "${aap_name}-admin-password" aap-admin-password; do
      _FLEET_AAP_PASSWORD=$(kubectl get secret "$secret_name" -n "$ns" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
      [ -n "$_FLEET_AAP_PASSWORD" ] && break
    done
  fi
  if [ -z "$_FLEET_AAP_PASSWORD" ]; then
    _err "Could not retrieve AAP admin password"
    return 1
  fi

  # TLS handling
  local ca_path
  ca_path=$(get_ingress_ca_cert_path 2>/dev/null || echo "")
  if [ -n "$ca_path" ] && [ -f "$ca_path" ]; then
    _FLEET_AAP_CURL_TLS="--cacert ${ca_path}"
  else
    _FLEET_AAP_CURL_TLS="-k"
  fi

  return 0
}

_fleet_aap_api() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"

  local url="${_FLEET_AAP_URL}/api/controller/v2${endpoint}"
  local curl_args=(
    -s -S -f
    -X "$method"
    -H "Content-Type: application/json"
    -u "admin:${_FLEET_AAP_PASSWORD}"
  )

  # shellcheck disable=SC2206
  [ -n "$_FLEET_AAP_CURL_TLS" ] && curl_args+=($_FLEET_AAP_CURL_TLS)

  if [ -n "$body" ]; then
    printf '%s' "$body" | curl "${curl_args[@]}" --data-binary @- "$url" 2>/dev/null
    return
  fi

  curl "${curl_args[@]}" "$url" 2>/dev/null
}

_fleet_aap_has_valid_license() {
  local response
  response=$(_fleet_aap_api GET "/config/") || return 1
  if [ -z "$response" ] || ! python3 -m json.tool >/dev/null 2>&1 <<<"$response"; then
    _err "AAP controller API is not ready"
    return 2
  fi
  python3 -c '
import json
import sys
license_info = json.load(sys.stdin).get("license_info") or {}
valid = license_info.get("valid_key") is True
capacity = license_info.get("instance_count", license_info.get("quantity", 0))
raise SystemExit(0 if valid and int(capacity or 0) > 0 else 1)
' <<<"$response"
}

_fleet_aap_select_subscription_id() {
  local subscriptions="$1"
  local preferred_id="$2"
  SUBSCRIPTIONS="$subscriptions" \
    PREFERRED_ID="$preferred_id" python3 -c '
import json
import os
import sys

data = json.loads(os.environ["SUBSCRIPTIONS"])
if isinstance(data, dict) and data.get("error"):
    print(data["error"], file=sys.stderr)
    raise SystemExit(1)
rows = data if isinstance(data, list) else data.get("results", [])
matches = [row for row in rows if str(row.get("subscription_id", ""))]
by_id = {str(row["subscription_id"]): row for row in matches}
preferred = os.environ["PREFERRED_ID"]
if preferred and preferred in by_id:
    print(preferred)
elif matches:
    print(matches[0]["subscription_id"])
else:
    raise SystemExit(1)
'
}

_fleet_aap_subscription_name() {
  local subscriptions="$1"
  local subscription_id="$2"
  SUBSCRIPTIONS="$subscriptions" \
    SUBSCRIPTION_ID="$subscription_id" python3 -c '
import json
import os
data = json.loads(os.environ["SUBSCRIPTIONS"])
rows = data if isinstance(data, list) else data.get("results", [])
for row in rows:
    if str(row.get("subscription_id", "")) == os.environ["SUBSCRIPTION_ID"]:
        print(row.get("subscription_name") or row.get("product_name") or "Unnamed subscription")
        break
'
}

_fleet_aap_describe_subscription_schema() {
  local subscriptions="$1"
  SUBSCRIPTIONS="$subscriptions" python3 -c '
import json
import os
data = json.loads(os.environ["SUBSCRIPTIONS"])
rows = data if isinstance(data, list) else data.get("results", [])
keys = sorted({key for row in rows if isinstance(row, dict) for key in row})
fields = (chr(44) + chr(32)).join(keys) if keys else "none"
top_level = (chr(44) + chr(32)).join(sorted(data)) if isinstance(data, dict) else "array"
print(f"  Subscription response keys: {top_level}; rows: {len(rows)}; row fields: {fields}")
' || true
}

_fleet_aap_record_subscription_name() {
  local name="$1" target tmp
  [ -n "$name" ] || return 0
  mkdir -p "$FLEET_DIR"
  target="$FLEET_DIR/aap_subscription_name"
  tmp=$(mktemp "$FLEET_DIR/.aap_subscription_name.XXXXXX")
  printf '%s\n' "$name" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$target"
}

_fleet_aap_ensure_subscription() {
  local license_status
  if _fleet_aap_has_valid_license; then
    return 0
  else
    license_status=$?
  fi
  if [ "$license_status" -eq 2 ]; then
    echo "  Wait for AAP pods to become ready, then retry: aap-demo fleet register"
    return 1
  fi

  echo "AAP subscription is missing; attaching an entitled subscription..."
  fleet_redhat_ensure_cdn_credentials true || return 1
  fleet_redhat_ensure_account_number true || return 1

  local username password account_number preferred_id payload subscriptions
  username=$(aap_demo_vault_get "$FLEET_CDN_USERNAME_KEY") || return 1
  password=$(aap_demo_vault_get "$FLEET_CDN_PASSWORD_KEY") || return 1
  account_number=$(aap_demo_vault_get "$FLEET_REDHAT_ACCOUNT_NUMBER_KEY") || return 1
  preferred_id=$(aap_demo_vault_get "$FLEET_REDHAT_SUBSCRIPTION_ID_KEY" 2>/dev/null || true)
  payload=$(CDN_USERNAME="$username" CDN_PASSWORD="$password" python3 -c '
import json
import os
print(json.dumps({
    "subscriptions_username": os.environ["CDN_USERNAME"],
    "subscriptions_password": os.environ["CDN_PASSWORD"],
}))
')
  subscriptions=$(_fleet_aap_api POST "/config/subscriptions/" "$payload") || {
    unset username password payload
    _err "AAP could not contact the Red Hat subscription service"
    return 1
  }
  unset username password payload
  if [ -z "$subscriptions" ] || ! python3 -m json.tool >/dev/null 2>&1 <<<"$subscriptions"; then
    _err "AAP subscription API returned an invalid or empty response"
    return 1
  fi
  local subscription_error
  subscription_error=$(python3 -c '
import json
import sys
data = json.load(sys.stdin)
print(data.get("error") or data.get("detail") or "")
' <<<"$subscriptions" 2>/dev/null || true)
  if [ -n "$subscription_error" ]; then
    _err "AAP subscription lookup failed: $subscription_error"
    return 1
  fi

  local subscription_id subscription_name
  if ! subscription_id=$(_fleet_aap_select_subscription_id \
    "$subscriptions" "$preferred_id") \
    || [ -z "$subscription_id" ]; then
    _fleet_aap_describe_subscription_schema "$subscriptions"
    _err "No AAP subscription is available for Red Hat account ${account_number}"
    return 1
  fi
  subscription_name=$(_fleet_aap_subscription_name \
    "$subscriptions" "$subscription_id")

  aap_demo_vault_set "$FLEET_REDHAT_SUBSCRIPTION_ID_KEY" "$subscription_id" || return 1
  payload=$(SUBSCRIPTION_ID="$subscription_id" python3 -c '
import json
import os
print(json.dumps({"subscription_id": os.environ["SUBSCRIPTION_ID"]}))
')
  local attach_response
  attach_response=$(_fleet_aap_api POST "/config/attach/" "$payload") || {
    _err "AAP subscription attachment request failed"
    return 1
  }
  if ! python3 -c '
import json
import sys
data = json.load(sys.stdin)
raise SystemExit(0 if data.get("valid_key") is True else 1)
' <<<"$attach_response"; then
    local detail
    detail=$(python3 -c '
import json
import sys
data = json.load(sys.stdin)
print(data.get("error") or data.get("detail") or "unknown error")
' <<<"$attach_response" 2>/dev/null || echo "unknown error")
    _err "AAP subscription attachment failed: $detail"
    return 1
  fi
  _fleet_aap_record_subscription_name "$subscription_name" || return 1
  echo "  ✓ AAP subscription attached: ${subscription_name:-subscription ${subscription_id}}"
}

# -----------------------------------------------------------------------------
# Host gateway IP (how cluster reaches the host)
# -----------------------------------------------------------------------------

_fleet_aap_get_host_gateway_ip() {
  local cached="${FLEET_DIR}/host_gateway_ip"

  local gw_ip=""

  # CRC/vfkit uses a virtual gateway (192.168.127.1) that does NOT expose host
  # ports back to the VM. We need the host's real network IP that the CRC VM
  # can reach. Detect it by finding the host IP on the route to the CRC VM.
  local crc_vm_ip
  crc_vm_ip=$(ssh -p 2222 -i "$HOME/.crc/machines/crc/id_ed25519" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes \
    core@127.0.0.1 "hostname -I | awk '{print \$1}'" 2>/dev/null || echo "")

  # Use the host's IP on the default route interface
  if [[ "$OSTYPE" == darwin* ]]; then
    local def_iface
    def_iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    [ -n "$def_iface" ] && gw_ip=$(ifconfig "$def_iface" 2>/dev/null | awk '/inet /{print $2; exit}')
  else
    gw_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  fi

  if [ -z "$gw_ip" ]; then
    _err "Could not determine host IP reachable from CRC VM"
    echo "  Ensure the CRC VM is running and accessible"
    return 1
  fi

  mkdir -p "$FLEET_DIR"
  echo "$gw_ip" >"$cached"
  echo "$gw_ip"
}

# -----------------------------------------------------------------------------
# AAP resource management
# -----------------------------------------------------------------------------

_fleet_aap_get_org_id() {
  local resp
  resp=$(_fleet_aap_api GET "/organizations/?name=Default")
  echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['id'] if r.get('count',0)>0 else '')" 2>/dev/null
}

_fleet_aap_get_credential_type_id() {
  local resp
  resp=$(_fleet_aap_api GET "/credential_types/?name=Machine")
  echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['id'] if r.get('count',0)>0 else '')" 2>/dev/null
}

_fleet_aap_find_resource() {
  local endpoint="$1"
  local name="$2"
  local resp
  resp=$(_fleet_aap_api GET "${endpoint}?name=$(jq -rn --arg name "$name" '$name|@uri')") || return 1
  echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['id'] if r.get('count',0)>0 else '')" 2>/dev/null
}

_fleet_aap_create_credential() {
  local org_id="$1"
  local cred_type_id="$2"
  local ssh_key_path="$3"
  local cred_name="Fleet SSH Key"

  # Check if already exists
  local existing
  existing=$(_fleet_aap_find_resource "/credentials/" "$cred_name") || return 1

  # JSON-escape the SSH key (newlines → \n)
  local escaped_key
  escaped_key=$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$ssh_key_path") || return 1

  local body
  body=$(
    cat <<CRED_EOF
{
  "name": "${cred_name}",
  "organization": ${org_id},
  "credential_type": ${cred_type_id},
  "inputs": {
    "username": "ansible",
    "ssh_key_data": ${escaped_key}
  }
}
CRED_EOF
  )

  local resp
  if [ -n "$existing" ]; then
    _fleet_aap_api PATCH "/credentials/${existing}/" "$body" >/dev/null || return 1
    echo "  ✓ Updated credential '${cred_name}' (id: ${existing})" >&2
    echo "$existing"
    return 0
  fi
  resp=$(_fleet_aap_api POST "/credentials/" "$body")
  local cred_id
  cred_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

  if [ -n "$cred_id" ]; then
    echo "  ✓ Created credential '${cred_name}' (id: ${cred_id})" >&2
    echo "$cred_id"
  else
    _err "Failed to create credential"
    echo "$resp" >&2
    return 1
  fi
}

_fleet_aap_create_inventory() {
  local org_id="$1"
  local inv_name="Fleet"

  local existing
  existing=$(_fleet_aap_find_resource "/inventories/" "$inv_name")
  if [ -n "$existing" ]; then
    echo "  ✓ Inventory '${inv_name}' exists (id: ${existing})" >&2
    echo "$existing"
    return 0
  fi

  local body
  body=$(
    cat <<INV_EOF
{
  "name": "${inv_name}",
  "organization": ${org_id}
}
INV_EOF
  )

  local resp
  resp=$(_fleet_aap_api POST "/inventories/" "$body")
  local inv_id
  inv_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

  if [ -n "$inv_id" ]; then
    echo "  ✓ Created inventory '${inv_name}' (id: ${inv_id})" >&2
    echo "$inv_id"
  else
    _err "Failed to create inventory"
    echo "$resp" >&2
    return 1
  fi
}

_fleet_aap_create_host() {
  local inv_id="$1"
  local hostname="$2"
  local host_ip="$3"
  local port="$4"

  # Check if already exists
  local existing
  existing=$(_fleet_aap_find_resource "/inventories/${inv_id}/hosts/" "$hostname") || return 1

  local variables
  variables="ansible_host: ${host_ip}\nansible_port: ${port}\nansible_user: ansible\nansible_become: true"

  local body
  body=$(
    cat <<HOST_EOF
{
  "name": "${hostname}",
  "inventory": ${inv_id},
  "variables": "${variables}"
}
HOST_EOF
  )

  local resp
  if [ -n "$existing" ]; then
    _fleet_aap_api PATCH "/hosts/${existing}/" "$body" >/dev/null || return 1
    echo "  ✓ Updated host '${hostname}' (id: ${existing})"
    return 0
  fi
  resp=$(_fleet_aap_api POST "/hosts/" "$body")
  local host_id
  host_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

  if [ -n "$host_id" ]; then
    echo "  ✓ Created host '${hostname}' (id: ${host_id})"
  else
    _err "Failed to create host '${hostname}'"
    echo "$resp" >&2
    return 1
  fi
}

_fleet_aap_remove_stale_hosts() {
  local inv_id="$1"
  local expected_hosts=""

  for meta in "${FLEET_DIR}"/node-*/meta; do
    [ -f "$meta" ] || continue
    local hostname pid
    hostname=$(grep '^HOSTNAME=' "$meta" | cut -d= -f2)
    pid=$(grep '^PID=' "$meta" | cut -d= -f2)
    if [ -n "$hostname" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      expected_hosts+="${hostname}"$'\n'
    fi
  done

  local hosts_resp
  hosts_resp=$(_fleet_aap_api GET "/inventories/${inv_id}/hosts/?page_size=200")
  local stale_hosts
  if ! stale_hosts=$(EXPECTED_HOSTS="$expected_hosts" python3 -c '
import json
import os
import sys

expected = set(os.environ["EXPECTED_HOSTS"].splitlines())
response = json.load(sys.stdin)
for host in response.get("results", []):
    name = host.get("name", "")
    if name.startswith("aap-fleet-node-") and name not in expected:
        print("{}\t{}".format(host["id"], name))
' <<<"$hosts_resp"); then
    _err "Could not reconcile Fleet inventory hosts"
    return 1
  fi

  local host_id hostname
  while IFS=$'\t' read -r host_id hostname; do
    [ -n "$host_id" ] || continue
    _fleet_aap_api DELETE "/hosts/${host_id}/" >/dev/null
    echo "  ✓ Removed stale host '${hostname}'"
  done <<<"$stale_hosts"
}

_fleet_aap_run_ping() {
  local inv_id="$1"
  local cred_id="$2"

  echo "  Running ad-hoc ping..."

  local body
  body=$(
    cat <<PING_EOF
{
  "module_name": "ping",
  "credential": ${cred_id},
  "limit": "",
  "extra_vars": ""
}
PING_EOF
  )

  local resp
  resp=$(_fleet_aap_api POST "/inventories/${inv_id}/ad_hoc_commands/" "$body")
  local job_id
  job_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

  if [ -n "$job_id" ]; then
    echo "  ✓ Ad-hoc ping launched (job: ${job_id})"

    # Wait briefly for result
    local attempts=0
    while [ "$attempts" -lt 15 ]; do
      sleep 2
      local status
      status=$(_fleet_aap_api GET "/ad_hoc_commands/${job_id}/")
      local job_status
      job_status=$(echo "$status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)

      case "$job_status" in
        successful)
          echo "  ✓ Ping successful — all nodes reachable"
          return 0
          ;;
        failed)
          echo "  ⚠ Ping failed — some nodes may not be reachable yet"
          echo "    Check in AAP UI: Jobs → Ad Hoc Commands"
          return 1
          ;;
        error | canceled)
          echo "  ⚠ Ping ${job_status}"
          return 1
          ;;
      esac
      attempts=$((attempts + 1))
    done
    echo "  ⚠ Ping still running — check AAP UI for results"
    return 1
  else
    echo "  ⚠ Could not launch ad-hoc ping"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Public registration functions
# -----------------------------------------------------------------------------

fleet_register_aap() {
  echo ""
  echo "Registering fleet nodes in AAP..."

  if declare -F fleet_reconcile_running_access >/dev/null; then
    fleet_reconcile_running_access || return 1
  fi
  if declare -F fleet_reconcile_stack >/dev/null; then
    fleet_reconcile_stack || return 1
  fi
  _fleet_aap_get_auth || return 1
  _fleet_aap_ensure_subscription || return 1

  local org_id
  org_id=$(_fleet_aap_get_org_id)
  if [ -z "$org_id" ]; then
    _err "Could not find Default organization"
    return 1
  fi

  local cred_type_id
  cred_type_id=$(_fleet_aap_get_credential_type_id)
  if [ -z "$cred_type_id" ]; then
    _err "Could not find Machine credential type"
    return 1
  fi

  local host_gw_ip
  host_gw_ip=$(_fleet_aap_get_host_gateway_ip)
  if [ -z "$host_gw_ip" ]; then
    return 1
  fi
  echo "  Host gateway IP: ${host_gw_ip}"

  # Status messages go to stderr, IDs to stdout
  local cred_id
  cred_id=$(_fleet_aap_create_credential "$org_id" "$cred_type_id" "$(_fleet_ssh_private_key_path)")

  local inv_id
  inv_id=$(_fleet_aap_create_inventory "$org_id")

  if [ -z "$inv_id" ] || [ -z "$cred_id" ]; then
    _err "Failed to create AAP resources"
    return 1
  fi

  _fleet_aap_remove_stale_hosts "$inv_id" || return 1

  # Create hosts
  local registration_failed=false
  for meta in "${FLEET_DIR}"/node-*/meta; do
    [ -f "$meta" ] || continue
    local hostname port pid
    hostname=$(grep '^HOSTNAME=' "$meta" | cut -d= -f2)
    port=$(grep '^PORT=' "$meta" | cut -d= -f2)
    pid=$(grep '^PID=' "$meta" | cut -d= -f2)

    # Only register running nodes
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      if ! _fleet_aap_create_host "$inv_id" "$hostname" "$host_gw_ip" "$port"; then
        registration_failed=true
      fi
    fi
  done

  if [ "$registration_failed" = true ]; then
    _err "One or more Fleet nodes could not be registered in AAP"
    echo "  If AAP reports 'License is missing', attach a subscription and retry:"
    echo "  aap-demo fleet register"
    return 1
  fi

  # Run ad-hoc ping
  _fleet_aap_run_ping "$inv_id" "$cred_id" || return 1

  echo ""
  echo "✓ Fleet nodes registered in AAP"
  echo "  Inventory: Fleet"
  echo "  Credential: Fleet SSH Key"
  echo "  AAP UI: ${_FLEET_AAP_URL}"
}

fleet_node_deregister_host() {
  local hostname="$1"

  _fleet_aap_get_auth || return 1

  local host_id
  host_id=$(_fleet_aap_find_resource "/hosts/" "$hostname")
  if [ -n "$host_id" ]; then
    _fleet_aap_api DELETE "/hosts/${host_id}/" >/dev/null
    echo "  ✓ Deregistered host '${hostname}'"
  fi
}

fleet_deregister_aap() {
  _fleet_aap_get_auth 2>/dev/null || return 0

  echo "Removing AAP fleet resources..."

  # Remove all hosts from inventory
  local inv_id
  inv_id=$(_fleet_aap_find_resource "/inventories/" "Fleet")
  if [ -n "$inv_id" ]; then
    # Get all hosts in the inventory
    local hosts_resp
    hosts_resp=$(_fleet_aap_api GET "/inventories/${inv_id}/hosts/")
    local host_ids
    host_ids=$(echo "$hosts_resp" | python3 -c "
import sys, json
r = json.load(sys.stdin)
for h in r.get('results', []):
    print(h['id'])
" 2>/dev/null || true)

    for hid in $host_ids; do
      _fleet_aap_api DELETE "/hosts/${hid}/" >/dev/null 2>&1
    done

    _fleet_aap_api DELETE "/inventories/${inv_id}/" >/dev/null 2>&1
    echo "  ✓ Removed inventory 'Fleet'"
  fi

  # Remove credential
  local cred_id
  cred_id=$(_fleet_aap_find_resource "/credentials/" "Fleet SSH Key")
  if [ -n "$cred_id" ]; then
    _fleet_aap_api DELETE "/credentials/${cred_id}/" >/dev/null 2>&1
    echo "  ✓ Removed credential 'Fleet SSH Key'"
  fi

  # Clean cached gateway IP
  rm -f "${FLEET_DIR}/host_gateway_ip"
}
