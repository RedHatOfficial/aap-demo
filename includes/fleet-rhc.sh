#!/usr/bin/env bash

fleet_rhc_connect() {
  if [ "$#" -ne 0 ]; then
    _err "Usage: aap-demo fleet rhc-connect (running Fleet VMs only)"
    return 1
  fi
  local nodes username password command row index port failed=false
  nodes=$(fleet_access_inventory omit) || return 1
  nodes=$(jq -c '[.[] | select(.state == "running")]' <<<"$nodes") || return 1
  [ "$nodes" != '[]' ] || { _err "No running Fleet nodes to enroll"; return 1; }
  username=$(aap_demo_vault_get "$FLEET_CDN_USERNAME_KEY") || {
    _err "Cannot read CDN username; run aap-demo fleet auth configure"; return 1;
  }
  password=$(aap_demo_vault_get "$FLEET_CDN_PASSWORD_KEY") || {
    _err "Cannot read CDN password; run aap-demo fleet auth configure"; return 1;
  }
  [ -n "$username" ] && [ -n "$password" ] || { _err "CDN credentials are empty"; return 1; }
  # Code, not credentials, enters the remote command. JSON credentials use SSH stdin.
  printf -v command 'sudo python3 -c %q' "$(cat "${FLEET_ACCESS_DIR}/../scripts/fleet-rhc-connect.py")"
  echo "Enrolling running Fleet VMs with Red Hat (RHSM, Insights, remote management)..."
  while IFS= read -r row; do
    index=$(jq -r '.index' <<<"$row")
    port=$(jq -r '.ssh_port' <<<"$row")
    echo "  Fleet node $index:"
    if ! (
      set -o pipefail
      printf '%s\0%s' "$username" "$password" |
        python3 -c 'import json,sys; u,p=sys.stdin.read().split("\0",1); json.dump({"username":u,"password":p},sys.stdout)' |
        fleet_stack_ssh "$port" "$command"
    ); then
      _err "Red Hat connection failed for Fleet node $index"
      failed=true
    fi
  done < <(jq -c '.[]' <<<"$nodes")
  unset username password
  if [ "$failed" = true ]; then return 1; fi
  echo "✓ All running Fleet nodes have verified Red Hat connections"
  echo "CRC is not enrolled: its OSTree appliance lacks rhc/insights-client; installation is deferred."
}
