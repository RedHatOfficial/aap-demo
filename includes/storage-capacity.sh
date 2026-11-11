# shellcheck shell=bash

if [ -n "${_AAP_DEMO_STORAGE_CAPACITY_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_STORAGE_CAPACITY_LOADED=1

AAP_DEMO_CAPACITY_MODEL="${AAP_DEMO_CAPACITY_MODEL:-${SCRIPT_DIR}/config/storage-capacity.json}"
AAP_DEMO_MIN_IMAGE_STORAGE_GIB="${AAP_DEMO_MIN_IMAGE_STORAGE_GIB:-100}"

_aap_demo_capacity_addons_json() {
  printf '%s' "${1:-}" | tr ',' ' ' | jq -Rsc '[scan("\\S+")] | unique'
}

aap_demo_capacity_plan() {
  local addons="${1:-}" addons_json
  addons_json=$(_aap_demo_capacity_addons_json "$addons")
  jq -cn \
    --slurpfile model "$AAP_DEMO_CAPACITY_MODEL" \
    --argjson enabled "$addons_json" '
      $model[0] as $m
      | (
          [$enabled[] as $id
            | select($m.addons[$id] != null)
            | $m.addons[$id].vm_gib
          ] | add // 0
        ) as $addon_vm
      | (
          [$enabled[] as $id
            | select($m.addons[$id] != null)
            | $m.addons[$id].host_gib
          ] | add // 0
        ) as $host
      | ($m.core.vm_gib + $m.headroom.vm_gib + $addon_vm) as $raw
      | ((($raw / $m.round_to_gib) | ceil) * $m.round_to_gib) as $recommended
      | {
          estimate: true,
          units: $m.units,
          description: $m.description,
          enabled_addons: $enabled,
          core_vm_gib: $m.core.vm_gib,
          safety_headroom_gib: $m.headroom.vm_gib,
          addons_vm_gib: $addon_vm,
          host_only_gib: $host,
          recommended_vm_disk_gib: $recommended,
          addons: (
            reduce $enabled[] as $id ({};
              if $m.addons[$id] == null then .
              else .[$id] = $m.addons[$id]
              end
            )
          )
        }'
}

aap_demo_capacity_recommended_disk() {
  aap_demo_capacity_plan "${1:-}" | jq -r '.recommended_vm_disk_gib'
}

aap_demo_capacity_inventory_plan() {
  local addons="${1:-}" plan addon projected projections='{}'
  plan=$(aap_demo_capacity_plan "$addons")
  while IFS= read -r addon; do
    if echo " $addons " | grep -q " $addon "; then
      projected=$(jq -r '.recommended_vm_disk_gib' <<<"$plan")
    else
      projected=$(aap_demo_capacity_recommended_disk "${addons:+$addons }$addon")
    fi
    projections=$(jq -c --arg addon "$addon" --argjson value "$projected" \
      '. + {($addon): $value}' <<<"$projections")
  done < <(jq -r '.addons | keys[]' "$AAP_DEMO_CAPACITY_MODEL")

  jq -c \
    --slurpfile model "$AAP_DEMO_CAPACITY_MODEL" \
    --argjson projections "$projections" '
      . + {
        addon_estimates: $model[0].addons,
        projected_vm_disk_gib: $projections
      }' <<<"$plan"
}

aap_demo_capacity_default_pv_size() {
  local disk="$1" preferred="${2:-70}" reserve=30
  if [ "$preferred" -lt "$disk" ]; then
    printf '%s' "$preferred"
  elif [ "$disk" -gt "$reserve" ]; then
    printf '%s' "$((disk - reserve))"
  else
    printf '%s' "$((disk - 1))"
  fi
}

aap_demo_capacity_minimum_disk() {
  local pv_size="$1" image_size="${2:-$AAP_DEMO_MIN_IMAGE_STORAGE_GIB}" required
  if ! [[ "$pv_size" =~ ^[0-9]+$ ]] || [ "$pv_size" -le 0 ]; then
    echo "ERROR: CRC_PV_SIZE must be a positive integer" >&2
    return 1
  fi
  if ! [[ "$image_size" =~ ^[0-9]+$ ]] || [ "$image_size" -le 0 ]; then
    echo "ERROR: AAP_DEMO_MIN_IMAGE_STORAGE_GIB must be a positive integer" >&2
    return 1
  fi

  required=$((pv_size + image_size + 1))
  printf '%s' "$((((required + 9) / 10) * 10))"
}

aap_demo_capacity_select_disk() {
  case "${1:-1}" in
    1 | 180) printf '180' ;;
    2 | 220) printf '220' ;;
    3 | 270) printf '270' ;;
    4 | 320) printf '320' ;;
    *) return 1 ;;
  esac
}

