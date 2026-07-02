#!/usr/bin/env bash
# =============================================================================
# seed-nodes-aap.sh — Register/deregister seed nodes in AAP via REST API
# =============================================================================

if [ -n "${_SEED_NODES_AAP_LOADED:-}" ]; then return 0; fi
_SEED_NODES_AAP_LOADED=1

SEED_NODES_DIR="${HOME}/.aap-demo/nodes"

_SEED_AAP_URL=""
_SEED_AAP_PASSWORD=""
_SEED_AAP_CURL_TLS=""

# -----------------------------------------------------------------------------
# AAP API connection
# -----------------------------------------------------------------------------

_seed_aap_get_auth() {
  if [ -n "$_SEED_AAP_URL" ] && [ -n "$_SEED_AAP_PASSWORD" ]; then
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
  _SEED_AAP_URL="https://${gateway_host}"

  # Discover admin password
  local pw_secret
  pw_secret=$(kubectl get aap "$aap_name" -n "$ns" -o jsonpath='{.status.adminPasswordSecret}' 2>/dev/null || echo "")
  if [ -n "$pw_secret" ]; then
    _SEED_AAP_PASSWORD=$(kubectl get secret "$pw_secret" -n "$ns" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  fi
  if [ -z "$_SEED_AAP_PASSWORD" ]; then
    for secret_name in "${aap_name}-admin-password" aap-admin-password; do
      _SEED_AAP_PASSWORD=$(kubectl get secret "$secret_name" -n "$ns" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
      [ -n "$_SEED_AAP_PASSWORD" ] && break
    done
  fi
  if [ -z "$_SEED_AAP_PASSWORD" ]; then
    _err "Could not retrieve AAP admin password"
    return 1
  fi

  # TLS handling
  local ca_path
  ca_path=$(get_ingress_ca_cert_path 2>/dev/null || echo "")
  if [ -n "$ca_path" ] && [ -f "$ca_path" ]; then
    _SEED_AAP_CURL_TLS="--cacert ${ca_path}"
  else
    _SEED_AAP_CURL_TLS="-k"
  fi

  return 0
}

_seed_aap_api() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"

  local url="${_SEED_AAP_URL}/api/controller/v2${endpoint}"
  local curl_args=(
    -s -S
    -X "$method"
    -H "Content-Type: application/json"
    -u "admin:${_SEED_AAP_PASSWORD}"
  )

  # shellcheck disable=SC2206
  [ -n "$_SEED_AAP_CURL_TLS" ] && curl_args+=($_SEED_AAP_CURL_TLS)

  if [ -n "$body" ]; then
    curl_args+=(-d "$body")
  fi

  curl "${curl_args[@]}" "$url" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Host gateway IP (how cluster reaches the host)
# -----------------------------------------------------------------------------

_seed_aap_get_host_gateway_ip() {
  local cached="${SEED_NODES_DIR}/host_gateway_ip"
  if [ -f "$cached" ]; then
    cat "$cached"
    return 0
  fi

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

  mkdir -p "$SEED_NODES_DIR"
  echo "$gw_ip" >"$cached"
  echo "$gw_ip"
}

# -----------------------------------------------------------------------------
# AAP resource management
# -----------------------------------------------------------------------------

_seed_aap_get_org_id() {
  local resp
  resp=$(_seed_aap_api GET "/organizations/?name=Default")
  echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['id'] if r.get('count',0)>0 else '')" 2>/dev/null
}

_seed_aap_get_credential_type_id() {
  local resp
  resp=$(_seed_aap_api GET "/credential_types/?name=Machine")
  echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['id'] if r.get('count',0)>0 else '')" 2>/dev/null
}

_seed_aap_find_resource() {
  local endpoint="$1"
  local name="$2"
  local resp
  resp=$(_seed_aap_api GET "${endpoint}?name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${name}'))")")
  echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['id'] if r.get('count',0)>0 else '')" 2>/dev/null
}

