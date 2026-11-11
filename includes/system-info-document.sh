# shellcheck shell=bash

if [ -n "${_AAP_DEMO_SYSTEM_INFO_DOCUMENT_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_SYSTEM_INFO_DOCUMENT_LOADED=1

_aap_demo_system_info_routes_markdown() {
  local inventory="$1"
  echo "| Namespace | Route | URL | Resolved IPv4 | Service | Target port | TLS | Admitted |"
  echo "|---|---|---|---:|---|---:|---|---|"
  if [ "$(jq '.routes | length' "$inventory")" -eq 0 ]; then
    echo "| - | - | No application routes found | - | - | - | - | - |"
    return
  fi
  jq -r '
    .routes[]
    | "| \(.namespace) | \(.name) | \(.url) | \(.resolved_ipv4 // "-") | \(.service) | \(.target_port // "-") | \(.tls) | \(.admitted) |"
  ' "$inventory"
}

_aap_demo_system_info_credentials_markdown() {
  local inventory="$1"
  local credential component namespace username secret password
  if [ "$(jq '.credentials | length' "$inventory")" -eq 0 ]; then
    echo "_No application administrator credentials found._"
    return
  fi
  while IFS= read -r credential; do
    component=$(jq -r '.component' <<<"$credential")
    namespace=$(jq -r '.namespace' <<<"$credential")
    username=$(jq -r '.username' <<<"$credential")
    secret=$(jq -r '.secret_name' <<<"$credential")
    password=$(jq -r '.password // empty' <<<"$credential")
    echo "### $component: $namespace"
    echo ""
    echo "- Username: \`$username\`"
    echo "- Kubernetes Secret: \`$secret\`"
    if [ -n "$password" ]; then
      echo "- Password:"
      # shellcheck disable=SC2016
      printf '\n```text\n%s\n```\n\n' "$password"
    else
      echo "- Password: omitted"
      echo ""
    fi
  done < <(jq -c '.credentials[]' "$inventory")
}

_aap_demo_system_info_api_keys_markdown() {
  local inventory="$1"
  local provider base_url model api_key note
  provider=$(jq -r '.api_keys.ao_llm.provider' "$inventory")
  base_url=$(jq -r '.api_keys.ao_llm.base_url // empty' "$inventory")
  model=$(jq -r '.api_keys.ao_llm.model // empty' "$inventory")
  api_key=$(jq -r '.api_keys.ao_llm.api_key // empty' "$inventory")
  note=$(jq -r '.api_keys.aap_mcp.note' "$inventory")
  echo "- AO LLM provider: \`$provider\`"
  [ -z "$base_url" ] || echo "- AO LLM base URL: \`$base_url\`"
  [ -z "$model" ] || echo "- AO LLM model: \`$model\`"
  if [ -n "$api_key" ]; then
    echo "- AO LLM API key:"
    # shellcheck disable=SC2016
    printf '\n```text\n%s\n```\n\n' "$api_key"
  elif [ "$provider" = external ]; then
    echo "- AO LLM API key: omitted or unavailable"
  else
    echo "- AO LLM API key: not required"
  fi
  echo "- AAP MCP OAuth token: $note"
}

_aap_demo_system_info_services_markdown() {
  local inventory="$1"
  echo "| Namespace | Service | Type | Cluster IP | External IPs | Ports |"
  echo "|---|---|---|---:|---|---|"
  if [ "$(jq '.services | length' "$inventory")" -eq 0 ]; then
    echo "| - | No application services found | - | - | - | - |"
    return
  fi
  jq -r '
    .services[]
    | (
        [.ports[]
          | "\(.port)/\(.protocol) -> \(.target_port)"
            + (if .node_port then " (node \(.node_port))" else "" end)
        ]
        | join(", ")
      ) as $ports
    | "| \(.namespace) | \(.name) | \(.type) | \(.cluster_ip // "-") | \(.external_ips | if length == 0 then "-" else join(", ") end) | \($ports) |"
  ' "$inventory"
}

_aap_demo_system_info_pods_markdown() {
  local inventory="$1"
  echo "| Namespace | Pod | Phase | Ready | Restarts | Pod IP | Node |"
  echo "|---|---|---|---:|---:|---:|---|"
  if [ "$(jq '.pods | length' "$inventory")" -eq 0 ]; then
    echo "| - | No application pods found | - | - | - | - | - |"
    return
  fi
  jq -r '
    .pods[]
    | "| \(.namespace) | \(.name) | \(.phase) | \(.ready_containers)/\(.total_containers) | \(.restarts) | \(.pod_ip // "-") | \(.node // "-") |"
  ' "$inventory"
}

_aap_demo_system_info_namespaces_markdown() {
  local inventory="$1"
  echo "| Namespace | Running pods | Total pods | Ready |"
  echo "|---|---:|---:|---|"
  if [ "$(jq '.namespaces | length' "$inventory")" -eq 0 ]; then
    echo "| - | 0 | 0 | false |"
    return
  fi
  jq -r '
    .namespaces[]
    | "| \(.name) | \(.running_pods) | \(.total_pods) | \(.ready) |"
  ' "$inventory"
}

_aap_demo_system_info_ingress_markdown() {
  local inventory="$1"
  if jq -e '.ingress.service != null' "$inventory" &>/dev/null; then
    jq -r '
      "- Router service: `\(.ingress.service.name)`\n"
      + "- Cluster IP: `\(.ingress.service.cluster_ip // "unavailable")`\n"
      + "- External IPs: `\(.ingress.service.external_ips | if length == 0 then "none" else join(", ") end)`\n"
      + "- Ports: `\([.ingress.service.ports[] | "\(.port)/\(.protocol)" + (if .node_port then " -> node \(.node_port)" else "" end)] | join(", "))`\n"
      + "- Backends: `\([.ingress.endpoints[] | "\(.ip):\(.port)/\(.protocol)"] | if length == 0 then "none" else join(", ") end)`"
    ' "$inventory"
  else
    echo "_Ingress router information unavailable._"
  fi
}

_aap_demo_render_system_info_markdown() {
  local inventory="$1"
  local secret_mode
  secret_mode=$(jq -r '.secret_mode' "$inventory")
  cat <<EOF
# aap-demo Local Environment

> **Generated local-development file.**
> Secret mode: \`${secret_mode}\`.
> Registry pull secrets, Kubernetes client private keys, and unrelated Secret resources are intentionally excluded.

Generated: \`$(jq -r '.generated_at' "$inventory")\`

## Environment

- aap-demo version: \`$(jq -r '.tool.version' "$inventory")\`
- Source: \`$(jq -r '.tool.source' "$inventory")\`
- Branch: \`$(jq -r '.tool.branch' "$inventory")\`
- Infrastructure: \`$(jq -r '.cluster.infrastructure' "$inventory")\`
- Cluster: \`$(jq -r '.cluster.name // "unavailable"' "$inventory")\`
- Cluster state: \`$(jq -r '.cluster.state' "$inventory")\`
- Kubernetes context: \`$(jq -r '.cluster.context' "$inventory")\`
- Kubernetes version: \`$(jq -r '.cluster.kubernetes_version' "$inventory")\`
- Kubeconfig: \`$(jq -r '.cluster.kubeconfig' "$inventory")\`
- Host OS: \`$(jq -r '.host.os' "$inventory")\`
- Host architecture: \`$(jq -r '.host.architecture' "$inventory")\`
- AAP subscription: \`$(jq -r '.host.aap_subscription // "Not attached"' "$inventory")\`
- Enabled add-ons: \`$(jq -r '.addons | if length == 0 then "none" else join(", ") end' "$inventory")\`

## VM

- Guest OS: \`$(jq -r '.cluster.vm.guest_os // "unavailable"' "$inventory")\`
- OpenShift: \`$(jq -r '.cluster.vm.openshift_version // "unavailable"' "$inventory")\`
- CPUs: \`$(jq -r '.cluster.vm.cpus // "unavailable"' "$inventory")\`
- Memory: \`$(jq -r 'if .cluster.vm.memory then "\(.cluster.vm.memory.used) / \(.cluster.vm.memory.total) (\(.cluster.vm.memory.available) available)" else "unavailable" end' "$inventory")\`
- Load: \`$(jq -r '.cluster.vm.load // "unavailable"' "$inventory")\`
- Disk: \`$(jq -r '.cluster.vm.disk // "unavailable"' "$inventory")\`

## Storage Capacity Planning

These values are conservative planning estimates, not exact requirements.

- Actual VM disk: \`$(jq -r 'if .storage.capacity_planning.actual_vm_disk_gib then "\(.storage.capacity_planning.actual_vm_used_gib) GiB used / \(.storage.capacity_planning.actual_vm_disk_gib) GiB, \(.storage.capacity_planning.actual_vm_free_gib) GiB free" else "unavailable" end' "$inventory")\`
- Configured CRC disk: \`$(jq -r 'if .storage.capacity_planning.configured_crc_disk_gib then "\(.storage.capacity_planning.configured_crc_disk_gib) GiB" else "adaptive / not explicitly set" end' "$inventory")\`
- Recommended for enabled add-ons: \`$(jq -r '"\(.storage.capacity_planning.recommended_vm_disk_gib) GiB"' "$inventory")\`
- Host-only estimate: \`$(jq -r '"\(.storage.capacity_planning.host_only_gib) GiB"' "$inventory")\`
- Needs rebuild for recommendation: \`$(jq -r '.storage.capacity_planning.needs_rebuild' "$inventory")\`
- Config not applied to existing VM: \`$(jq -r '.storage.capacity_planning.configured_not_applied' "$inventory")\`

CRC disk settings apply only at VM creation. A larger setting requires a destructive
rebuild; aap-demo never resizes or rebuilds automatically.

## Namespace Health

$(_aap_demo_system_info_namespaces_markdown "$inventory")

## URLs and Routes

$(_aap_demo_system_info_routes_markdown "$inventory")

## Fleet SSH Access

Fleet guests use isolated QEMU networks. Use the host address and unique
forwarded SSH port, not the shared guest address, from this host.

$(jq -r '
  (.fleet // [])[] |
  "- \(.hostname): `ssh -p \(.ssh_port) \(.username)@\(.ssh_host)`; guest IP: `\(.guest_ip // "unknown")`; state: \(.state)" +
  (if .password != null then "\n  Password: `" + .password + "`" else "\n  Password: omitted" end)
' "$inventory")

### Common API paths

- AAP Gateway API: \`/api/gateway/v1/\`
- Automation Controller API: \`/api/controller/v2/\`
- Event-Driven Ansible API: \`/api/eda/v1/\`
- Private Automation Hub API: \`/api/galaxy/\`
- MCP endpoint: \`/mcp\`

## Usernames and Passwords

$(_aap_demo_system_info_credentials_markdown "$inventory")

### CRC SSH Access

- crc_ip: \`$(jq -r '.cluster.crc_ip // "unavailable"' "$inventory")\`
- SSH: \`aap-demo ssh\`
- Forwarded endpoint: \`core@127.0.0.1:2222\`
- SSH identity file: \`$(jq -r '.cluster.ssh.ssh_key // "unavailable"' "$inventory")\`

The CRC IP may be internal to user-mode networking. From this host, use
the forwarded endpoint with the identity file, or use \`aap-demo ssh\`.
Private key contents are never included.

## API Keys and Tokens

$(_aap_demo_system_info_api_keys_markdown "$inventory")

## Service IP Addresses and Ports

ClusterIP addresses are reachable only inside the cluster.

$(_aap_demo_system_info_services_markdown "$inventory")

## Pod IP Addresses and Health

Pod IP addresses are ephemeral and can change after a restart.

$(_aap_demo_system_info_pods_markdown "$inventory")

## Ingress Router

$(_aap_demo_system_info_ingress_markdown "$inventory")

## Notes

- Public \`*.apps.127.0.0.1.nip.io\` routes resolve to \`127.0.0.1\` on the host.
- ClusterIP and pod addresses are internal and may change when the cluster is rebuilt.
- Refresh this file with \`aap-demo system-info\`.
EOF
}

aap_demo_generate_system_info() {
  local secret_mode="${1:-include}"
  local format="${2:-markdown}"
  local output="${3:-${AAP_DEMO_SYSTEM_INFO_FILE:-${SCRIPT_DIR}/docs/aap-demo-system-info.md}}"
  local inventory tmp_inventory output_dir tmp_output

  case "$format" in
    markdown | json) ;;
    *)
      echo "ERROR: System information format must be markdown or json" >&2
      return 1
      ;;
  esac

  if ! inventory=$(aap_demo_collect_system_inventory "$secret_mode"); then
    echo "ERROR: Could not collect system inventory" >&2
    return 1
  fi

  tmp_inventory=$(mktemp) || return 1
  chmod 600 "$tmp_inventory"
  printf '%s\n' "$inventory" >"$tmp_inventory"

  if [ "$output" = "-" ]; then
    if [ "$format" = json ]; then
      jq . "$tmp_inventory"
    else
      _aap_demo_render_system_info_markdown "$tmp_inventory"
    fi
    rm -f -- "$tmp_inventory"
    return
  fi

  output_dir=$(dirname "$output")
  if ! mkdir -p "$output_dir"; then
    rm -f -- "$tmp_inventory"
    echo "ERROR: Could not create system information directory: $output_dir" >&2
    return 1
  fi
  if ! tmp_output=$(mktemp "${output}.tmp.XXXXXX"); then
    rm -f -- "$tmp_inventory"
    echo "ERROR: Could not create temporary system information file" >&2
    return 1
  fi
  chmod 600 "$tmp_output"

  if [ "$format" = json ]; then
    jq . "$tmp_inventory" >"$tmp_output"
  else
    _aap_demo_render_system_info_markdown "$tmp_inventory" >"$tmp_output"
  fi
  rm -f -- "$tmp_inventory"

  if ! mv -f -- "$tmp_output" "$output"; then
    rm -f -- "$tmp_output"
    echo "ERROR: Could not save system information document: $output" >&2
    return 1
  fi
  chmod 600 "$output"
  echo ""
  echo "✓ System information saved to $output"
  if [ "$secret_mode" = include ]; then
    echo "  This file contains plaintext credentials; keep it private."
  fi
}
