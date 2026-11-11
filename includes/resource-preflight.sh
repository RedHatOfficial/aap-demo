#!/usr/bin/env bash

if [ -n "${_AAP_DEMO_RESOURCE_PREFLIGHT_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_RESOURCE_PREFLIGHT_LOADED=1

aap_demo_vm_disk_usage_pct() {
  local usage
  usage=$(infra_exec_cmd df -P /var 2>/dev/null \
    | awk 'NR==2 {gsub(/%/, "", $5); print $5}') || return 1
  [[ "$usage" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$usage"
}

aap_demo_cluster_resource_snapshot() {
  local alloc requested
  alloc=$(kubectl get nodes -o json 2>/dev/null | jq -r '
    def cpu_m:
      if . == null then 0
      elif test("n$") then sub("n$"; "") | tonumber / 1000000
      elif test("u$") then sub("u$"; "") | tonumber / 1000
      elif test("m$") then sub("m$"; "") | tonumber
      else tonumber * 1000
      end;
    def memory_mi:
      if . == null then 0
      elif test("Ki$") then sub("Ki$"; "") | tonumber / 1024
      elif test("Mi$") then sub("Mi$"; "") | tonumber
      elif test("Gi$") then sub("Gi$"; "") | tonumber * 1024
      elif test("Ti$") then sub("Ti$"; "") | tonumber * 1048576
      elif test("K$") then sub("K$"; "") | tonumber * 1000 / 1048576
      elif test("M$") then sub("M$"; "") | tonumber * 1000000 / 1048576
      elif test("G$") then sub("G$"; "") | tonumber * 1000000000 / 1048576
      else tonumber / 1048576
      end;
    [
      ([.items[].status.allocatable.cpu | cpu_m] | add // 0),
      ([.items[].status.allocatable.memory | memory_mi] | add // 0)
    ] | map(floor) | @tsv
  ') || return 1

  requested=$(kubectl get pods -A -o json 2>/dev/null | jq -r '
    def cpu_m:
      if . == null then 0
      elif test("n$") then sub("n$"; "") | tonumber / 1000000
      elif test("u$") then sub("u$"; "") | tonumber / 1000
      elif test("m$") then sub("m$"; "") | tonumber
      else tonumber * 1000
      end;
    def memory_mi:
      if . == null then 0
      elif test("Ki$") then sub("Ki$"; "") | tonumber / 1024
      elif test("Mi$") then sub("Mi$"; "") | tonumber
      elif test("Gi$") then sub("Gi$"; "") | tonumber * 1024
      elif test("Ti$") then sub("Ti$"; "") | tonumber * 1048576
      elif test("K$") then sub("K$"; "") | tonumber * 1000 / 1048576
      elif test("M$") then sub("M$"; "") | tonumber * 1000000 / 1048576
      elif test("G$") then sub("G$"; "") | tonumber * 1000000000 / 1048576
      else tonumber / 1048576
      end;
    def request_quantity($resource; $kind):
      (.resources.requests[$resource] // "0")
      | if $kind == "cpu" then cpu_m else memory_mi end;
    def container_sum($resource; $kind):
      [.spec.containers[]? | request_quantity($resource; $kind)] | add // 0;
    def init_max($resource; $kind):
      [.spec.initContainers[]? | request_quantity($resource; $kind)] | max // 0;
    def pod_request($resource; $kind):
      ([container_sum($resource; $kind), init_max($resource; $kind)] | max);
    (
      .items
      | map(select(.spec.nodeName != null and (.status.phase == "Running" or .status.phase == "Pending")))
    ) as $scheduled |
    [
      ($scheduled
        | map(pod_request("cpu"; "cpu")) | add // 0),
      ($scheduled
      | map(select(.spec.nodeName != null and (.status.phase == "Running" or .status.phase == "Pending")))
        | map(pod_request("memory"; "memory")) | add // 0)
    ] | map(floor) | @tsv
  ') || return 1

  printf '%s\t%s\n' "$alloc" "$requested"
}

aap_demo_resource_preflight() {
  local label="$1"
  local required_cpu_m="${2:-0}"
  local required_memory_mi="${3:-0}"
  local snapshot alloc_cpu_m alloc_memory_mi requested_cpu_m requested_memory_mi
  local cpu_headroom_m memory_headroom_m insufficient=false

  AAP_RESOURCE_PREFLIGHT_UNAVAILABLE=false
  AAP_RESOURCE_PREFLIGHT_INSUFFICIENT=false
  AAP_RESOURCE_PREFLIGHT_SKIPPED=false
  AAP_RESOURCE_CPU_HEADROOM_M=""
  AAP_RESOURCE_MEMORY_HEADROOM_MI=""

  if [ "${AAP_RESOURCE_PREFLIGHT_SKIP:-false}" = true ]; then
    AAP_RESOURCE_PREFLIGHT_SKIPPED=true
    return 0
  fi

  if ! snapshot=$(aap_demo_cluster_resource_snapshot); then
    AAP_RESOURCE_PREFLIGHT_UNAVAILABLE=true
    echo "WARNING: Could not calculate cluster resource headroom for ${label}." >&2
    [ "${AAP_RESOURCE_PREFLIGHT_STRICT:-false}" != true ]
    return
  fi
  IFS=$'\t' read -r alloc_cpu_m alloc_memory_mi requested_cpu_m requested_memory_mi \
    <<<"$snapshot"
  cpu_headroom_m=$((alloc_cpu_m - requested_cpu_m))
  memory_headroom_m=$((alloc_memory_mi - requested_memory_mi))
  AAP_RESOURCE_CPU_HEADROOM_M="$cpu_headroom_m"
  AAP_RESOURCE_MEMORY_HEADROOM_MI="$memory_headroom_m"

  echo "Resource preflight for ${label}:"
  printf "  CPU:    %sm available of %sm allocatable (%sm requested)\n" \
    "$cpu_headroom_m" "$alloc_cpu_m" "$requested_cpu_m"
  printf "  Memory: %sMi available of %sMi allocatable (%sMi requested)\n" \
    "$memory_headroom_m" "$alloc_memory_mi" "$requested_memory_mi"

  if [ "$cpu_headroom_m" -lt "$required_cpu_m" ]; then
    echo "  WARNING: ${label} recommends at least ${required_cpu_m}m free CPU." >&2
    insufficient=true
  fi
  if [ "$memory_headroom_m" -lt "$required_memory_mi" ]; then
    echo "  WARNING: ${label} recommends at least ${required_memory_mi}Mi free memory." >&2
    insufficient=true
  fi

  if [ "$insufficient" = true ] && [ "${AAP_RESOURCE_PREFLIGHT_STRICT:-false}" = true ]; then
    AAP_RESOURCE_PREFLIGHT_INSUFFICIENT=true
    echo "ERROR: Resource preflight failed in strict mode." >&2
    return 1
  fi
  [ "$insufficient" != true ] || AAP_RESOURCE_PREFLIGHT_INSUFFICIENT=true
  return 0
}