aap_demo_capacity_resolve_crc_sizes() {
  local requested_disk minimum_disk
  if [ -z "${CRC_DISK+x}" ]; then
    if [ -n "${VM_DISK_SIZE+x}" ]; then
      CRC_DISK="$VM_DISK_SIZE"
    else
      CRC_DISK=$(aap_demo_capacity_recommended_disk "${ADDONS:-}")
    fi
  fi
  if [ -z "${CRC_PV_SIZE+x}" ]; then
    if [ -n "${VM_PV_SIZE+x}" ]; then
      CRC_PV_SIZE="$VM_PV_SIZE"
    else
      CRC_PV_SIZE=$(aap_demo_capacity_default_pv_size "$CRC_DISK" 70)
    fi
  fi

  requested_disk="$CRC_DISK"
  minimum_disk=$(aap_demo_capacity_minimum_disk "$CRC_PV_SIZE") || return 1
  if ! [[ "$CRC_DISK" =~ ^[0-9]+$ ]] || [ "$CRC_DISK" -le 0 ]; then
    echo "ERROR: CRC_DISK must be a positive integer" >&2
    return 1
  fi
  if [ "$CRC_DISK" -lt "$minimum_disk" ]; then
    CRC_DISK="$minimum_disk"
    printf '  Warning: CRC_DISK=%sGB leaves less than %sGB for root/container images; increasing to %sGB.\n' \
      "$requested_disk" "$AAP_DEMO_MIN_IMAGE_STORAGE_GIB" "$CRC_DISK" >&2
  fi
}

_aap_demo_capacity_vm_disk_values() {
  local values
  if ! declare -F infra_exec_cmd >/dev/null; then
    return 1
  fi
  values=$(infra_exec_cmd bash -c \
    "df -BG --output=size,used,avail /var 2>/dev/null | tail -n 1 | tr -d 'G'" \
    2>/dev/null || true)
  if [[ "$values" =~ ^[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]*$ ]]; then
    printf '%s %s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

aap_demo_capacity_warn_enable() {
  local addon="$1" current="${2:-}" projected plan recommended incremental values actual free
  if echo " $current " | grep -q " $addon "; then
    return 0
  fi
  projected="${current:+$current }$addon"
  plan=$(aap_demo_capacity_plan "$projected")
  recommended=$(jq -r '.recommended_vm_disk_gib' <<<"$plan")
  incremental=$(jq -r --arg addon "$addon" '.addons[$addon].vm_gib // 0' <<<"$plan")
  values=$(_aap_demo_capacity_vm_disk_values || true)
  [ -n "$values" ] || return 0
  read -r actual _ free <<<"$values"

  if [ "$actual" -lt "$recommended" ] || [ "$free" -lt "$incremental" ]; then
    printf '\n\033[0;33m⚠ Disk capacity planning warning\033[0m\n' >&2
    printf '  Enabling %s projects a %s GiB CRC VM recommendation; this VM is %s GiB with %s GiB free.\n' \
      "$addon" "$recommended" "$actual" "$free" >&2
    printf '  Estimates are conservative planning guidance, not exact requirements.\n' >&2
    printf '  Continuing without resize. During aap-demo start, filesystem usage of 90%% or more\n' >&2
    printf '  triggers 20%% disk growth through a brief CRC stop/start, without a rebuild.\n\n' >&2
  fi
}