_seed_aap_create_credential() {
  local org_id="$1"
  local cred_type_id="$2"
  local ssh_key_path="$3"
  local cred_name="Seed Nodes SSH Key"

  # Check if already exists
  local existing
  existing=$(_seed_aap_find_resource "/credentials/" "$cred_name")
  if [ -n "$existing" ]; then
    echo "  ✓ Credential '${cred_name}' exists (id: ${existing})" >&2
    echo "$existing"
    return 0
  fi

  local ssh_key_data
  ssh_key_data=$(cat "$ssh_key_path")

  # JSON-escape the SSH key (newlines → \n)
  local escaped_key
  escaped_key=$(python3 -c "import json; print(json.dumps(open('${ssh_key_path}').read()))")

  local body
  body=$(cat <<CRED_EOF
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
  resp=$(_seed_aap_api POST "/credentials/" "$body")
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

_seed_aap_create_inventory() {
  local org_id="$1"
  local inv_name="Seed Nodes"

  local existing
  existing=$(_seed_aap_find_resource "/inventories/" "$inv_name")
  if [ -n "$existing" ]; then
    echo "  ✓ Inventory '${inv_name}' exists (id: ${existing})" >&2
    echo "$existing"
    return 0
  fi

  local body
  body=$(cat <<INV_EOF
{
  "name": "${inv_name}",
  "organization": ${org_id}
}
INV_EOF
)

  local resp
  resp=$(_seed_aap_api POST "/inventories/" "$body")
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

_seed_aap_create_host() {
  local inv_id="$1"
  local hostname="$2"
  local host_ip="$3"
  local port="$4"

  # Check if already exists
  local existing
  existing=$(_seed_aap_find_resource "/hosts/" "$hostname")
  if [ -n "$existing" ]; then
    echo "  ✓ Host '${hostname}' exists (id: ${existing})"
    return 0
  fi

  local variables
  variables="ansible_host: ${host_ip}\nansible_port: ${port}\nansible_user: ansible"

  local body
  body=$(cat <<HOST_EOF
{
  "name": "${hostname}",
  "inventory": ${inv_id},
  "variables": "${variables}"
}
HOST_EOF
)

  local resp
  resp=$(_seed_aap_api POST "/hosts/" "$body")
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

_seed_aap_run_ping() {
  local inv_id="$1"
  local cred_id="$2"

  echo "  Running ad-hoc ping..."

  local body
  body=$(cat <<PING_EOF
{
  "module_name": "ping",
  "credential": ${cred_id},
  "limit": "",
  "extra_vars": ""
}
PING_EOF
)

  local resp
  resp=$(_seed_aap_api POST "/inventories/${inv_id}/ad_hoc_commands/" "$body")
  local job_id
  job_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

  if [ -n "$job_id" ]; then
    echo "  ✓ Ad-hoc ping launched (job: ${job_id})"

    # Wait briefly for result
    local attempts=0
    while [ "$attempts" -lt 15 ]; do
      sleep 2
      local status
      status=$(_seed_aap_api GET "/ad_hoc_commands/${job_id}/")
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
          return 0
          ;;
        error | canceled)
          echo "  ⚠ Ping ${job_status}"
          return 0
          ;;
      esac
      attempts=$((attempts + 1))
    done
    echo "  ⚠ Ping still running — check AAP UI for results"
  else
    echo "  ⚠ Could not launch ad-hoc ping"
  fi
}

# -----------------------------------------------------------------------------
# Public registration functions
# -----------------------------------------------------------------------------

seed_nodes_register_aap() {
  echo ""
  echo "Registering seed nodes in AAP..."

  _seed_aap_get_auth || return 1

  local org_id
  org_id=$(_seed_aap_get_org_id)
  if [ -z "$org_id" ]; then
    _err "Could not find Default organization"
    return 1
  fi

  local cred_type_id
  cred_type_id=$(_seed_aap_get_credential_type_id)
  if [ -z "$cred_type_id" ]; then
    _err "Could not find Machine credential type"
    return 1
  fi

  local host_gw_ip
  host_gw_ip=$(_seed_aap_get_host_gateway_ip)
  if [ -z "$host_gw_ip" ]; then
    return 1
  fi
  echo "  Host gateway IP: ${host_gw_ip}"

  # Status messages go to stderr, IDs to stdout
  local cred_id
  cred_id=$(_seed_aap_create_credential "$org_id" "$cred_type_id" "$(_seed_ssh_private_key_path)")

  local inv_id
  inv_id=$(_seed_aap_create_inventory "$org_id")

  if [ -z "$inv_id" ] || [ -z "$cred_id" ]; then
    _err "Failed to create AAP resources"
    return 1
  fi

  # Create hosts
  for meta in "${SEED_NODES_DIR}"/node-*/meta; do
    [ -f "$meta" ] || continue
    local hostname port pid
    hostname=$(grep '^HOSTNAME=' "$meta" | cut -d= -f2)
    port=$(grep '^PORT=' "$meta" | cut -d= -f2)
    pid=$(grep '^PID=' "$meta" | cut -d= -f2)

    # Only register running nodes
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      _seed_aap_create_host "$inv_id" "$hostname" "$host_gw_ip" "$port"
    fi
  done

  # Run ad-hoc ping
  _seed_aap_run_ping "$inv_id" "$cred_id"

  echo ""
  echo "✓ Seed nodes registered in AAP"
  echo "  Inventory: Seed Nodes"
  echo "  Credential: Seed Nodes SSH Key"
  echo "  AAP UI: ${_SEED_AAP_URL}"
}

seed_node_deregister_host() {
  local hostname="$1"

  _seed_aap_get_auth || return 1

  local host_id
  host_id=$(_seed_aap_find_resource "/hosts/" "$hostname")
  if [ -n "$host_id" ]; then
    _seed_aap_api DELETE "/hosts/${host_id}/" >/dev/null
    echo "  ✓ Deregistered host '${hostname}'"
  fi
}

seed_nodes_deregister_aap() {
  _seed_aap_get_auth 2>/dev/null || return 0

  echo "Removing AAP seed node resources..."

  # Remove all hosts from inventory
  local inv_id
  inv_id=$(_seed_aap_find_resource "/inventories/" "Seed Nodes")
  if [ -n "$inv_id" ]; then
    # Get all hosts in the inventory
    local hosts_resp
    hosts_resp=$(_seed_aap_api GET "/inventories/${inv_id}/hosts/")
    local host_ids
    host_ids=$(echo "$hosts_resp" | python3 -c "
import sys, json
r = json.load(sys.stdin)
for h in r.get('results', []):
    print(h['id'])
" 2>/dev/null || true)

    for hid in $host_ids; do
      _seed_aap_api DELETE "/hosts/${hid}/" >/dev/null 2>&1
    done

    _seed_aap_api DELETE "/inventories/${inv_id}/" >/dev/null 2>&1
    echo "  ✓ Removed inventory 'Seed Nodes'"
  fi

  # Remove credential
  local cred_id
  cred_id=$(_seed_aap_find_resource "/credentials/" "Seed Nodes SSH Key")
  if [ -n "$cred_id" ]; then
    _seed_aap_api DELETE "/credentials/${cred_id}/" >/dev/null 2>&1
    echo "  ✓ Removed credential 'Seed Nodes SSH Key'"
  fi

  # Clean cached gateway IP
  rm -f "${SEED_NODES_DIR}/host_gateway_ip"
}
