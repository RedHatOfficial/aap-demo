# shellcheck shell=bash

if [ -n "${_AAP_DEMO_SYSTEM_INVENTORY_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_SYSTEM_INVENTORY_LOADED=1

# shellcheck source=includes/storage-capacity.sh
source "${SCRIPT_DIR}/includes/storage-capacity.sh"

_aap_demo_inventory_ipv4() {
  local host="$1"
  getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 { print $1 }' || true
}

_aap_demo_inventory_routes() {
  local addons_text="${1:-}"
  local raw_routes routes row host ip
  raw_routes=$(kubectl get route -A -o json 2>/dev/null || printf '{"items":[]}')
  routes='[]'
  while IFS= read -r row; do
    host=$(jq -r '.host' <<<"$row")
    ip=$(_aap_demo_inventory_ipv4 "$host")
    routes=$(jq -c --argjson row "$row" --arg ip "$ip" \
      '. + [$row + {resolved_ipv4: ($ip | select(length > 0) // null)}]' <<<"$routes")
  done < <(jq -c '
    .items[]
    | select(.metadata.namespace | test("^(openshift-|kube-)") | not)
    | {
        namespace: .metadata.namespace,
        name: .metadata.name,
        host: .spec.host,
        url: ("https://" + .spec.host),
        service: .spec.to.name,
        target_port: (.spec.port.targetPort // null),
        tls: (.spec.tls.termination // "none"),
        admitted: ([.status.ingress[]?.conditions[]? | select(.type == "Admitted") | .status] | any(. == "True"))
      }
  ' <<<"$raw_routes")

  # Append external (non-cluster) routes such as the Satellite lab VM.
  local ext
  while IFS= read -r ext; do
    [ -n "$ext" ] || continue
    routes=$(jq -c --argjson row "$ext" '. + [$row]' <<<"$routes")
  done < <(_aap_demo_inventory_external_routes "$addons_text")

  printf '%s' "$routes"
}

# External routes: services that are not Kubernetes routes but should appear in
# the dashboard Routes list. Currently the Satellite lab VM, surfaced once the
# External namespaces: non-cluster workloads that should appear in the
# dashboard Namespaces list. Currently the Satellite lab VM, surfaced once the
# satellite-manifest addon is enabled and the VM exists.
_aap_demo_inventory_external_namespaces() {
  local addons_text="$1"
  grep -qw 'satellite-manifest' <<<"$addons_text" || return 0
  command -v virsh >/dev/null 2>&1 || return 0

  local state ready=false
  state=$(virsh -c qemu:///system domstate satellite 2>/dev/null) || return 0
  [ -n "$state" ] || return 0
  [ "$state" = "running" ] && ready=true

  jq -cn --argjson ready "$ready" '
    {
      name: "satellite-lab",
      running_pods: (if $ready then 1 else 0 end),
      total_pods: 1,
      ready: $ready,
      external: true
    }'
}

# Kubernetes-native (Python v2) Fleet nodes are pod-backed, so they never
# appear in the QEMU fleet inventory. List them separately so status and the
# dashboard can show both backends.
_aap_demo_inventory_fleet_v2() {
  kubectl get pods -A -l app.kubernetes.io/name=fleet-node -o json 2>/dev/null \
    | jq -c '[.items[] | {
        namespace: .metadata.namespace,
        name: .metadata.name,
        state: (.status.phase // "Unknown" | ascii_downcase),
        ready: ([.status.containerStatuses[]?.ready] | all),
        pod_ip: (.status.podIP // null)
      }]' 2>/dev/null || printf '[]'
}

# The Python v2 CLI is available when this checkout has src/aap_demo and a
# Python with PyYAML is on hand (mirrors the _fleet_delegate_v2 lookup chain).
_aap_demo_inventory_v2_available() {
  [ -d "${SCRIPT_DIR}/src/aap_demo" ] || return 1
  local candidate
  for candidate in "${AAP_DEMO_PYTHON:-}" \
    "${SCRIPT_DIR}/.venv/bin/python" "${SCRIPT_DIR}/.venv/bin/python3" \
    "$(command -v python3 2>/dev/null)"; do
    if [ -n "$candidate" ] && command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -c 'import yaml' >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# satellite-manifest addon is enabled and the Satellite VM exists.
_aap_demo_inventory_external_routes() {
  local addons_text="$1"
  # Only when the satellite-manifest addon is enabled.
  grep -qw 'satellite-manifest' <<<"$addons_text" || return 0

  local sat_host sat_ip
  sat_host="${SATELLITE_LAB_HOST:-satellite.demo.lab}"
  sat_ip=$(_aap_demo_inventory_ipv4 "$sat_host")
  # Fall back to the well-known lab NIC1 address when the FQDN does not resolve.
  if [ -z "$sat_ip" ]; then
    sat_ip="${SATELLITE_LAB_IP:-192.168.122.20}"
  fi

  # Surface the route once the Satellite VM exists and is running (so it shows
  # during the build), marking it admitted only once it answers HTTPS.
  command -v virsh >/dev/null 2>&1 || return 0
  [ "$(virsh -c qemu:///system domstate satellite 2>/dev/null)" = "running" ] || return 0

  local admitted=false
  if curl -sk --connect-timeout 3 --max-time 5 -o /dev/null "https://${sat_ip}/" 2>/dev/null; then
    admitted=true
  fi

  jq -cn \
    --arg host "$sat_host" \
    --arg ip "$sat_ip" \
    --argjson admitted "$admitted" \
    '{
      namespace: "satellite-lab",
      name: "satellite",
      host: $host,
      url: ("https://" + $host),
      service: "satellite",
      target_port: "https",
      tls: "edge",
      admitted: $admitted,
      resolved_ipv4: $ip,
      external: true
    }'
}

_aap_demo_inventory_app_namespaces() {
  kubectl get namespace -o json 2>/dev/null | jq -c '
    [
      .items[].metadata.name
      | select(
          . != "default"
          and . != "olm"
          and (test("^(openshift-|kube-)") | not)
        )
    ]
    | sort
  ' 2>/dev/null || printf '[]'
}

_aap_demo_inventory_services() {
  local namespaces="$1"
  kubectl get service -A -o json 2>/dev/null | jq -c --argjson namespaces "$namespaces" '
    [
      .items[]
      | select(.metadata.namespace as $namespace | $namespaces | index($namespace))
      | {
          namespace: .metadata.namespace,
          name: .metadata.name,
          type: (.spec.type // "ClusterIP"),
          cluster_ip: (.spec.clusterIP // null),
          external_ips: (.spec.externalIPs // []),
          ports: [
            .spec.ports[]?
            | {
                name: (.name // null),
                port: .port,
                protocol: (.protocol // "TCP"),
                target_port: (.targetPort // .port),
                node_port: (.nodePort // null)
              }
          ]
        }
    ]
    | sort_by(.namespace, .name)
  ' 2>/dev/null || printf '[]'
}

_aap_demo_inventory_pods() {
  local namespaces="$1"
  kubectl get pods -A -o json 2>/dev/null | jq -c --argjson namespaces "$namespaces" '
    [
      .items[]
      | select(.metadata.namespace as $namespace | $namespaces | index($namespace))
      | select(.status.phase != "Succeeded")
      | {
          namespace: .metadata.namespace,
          name: .metadata.name,
          phase: (.status.phase // "Unknown"),
          ready_containers: ([.status.containerStatuses[]? | select(.ready == true)] | length),
          total_containers: ([.status.containerStatuses[]?] | length),
          restarts: ([.status.containerStatuses[]?.restartCount] | add // 0),
          pod_ip: (.status.podIP // null),
          node: (.spec.nodeName // null)
        }
    ]
    | sort_by(.namespace, .name)
  ' 2>/dev/null || printf '[]'
}

_aap_demo_inventory_namespaces() {
  local namespaces="$1"
  local pods="$2"
  jq -cn --argjson namespaces "$namespaces" --argjson pods "$pods" '
    [
      $namespaces[] as $namespace
      | ($pods | map(select(.namespace == $namespace))) as $namespace_pods
      | select(($namespace_pods | length) > 0)
      | {
          name: $namespace,
          running_pods: ($namespace_pods | map(select(.phase == "Running")) | length),
          total_pods: ($namespace_pods | length),
          ready: (
            ($namespace_pods | length) > 0
            and ($namespace_pods | all(.phase == "Running" and .ready_containers == .total_containers))
          )
        }
    ]
  '
}

_aap_demo_inventory_secret_value() {
  local namespace="$1"
  local secret="$2"
  local key="$3"
  local mode="$4"
  local value

  case "$mode" in
    include)
      value=$(kubectl get secret "$secret" -n "$namespace" \
        -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true)
      [ -n "$value" ] && printf '%s' "$value" || printf 'null'
      ;;
    redact) printf '******' ;;
    omit) printf 'null' ;;
    *)
      echo "ERROR: Unsupported inventory secret mode: $mode" >&2
      return 1
      ;;
  esac
}

_aap_demo_inventory_credentials() {
  local mode="$1"
  local aap_json credentials item namespace secret password ao_password
  aap_json=$(kubectl get aap -A -o json 2>/dev/null || printf '{"items":[]}')
  credentials='[]'

  while IFS= read -r item; do
    namespace=$(jq -r '.namespace' <<<"$item")
    secret=$(jq -r '.secret // empty' <<<"$item")
    if [ -z "$secret" ]; then
      for secret in myaap-admin-password aap-admin-password aap-controller-admin-password custom-admin-password; do
        kubectl get secret "$secret" -n "$namespace" &>/dev/null && break
      done
    fi
    password=$(_aap_demo_inventory_secret_value "$namespace" "$secret" password "$mode")
    credentials=$(jq -c \
      --arg component "AAP" \
      --arg namespace "$namespace" \
      --arg username "admin" \
      --arg secret "$secret" \
      --arg password "$password" \
      '. + [{
        component: $component,
        namespace: $namespace,
        username: $username,
        secret_name: $secret,
        password: (if $password == "null" then null else $password end)
      }]' <<<"$credentials")
  done < <(jq -c '
    .items[]
    | {
        namespace: .metadata.namespace,
        secret: (.status.adminPasswordSecret // null)
      }
  ' <<<"$aap_json")

  if kubectl get namespace automation-orchestrator &>/dev/null; then
    secret="automation-orchestrator-initial-admin-password"
    ao_password=$(_aap_demo_inventory_secret_value automation-orchestrator "$secret" password "$mode")
    credentials=$(jq -c \
      --arg component "Automation Orchestrator" \
      --arg namespace "automation-orchestrator" \
      --arg username "admin" \
      --arg secret "$secret" \
      --arg password "$ao_password" \
      '. + [{
        component: $component,
        namespace: $namespace,
        username: $username,
        secret_name: $secret,
        password: (if $password == "null" then null else $password end)
      }]' <<<"$credentials")
  fi
  printf '%s' "$credentials"
}

_aap_demo_inventory_api_keys() {
  local mode="$1"
  local api_key="null"
  if [ "${AO_LLM_PROVIDER:-}" = external ]; then
    case "$mode" in
      include)
        api_key=$(aap_demo_ao_llm_read_key 2>/dev/null || true)
        [ -n "$api_key" ] || api_key="null"
        ;;
      redact) api_key="******" ;;
    esac
  fi
  jq -cn \
    --arg provider "${AO_LLM_PROVIDER:-not configured}" \
    --arg base_url "${AO_LLM_BASE_URL:-}" \
    --arg model "${AO_LLM_MODEL:-}" \
    --arg api_key "$api_key" \
    '{
      ao_llm: {
        provider: $provider,
        base_url: ($base_url | select(length > 0) // null),
        model: ($model | select(length > 0) // null),
        api_key: (if $api_key == "null" then null else $api_key end)
      },
      aap_mcp: {
        oauth_token: null,
        note: "Generated for client configuration but not persisted by aap-demo"
      }
    }'
}

_aap_demo_inventory_ingress() {
  local service endpoints router_svc
  # MicroShift exposes router-default; the OpenShift preset exposes
  # router-internal-default. Use whichever exists.
  router_svc=$(kubectl get svc -n openshift-ingress -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^router-(internal-)?default$' | head -1)
  router_svc="${router_svc:-router-default}"
  service=$(kubectl get service "$router_svc" -n openshift-ingress -o json 2>/dev/null \
    | jq -c '{
        name: .metadata.name,
        cluster_ip: (.spec.clusterIP // null),
        external_ips: (
          [(.status.loadBalancer.ingress[]?.ip), (.spec.externalIPs[]?)]
          | map(select(. != null))
          | unique
        ),
        ports: [
          .spec.ports[]?
          | {
              port: .port,
              protocol: (.protocol // "TCP"),
              node_port: (.nodePort // null)
            }
        ]
      }' 2>/dev/null || printf 'null')
  # kubectl prints a deprecation warning to stdout before the JSON; keep only
  # the JSON document so jq never receives the warning text.
  endpoints=$(kubectl get endpoints "$router_svc" -n openshift-ingress -o json 2>/dev/null \
    | sed -n '/^{/,$p' \
    | jq -c '[
        .subsets[]?
        | .addresses[]? as $address
        | .ports[]?
        | {
            ip: $address.ip,
            port: .port,
            protocol: (.protocol // "TCP")
          }
      ]' 2>/dev/null || printf '[]')
  # Never pass empty text to --argjson.
  [ -n "$service" ] || service='null'
  [ -n "$endpoints" ] || endpoints='[]'
  jq -cn --argjson service "$service" --argjson endpoints "$endpoints" \
    '{service: $service, endpoints: $endpoints}'
}

_aap_demo_inventory_vm() {
  local vm_info guest_os openshift cpus memory_used memory_total memory_available load disk
  local disk_total_gib disk_used_gib disk_free_gib
  if ! declare -F infra_exec_cmd >/dev/null; then
    printf '{}'
    return
  fi
  vm_info=$(infra_exec_cmd bash -c '
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$(cat /etc/redhat-release 2>/dev/null || echo unknown)" \
      "$(microshift version 2>/dev/null | awk "/MicroShift Version:/{print \$3}" || rpm -q microshift --qf "%{VERSION}" 2>/dev/null || echo unknown)" \
      "$(nproc 2>/dev/null || echo unknown)" \
      "$(free -h | awk "/Mem:/{print \$3}")" \
      "$(free -h | awk "/Mem:/{print \$2}")" \
      "$(free -h | awk "/Mem:/{print \$7}")" \
      "$(awk "{print \$1, \$2, \$3}" /proc/loadavg 2>/dev/null || echo unknown)" \
      "$(df -h /var 2>/dev/null | awk "NR==2{print \$3\"/\"\$2\" (\"\$5\" used)\"}")" \
      "$(df -BG --output=size /var 2>/dev/null | tail -n 1 | tr -d " G")" \
      "$(df -BG --output=used /var 2>/dev/null | tail -n 1 | tr -d " G")" \
      "$(df -BG --output=avail /var 2>/dev/null | tail -n 1 | tr -d " G")"
  ' 2>/dev/null || true)
  IFS=$'\t' read -r guest_os openshift cpus memory_used memory_total memory_available load disk \
    disk_total_gib disk_used_gib disk_free_gib <<<"$vm_info"
  # On the OpenShift preset the VM has no microshift binary, so the version
  # field comes back empty and shifts every later field left. Fall back to the
  # host-side `crc version` OpenShift version.
  if [ -z "$openshift" ] || [ "$openshift" = "unknown" ]; then
    openshift=$(crc version 2>/dev/null | awk -F': *' '/^OpenShift version:/ {print $2}' || true)
    openshift="${openshift:-unknown}"
  fi
  jq -cn \
    --arg guest_os "${guest_os:-unknown}" \
    --arg openshift "${openshift:-unknown}" \
    --arg cpus "${cpus:-unknown}" \
    --arg memory_used "${memory_used:-unknown}" \
    --arg memory_total "${memory_total:-unknown}" \
    --arg memory_available "${memory_available:-unknown}" \
    --arg load "${load:-unknown}" \
    --arg disk "${disk:-unknown}" \
    --arg disk_total_gib "${disk_total_gib:-}" \
    --arg disk_used_gib "${disk_used_gib:-}" \
    --arg disk_free_gib "${disk_free_gib:-}" \
    '{
      guest_os: $guest_os,
      openshift_version: $openshift,
      cpus: $cpus,
      memory: {
        used: $memory_used,
        total: $memory_total,
        available: $memory_available
      },
      load: $load,
      disk: $disk,
      disk_gib: {
        size: (if $disk_total_gib == "" then null else ($disk_total_gib | tonumber?) end),
        used: (if $disk_used_gib == "" then null else ($disk_used_gib | tonumber?) end),
        free: (if $disk_free_gib == "" then null else ($disk_free_gib | tonumber?) end)
      }
    }'
}

_aap_demo_inventory_configured_crc_disk() {
  local output line
  if [ -n "${CRC_DISK:-}" ]; then
    printf '%s' "$CRC_DISK"
    return
  fi
  if [ -n "${VM_DISK_SIZE:-}" ]; then
    printf '%s' "$VM_DISK_SIZE"
    return
  fi
  [ "${INFRA_TYPE:-}" = "crc" ] || return 0
  command -v crc >/dev/null 2>&1 || return 0
  output=$(crc config get disk-size 2>/dev/null) || return 0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*disk-size[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return
    fi
  done <<<"$output"
}

_aap_demo_inventory_storage() {
  local addons="$1" vm="$2" plan configured actual used free
  plan=$(aap_demo_capacity_inventory_plan "$addons")
  configured=$(_aap_demo_inventory_configured_crc_disk)
  actual=$(jq -r '.disk_gib.size // empty' <<<"$vm")
  used=$(jq -r '.disk_gib.used // empty' <<<"$vm")
  free=$(jq -r '.disk_gib.free // empty' <<<"$vm")
  jq -cn \
    --argjson plan "$plan" \
    --arg configured "$configured" \
    --arg actual "$actual" \
    --arg used "$used" \
    --arg free "$free" '
      (try ($configured | tonumber) catch null) as $configured_n
      | (try ($actual | tonumber) catch null) as $actual_n
      | (try ($used | tonumber) catch null) as $used_n
      | (try ($free | tonumber) catch null) as $free_n
      | $plan + {
          configured_crc_disk_gib: $configured_n,
          actual_vm_disk_gib: $actual_n,
          actual_vm_used_gib: $used_n,
          actual_vm_free_gib: $free_n,
          needs_rebuild: (
            $actual_n != null
            and ($actual_n + 2) < $plan.recommended_vm_disk_gib
          ),
          configured_not_applied: (
            $configured_n != null
            and $actual_n != null
            and (($configured_n - $actual_n) | fabs) > 2
          ),
          note: "CRC disk configuration is applied only when the VM is created; resizing an existing VM requires a destructive rebuild and is never automatic."
        }'
}

_aap_demo_inventory_crc_access() {
  local crc_ip="" key=""
  if ! crc_ip=$(crc ip 2>/dev/null); then
    echo "WARNING: CRC IP unavailable; use 'aap-demo ssh' after CRC networking recovers" >&2
    crc_ip=""
  fi
  if declare -F _detect_crc_ssh_key >/dev/null; then
    key=$(_detect_crc_ssh_key) || key=""
  fi
  jq -cn --arg ip "$crc_ip" --arg key "$key" '{
    crc_ip: ($ip | select(length > 0) // null),
    ssh_host: "127.0.0.1",
    ssh_port: 2222,
    ssh_user: "core",
    ssh_key: ($key | select(length > 0) // null),
    ssh_command: "aap-demo ssh"
  }'
}

aap_demo_collect_system_inventory() {
  local secret_mode="${1:-omit}"
  local cluster_state cluster_name generated_at addons addons_text host_os host_arch aap_subscription context kubernetes_version
  local namespaces services pods namespace_status routes credentials api_keys ingress vm storage fleet fleet_v2 crc_access v2_available
  # shellcheck source=fleet-access.sh
  source "$(dirname "${BASH_SOURCE[0]}")/fleet-access.sh"
  fleet=$(fleet_access_inventory "$secret_mode") || return 1
  fleet_v2='[]'
  if _aap_demo_inventory_v2_available; then
    v2_available=true
  else
    v2_available=false
  fi

  case "$secret_mode" in
    include | redact | omit) ;;
    *)
      echo "ERROR: Secret mode must be include, redact, or omit" >&2
      return 1
      ;;
  esac

  cluster_state=$(infra_get_state 2>/dev/null || echo "not_created")
  cluster_name=$(infra_get_name 2>/dev/null || echo "")
  generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  host_os=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  host_arch=$(uname -m 2>/dev/null || echo "unknown")
  aap_subscription=""
  if [ -s "${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet/aap_subscription_name" ]; then
    aap_subscription=$(cat "${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet/aap_subscription_name")
  fi
  if declare -F _addons_list >/dev/null; then
    addons_text=$(_addons_list)
  else
    addons_text=$(tr ',' ' ' <<<"${ADDONS:-}")
  fi
  addons=$(jq -Rsc '[scan("\\S+")]' <<<"$addons_text")

  context="unknown"
  kubernetes_version="unknown"
  namespaces='[]'
  services='[]'
  pods='[]'
  namespace_status='[]'
  routes='[]'
  credentials='[]'
  api_keys=$(_aap_demo_inventory_api_keys "$secret_mode")
  ingress='{"service":null,"endpoints":[]}'
  vm='{}'
  storage='{}'

  if [ "$cluster_state" = running ] && kubectl cluster-info &>/dev/null; then
    context=$(kubectl config current-context 2>/dev/null || echo "unknown")
    kubernetes_version=$(kubectl version -o json 2>/dev/null \
      | jq -r '.serverVersion.gitVersion // "unknown"' 2>/dev/null || echo "unknown")
    namespaces=$(_aap_demo_inventory_app_namespaces)
    services=$(_aap_demo_inventory_services "$namespaces")
    pods=$(_aap_demo_inventory_pods "$namespaces")
    namespace_status=$(_aap_demo_inventory_namespaces "$namespaces" "$pods")
    # Append external (non-cluster) namespace entries such as the Satellite lab VM.
    local ext_ns
    while IFS= read -r ext_ns; do
      [ -n "$ext_ns" ] || continue
      namespace_status=$(jq -c --argjson row "$ext_ns" '. + [$row]' <<<"$namespace_status")
    done < <(_aap_demo_inventory_external_namespaces "$addons_text")
    routes=$(_aap_demo_inventory_routes "$addons_text")
    credentials=$(_aap_demo_inventory_credentials "$secret_mode")
    ingress=$(_aap_demo_inventory_ingress)
    vm=$(_aap_demo_inventory_vm)
    fleet_v2=$(_aap_demo_inventory_fleet_v2)
  fi
  storage=$(_aap_demo_inventory_storage "$addons_text" "$vm")
  crc_access=$(_aap_demo_inventory_crc_access)

  jq -cn \
    --arg generated_at "$generated_at" \
    --arg secret_mode "$secret_mode" \
    --arg tool_version "$(aap_demo_version_short)" \
    --arg built "$AAP_DEMO_GIT_DATE" \
    --arg source "$AAP_DEMO_REPO_ROOT" \
    --arg branch "$AAP_DEMO_GIT_BRANCH" \
    --arg repo "$AAP_DEMO_GIT_REMOTE" \
    --arg host_os "${host_os:-unknown}" \
    --arg host_arch "$host_arch" \
    --arg aap_subscription "$aap_subscription" \
    --arg cluster_name "$cluster_name" \
    --arg cluster_state "$cluster_state" \
    --arg context "$context" \
    --arg kubeconfig "${KUBECONFIG:-$(aap_demo_resolve_kubeconfig)}" \
    --arg kubernetes_version "$kubernetes_version" \
    --argjson addons "$addons" \
    --argjson namespaces "$namespace_status" \
    --argjson routes "$routes" \
    --argjson credentials "$credentials" \
    --argjson fleet "$fleet" \
    --argjson fleet_v2 "$fleet_v2" \
    --argjson v2_available "$v2_available" \
    --argjson api_keys "$api_keys" \
    --argjson services "$services" \
    --argjson pods "$pods" \
    --argjson ingress "$ingress" \
    --argjson vm "$vm" \
    --argjson storage "$storage" \
    --argjson crc_access "$crc_access" \
    '{
      schema_version: 1,
      generated_at: $generated_at,
      secret_mode: $secret_mode,
      tool: {
        version: $tool_version,
        built: $built,
        source: $source,
        branch: $branch,
        repository: ($repo | select(length > 0) // null),
        v2_available: $v2_available
      },
      host: {
        os: $host_os,
        architecture: $host_arch,
        aap_subscription: ($aap_subscription | select(length > 0) // null)
      },
      cluster: {
        infrastructure: "OpenShift Local (CRC/MicroShift)",
        name: ($cluster_name | select(length > 0) // null),
        state: $cluster_state,
        context: $context,
        kubeconfig: $kubeconfig,
        kubernetes_version: $kubernetes_version,
        crc_ip: $crc_access.crc_ip,
        ssh: ($crc_access | del(.crc_ip)),
        vm: $vm
      },
      storage: {
        capacity_planning: $storage
      },
      addons: $addons,
      namespaces: $namespaces,
      routes: $routes,
      credentials: $credentials,
      fleet: $fleet,
      fleet_v2: $fleet_v2,
      api_keys: $api_keys,
      services: $services,
      pods: $pods,
      ingress: $ingress
    }'
}
