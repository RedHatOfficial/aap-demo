#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SCRIPT_DIR="$REPO_ROOT"

# shellcheck source=../includes/storage-capacity.sh
source "$REPO_ROOT/includes/storage-capacity.sh"

[ "$(aap_demo_capacity_select_disk "")" = 180 ]
[ "$(aap_demo_capacity_select_disk 1)" = 180 ]
[ "$(aap_demo_capacity_select_disk 180)" = 180 ]
[ "$(aap_demo_capacity_select_disk 2)" = 220 ]
[ "$(aap_demo_capacity_select_disk 3)" = 270 ]
[ "$(aap_demo_capacity_select_disk 4)" = 320 ]
if aap_demo_capacity_select_disk 5 >/dev/null; then
  echo "Invalid CRC disk selection was accepted" >&2
  exit 1
fi

[ "$(aap_demo_capacity_recommended_disk "")" = 180 ]
[ "$(aap_demo_capacity_recommended_disk "ao mcp-server ollama")" = 220 ]

all_addons=$(jq -r '.addons | keys | join(" ")' "$AAP_DEMO_CAPACITY_MODEL")
all_plan=$(aap_demo_capacity_plan "$all_addons")
[ "$(jq -r '.recommended_vm_disk_gib' <<<"$all_plan")" = 270 ]
# host_only_gib includes satellite-manifest's 1 GiB host-side manifest.
[ "$(jq -r '.host_only_gib' <<<"$all_plan")" = 66 ]
[ "$(jq -r '.addons.fleet.vm_gib' <<<"$all_plan")" = 0 ]
[ "$(jq -r '.addons.fleet.host_gib' <<<"$all_plan")" = 25 ]

cli_addons=$(sed -n 's/^AVAILABLE_ADDONS="\([^"]*\)"/\1/p' "$REPO_ROOT/aap-demo.sh" | tr ' ' '\n' | sort)
model_addons=$(jq -r '.addons | keys[]' "$AAP_DEMO_CAPACITY_MODEL" | sort)
[ "$cli_addons" = "$model_addons" ]

unset CRC_DISK CRC_PV_SIZE VM_DISK_SIZE VM_PV_SIZE
ADDONS="ao,mcp-server,ollama"
aap_demo_capacity_resolve_crc_sizes
[ "$CRC_DISK" = 220 ]
[ "$CRC_PV_SIZE" = 70 ]

unset CRC_PV_SIZE VM_DISK_SIZE VM_PV_SIZE
CRC_DISK=137
aap_demo_capacity_resolve_crc_sizes
[ "$CRC_DISK" = 180 ]
[ "$CRC_PV_SIZE" = 70 ]

unset CRC_PV_SIZE VM_DISK_SIZE VM_PV_SIZE
CRC_DISK=60
aap_demo_capacity_resolve_crc_sizes
[ "$CRC_DISK" = 140 ]
[ "$CRC_PV_SIZE" = 30 ]

[ "$(aap_demo_capacity_minimum_disk 70)" = 180 ]

infra_exec_cmd() {
  printf '%s\n' "${MOCK_DISK_VALUES}"
}

MOCK_DISK_VALUES="50 45 5"
warning=$(aap_demo_capacity_warn_enable ao "" 2>&1)
grep -q 'Disk capacity planning warning' <<<"$warning"
grep -q 'Continuing without resize' <<<"$warning"
grep -q '20% disk growth' <<<"$warning"

MOCK_DISK_VALUES="200 100 100"
warning=$(aap_demo_capacity_warn_enable ao "" 2>&1)
[ -z "$warning" ]

echo "✓ storage capacity calculations, overrides, PV sizing, and warnings"
