#!/usr/bin/env bash

if [ -n "${_FLEET_STACK_LOADED:-}" ]; then return 0; fi
_FLEET_STACK_LOADED=1
FLEET_STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fleet_stack_ssh() {
  local port="$1"
  shift
  ssh -p "$port" -i "${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet/ssh_key" \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet/known_hosts" \
    -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes ansible@127.0.0.1 "$@"
}

fleet_stack_validate_hosts() {
  awk '
    /^#/ || NF == 0 {next}
    {
      if (NF < 3 || split($1, octets, ".") != 4) exit 1
      for(i=1;i<=4;i++) if(octets[i] !~ /^[0-9]+$/ || octets[i]+0 > 255) exit 1
      for(i=2;i<=NF;i++) {
        if(length($i)>253 || $i !~ /^[a-zA-Z0-9.-]+$/) exit 1
        count=split($i, labels, ".")
        for(j=1;j<=count;j++)
          if(length(labels[j])>63 || labels[j] !~ /^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$/) exit 1
        if(tolower($i) in seen) exit 1
        seen[tolower($i)]=1
      }
    }
  '
}

fleet_reconcile_stack() {
  local inventory running gateway domain nodes routes row index port name fqdn key hostkey
  local stack_hosts stack_keys="" stack_config="" stack_known_hosts=""
  inventory=$(fleet_access_inventory omit) || return 1
  running=$(jq -c '[.[] | select(.state == "running")]' <<<"$inventory") || return 1
  [ "$running" != '[]' ] || return 0
  domain="${FLEET_DOMAIN:-fleet.aap-demo.test}"
  [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]] || {
    _err "Invalid Fleet domain"; return 1;
  }
  if [[ "$OSTYPE" == darwin* ]]; then
    local iface
    iface=$(route -n get default | awk '/interface:/{print $2}') || return 1
    gateway=$(ifconfig "$iface" | awk '/inet /{print $2;exit}') || return 1
  else
    gateway=$(ip -4 route get 1.1.1.1 | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}') || return 1
  fi
  [ -n "$gateway" ] || { _err "Cannot determine Fleet host gateway"; return 1; }
  nodes=$(kubectl get nodes -o json) || { _err "Cannot discover stack machines"; return 1; }
  routes=$(kubectl get routes -A -o json) || { _err "Cannot discover stack routes"; return 1; }
  if ! jq -e '(.items | type == "array" and length > 0)
    and all(.items[]; (.metadata.name | type == "string")
      and (.status.addresses | type == "array"))' <<<"$nodes" >/dev/null; then
    _err "Invalid cluster machine discovery response"; return 1
  fi
  # Some routes (e.g. the OpenShift preset's openshift-ingress-canary) have no
  # spec.host. Require a valid namespace on every route, but only require a
  # host on routes that carry one.
  if ! jq -e '(.items | type == "array")
    and all(.items[]; (.metadata.namespace | type == "string")
      and ((.spec.host // "") | type == "string"))' <<<"$routes" >/dev/null; then
    _err "Invalid route discovery response"; return 1
  fi
  stack_hosts="# Fleet names use the host gateway; SSH config selects forwarded ports."
  stack_hosts+=$'\n'"$gateway aap-demo-host.$domain aap-demo-host"
  while IFS= read -r row; do
    name=$(jq -r '.metadata.name' <<<"$row")
    key=$(jq -r '[.status.addresses[] | select(.type=="InternalIP") | .address | select(contains(":")|not)][0] // empty' <<<"$row")
    [ -n "$key" ] || { _err "Missing IPv4 address for cluster node $name"; return 1; }
    fqdn="$name"
    [[ "$fqdn" == *.* ]] || fqdn="$name.$domain"
    stack_hosts+=$'\n'"$key $fqdn ${name%%.*}"
  done < <(jq -c '.items[]' <<<"$nodes")
  # Routes resolving to localhost on the host must point to its ingress listener from VMs.
  while IFS= read -r name; do
    stack_hosts+=$'\n'"$gateway $name ${name%%.*}"
  done < <(jq -r '[.items[] | select(.metadata.namespace | test("^(openshift-|kube-)") | not) | .spec.host] | unique[]' <<<"$routes")
  while IFS= read -r row; do
    name=$(jq -r '.hostname' <<<"$row")
    stack_hosts+=$'\n'"$gateway $name.$domain $name"
  done < <(jq -c '.[]' <<<"$inventory")
  printf '%s\n' "$stack_hosts" | fleet_stack_validate_hosts || {
    _err "Stack hosts contain invalid or conflicting addresses/names; no files updated"; return 1;
  }
  while IFS= read -r row; do
    port=$(jq -r '.ssh_port' <<<"$row")
    name=$(jq -r '.hostname' <<<"$row")
    fqdn="$name.$domain"
    key=$(fleet_stack_ssh "$port" 'sudo cat /home/admin/.ssh/id_ed25519.pub' </dev/null) || return 1
    [[ "$key" == ssh-ed25519\ * && "$key" != *$'\n'* ]] || { _err "Invalid public key for $name"; return 1; }
    stack_keys+="$key"$'\n'
    hostkey=$(fleet_stack_ssh "$port" 'sudo cat /etc/ssh/ssh_host_ed25519_key.pub' </dev/null) || return 1
    [[ "$hostkey" == ssh-ed25519\ * && "$hostkey" != *$'\n'* ]] || { _err "Invalid host key for $name"; return 1; }
    stack_known_hosts+="$fqdn $hostkey"$'\n'
    stack_config+="Host $name $fqdn"$'\n'
    stack_config+="    HostName $gateway"$'\n'
    stack_config+="    Port $port"$'\n'
    stack_config+="    User admin"$'\n'
    stack_config+="    IdentityFile ~/.ssh/id_ed25519"$'\n'
    stack_config+="    IdentitiesOnly yes"$'\n'
    stack_config+="    HostKeyAlias $fqdn"$'\n'
    stack_config+="    UserKnownHostsFile ~/.ssh/aap-demo-known_hosts"$'\n'
    stack_config+="    StrictHostKeyChecking yes"$'\n'
  done < <(jq -c '.[]' <<<"$running")
  stack_config+=$'Host *\n'
  while IFS= read -r row; do
    index=$(jq -r '.index' <<<"$row")
    port=$(jq -r '.ssh_port' <<<"$row")
    if ! {
      printf 'set -euo pipefail\n'
      printf 'stack_hosts=%q\nstack_keys=%q\nstack_config=%q\nstack_known_hosts=%q\n' \
        "$stack_hosts" "${stack_keys%$'\n'}" "$stack_config" "$stack_known_hosts"
      cat "$FLEET_STACK_DIR/fleet-stack-remote.sh"
    } | fleet_stack_ssh "$port" 'sudo bash -s'; then
      _err "Stack reconciliation failed on Fleet node $index"; return 1
    fi
  done < <(jq -c '.[]' <<<"$running")
  printf '  ✓ Fleet public keys, SSH aliases, and full-stack hosts reconciled\n'
}
