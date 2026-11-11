#!/usr/bin/env bash
# Argument parsing helpers for Fleet subcommands.

if [ -n "${_FLEET_CLI_LOADED:-}" ]; then return 0; fi
_FLEET_CLI_LOADED=1

fleet_parse_add_args() {
  FLEET_ADD_COUNT=1
  FLEET_ADD_IMAGE="${FLEET_IMAGE:-}"
  local count_seen=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --image)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          _err "--image requires a QCOW2 path"
          return 1
        fi
        FLEET_ADD_IMAGE="$2"
        shift 2
        ;;
      --image=*)
        FLEET_ADD_IMAGE="${1#*=}"
        if [ -z "$FLEET_ADD_IMAGE" ]; then
          _err "--image requires a QCOW2 path"
          return 1
        fi
        shift
        ;;
      [0-9]*)
        if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -lt 1 ]; then
          _err "Fleet node count must be a positive integer: $1"
          return 1
        fi
        if [ "$count_seen" = true ]; then
          _err "Fleet node count was specified more than once"
          return 1
        fi
        FLEET_ADD_COUNT="$1"
        count_seen=true
        shift
        ;;
      *)
        _err "Unexpected argument for 'fleet add': $1"
        echo "  Usage: aap-demo fleet add [count] --image <rhel9|rhel10|local-qcow2-path>"
        return 1
        ;;
    esac
  done
}
