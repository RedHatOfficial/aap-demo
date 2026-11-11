#!/usr/bin/env bash
# =============================================================================
# cmd-fleet.sh — fleet QEMU backend (legacy Bash v1)
# =============================================================================
#
# Extracted from aap-demo.sh. Sources the fleet addon modules itself; expects
# the caller to define SCRIPT_DIR and _err. aap-demo.sh keeps the cmd_fleet
# dispatcher, which routes --backend qemu (the default) to cmd_fleet_qemu here
# and --backend kube-native to the Python v2 CLI.

# Guard against double-sourcing
if [ -n "${_AAP_DEMO_CMD_FLEET_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_CMD_FLEET_LOADED=1

cmd_fleet_qemu() {
  local fleet_dir="${SCRIPT_DIR}/addons/fleet"
  if [ ! -f "${fleet_dir}/fleet.sh" ]; then
    _err "Fleet addon not found"
    echo "  Expected: ${fleet_dir}/fleet.sh"
    return 1
  fi

  source "${fleet_dir}/fleet.sh"
  source "${fleet_dir}/fleet-aap.sh"
  source "${fleet_dir}/fleet-auth.sh"
  source "${fleet_dir}/fleet-cli.sh"
  source "${fleet_dir}/fleet-images.sh"
  source "${SCRIPT_DIR}/includes/fleet-rhc.sh"
  source "${SCRIPT_DIR}/includes/fleet-satellite.sh"

  local subcmd="${1:-}"
  shift 2>/dev/null || true

  case "$subcmd" in
    rhc-connect)
      fleet_rhc_connect "$@"
      ;;
    satellite-register)
      fleet_satellite_register "$@"
      ;;
    auth)
      fleet_redhat_auth "${1:-configure}"
      ;;
    add)
      fleet_parse_add_args "$@" || return 1
      local count="$FLEET_ADD_COUNT"
      local image="$FLEET_ADD_IMAGE"

      if [ -z "$image" ]; then
        _err "No QCOW2 image specified"
        echo ""
        echo "Usage: aap-demo fleet add [count] --image <rhel9|rhel10|local-qcow2-path>"
        echo ""
        echo "  count    Number of VMs to create (default: 1)"
        echo "  --image  Path to a RHEL/CentOS QCOW2 cloud image"
        return 1
      fi

      fleet_resolve_image "$image" || return 1
      image="$FLEET_RESOLVED_IMAGE"
      image=$(cd "$(dirname "$image")" 2>/dev/null && echo "$(pwd)/$(basename "$image")")

      _verify_cluster || return 1
      fleet_check_prereqs "$image" || return 1
      fleet_create_all "$count" "$image"
      _fleet_save_image_config "$image"
      fleet_register_aap
      ;;
    start)
      fleet_start_all
      ;;
    node)
      local node_index="${1:-}" node_action="${2:-}"
      [[ "$node_index" =~ ^[1-9][0-9]*$ ]] || { _err "Usage: aap-demo fleet node <index> <start|stop|restart>"; return 1; }
      [[ "$node_action" =~ ^(start|stop|restart)$ ]] || { _err "Usage: aap-demo fleet node <index> <start|stop|restart>"; return 1; }
      fleet_node_power "$node_index" "$node_action"
      ;;
    register)
      _verify_cluster || return 1
      if [ -z "$(_fleet_running_indices)" ]; then
        _err "No running Fleet nodes found"
        echo "  Create nodes first: aap-demo fleet add <count> --image <rhel9|rhel10|local-qcow2-path>"
        return 1
      fi
      fleet_register_aap
      ;;
    ssh)
      local index="${1:-1}" port
      [[ "$index" =~ ^[1-9][0-9]*$ ]] || { _err "Fleet SSH requires a node index"; return 1; }
      port=$(sed -n 's/^PORT=//p' "$FLEET_DIR/node-$index/meta") || return 1
      [[ "$port" =~ ^[0-9]+$ ]] || { _err "Invalid Fleet node port"; return 1; }
      _aap_demo_release_operation_lock
      ssh -t -p "$port" -i "$FLEET_DIR/ssh_key" \
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$FLEET_DIR/known_hosts" admin@127.0.0.1
      ;;
    remove)
      local target="${1:-1}"
      if [[ "$target" =~ ^[0-9]+$ ]]; then
        for narg in "$@"; do
          if [[ "$narg" =~ ^[0-9]+$ ]]; then
            target="$narg"
            break
          fi
        done
        local indices
        indices=$(_fleet_running_indices)
        local to_remove
        to_remove=$(echo "$indices" | tail -n "$target")
        for idx in $to_remove; do
          local hn="aap-fleet-node-${idx}"
          fleet_node_deregister_host "$hn" 2>/dev/null || true
        done
        fleet_remove_last "$target"
      else
        local hn="$target"
        [[ "$hn" != aap-fleet-node-* ]] && hn="aap-fleet-node-${hn}"
        fleet_node_deregister_host "$hn" 2>/dev/null || true
        fleet_remove_by_name "$target"
      fi
      ;;
    list)
      echo ""
      printf "\033[1mFleet Nodes\033[0m\n"
      echo ""
      fleet_list
      ;;
    destroy)
      _verify_cluster 2>/dev/null && fleet_deregister_aap 2>/dev/null || true
      fleet_destroy_all
      ;;
    *)
      echo "Usage: aap-demo fleet <subcommand>"
      echo ""
      echo "Subcommands:"
      echo "  auth [configure|status|reset] Configure Red Hat download authentication"
      echo "  add [count] --image <rhel9|rhel10|local-qcow2-path>"
      echo "                                 Create fleet node VMs"
      echo "  register                     Register existing Fleet VMs in AAP"
      echo "  rhc-connect                  Enroll running Fleet VMs with Red Hat"
      echo "  satellite-register           Register running Fleet VMs to the Satellite lab"
      echo "  start                        Start preserved Fleet VMs"
      echo "  node <index> <start|stop|restart>"
      echo "                               Power-control a single Fleet node"
      echo "  ssh [index]                  Open an admin SSH shell on a Fleet node"
      echo "  remove [count|name]          Remove fleet node VMs"
      echo "  list                         List fleet node VMs"
      echo "  destroy                      Remove all VMs and AAP resources"
      echo ""
      echo "Options:"
      echo "  --image <rhel9|rhel10|local-qcow2-path>"
      echo "                    Local QCOW2 path or entitled RHEL image to download"
      echo "  FLEET_NODE_MEM=N   VM memory in MB (default: 1024)"
      echo "  FLEET_NODE_CPUS=N  VM CPU count (default: 2)"
      echo ""
      echo "Examples:"
      echo "  aap-demo fleet add 3 --image rhel9"
      echo "  aap-demo fleet add 3 --image rhel10"
      echo "  aap-demo fleet add 3 --image ~/rhel9.qcow2"
      echo "  aap-demo fleet register"
      echo "  aap-demo fleet start"
      echo "  aap-demo fleet list"
      echo "  aap-demo fleet remove 1"
      echo "  aap-demo fleet destroy"
      ;;
  esac
}
