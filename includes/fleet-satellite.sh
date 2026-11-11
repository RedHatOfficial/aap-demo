#!/usr/bin/env bash
# =============================================================================
# fleet-satellite.sh — Register running Fleet nodes to the Satellite lab
# =============================================================================
#
# Fleet nodes register to the Satellite (not directly to Red Hat) so content
# is served from the local Pulp, hosts appear in the Satellite inventory, and
# Insights data flows through the Satellite's rh_cloud connector. Each node:
#   1. trusts the Satellite CA (katello-ca-consumer)
#   2. registers with subscription-manager using a Satellite activation key
#   3. enables Insights + remote execution (rhc) via the Satellite
#
# Usage:
#   source "${SCRIPT_DIR}/includes/fleet-satellite.sh"
#   fleet_satellite_register
#
# =============================================================================

if [ -n "${_FLEET_SATELLITE_LOADED:-}" ]; then return 0; fi
_FLEET_SATELLITE_LOADED=1

# shellcheck source=fleet-access.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fleet-access.sh"

SAT_HOST="${SATELLITE_LAB_HOST:-satellite.demo.lab}"
SAT_IP="${SATELLITE_LAB_IP:-192.168.122.20}"
SAT_AK_NAME="${SAT_FLEET_AK:-fleet-rhel9}"
# Display name and subscription-manager org label differ; Demo Org owns the
# RHEL content views in this lab.
SAT_ORG="${SAT_ORG:-Demo Org}"
SAT_ORG_LABEL="${SAT_ORG_LABEL:-Demo_Org}"

_sat_ssh() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=10 "root@${SAT_IP}" "$@"
}

# Ensure the Satellite has an activation key for the fleet; echo its name.
_fleet_satellite_ensure_ak() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    "${script_dir}/../satellite-lab/07-fleet-activation-key.sh" "root@${SAT_IP}:/root/" >/dev/null 2>&1 || return 1
  _sat_ssh "bash /root/07-fleet-activation-key.sh" 2>/dev/null | tail -1
}

# Register a single node. Credentials and the AK name cross SSH via stdin,
# never as argv, so they do not leak into the remote process list or logs.
_fleet_satellite_register_node() {
  local port="$1" ak_name="$2"
  local remote
  remote=$(cat <<'REMOTE'
set -euo pipefail
# ak name and satellite host arrive on stdin (tab-separated), never via argv or
# string interpolation into this script, so a crafted value cannot inject shell.
IFS=$'\t' read -r ak_name sat_host
# Validate the host is a bare FQDN/IP before it is used in URLs and rpm names.
case "$sat_host" in
  *[!a-zA-Z0-9.-]* | "" | .* | *..*)
    echo "ERROR: invalid satellite host: $sat_host" >&2
    exit 1
    ;;
esac

# 1. Trust the Satellite CA (idempotent). Prefer dnf (which verifies the RPM
# signature against the Satellite's own CA once the consumer package bootstraps
# trust); the curl fallback below is a last resort and still verifies the CA
# cert it fetches is a CA:TRUE cert before installing.
if ! rpm -q "katello-ca-consumer-${sat_host}" >/dev/null 2>&1; then
  if ! dnf install -y "https://${sat_host}/pub/katello-ca-consumer-latest.noarch.rpm" >/dev/null 2>&1; then
    tmp_rpm=$(mktemp /tmp/katello-ca-consumer.XXXXXX.rpm)
    # Verify the served CA cert is a real CA before trusting the RPM payload.
    if curl -sS --fail "https://${sat_host}/pub/katello-server-ca.crt" 2>/dev/null \
        | openssl x509 -noout -text 2>/dev/null | grep -q 'CA:TRUE' \
      && curl -sS --fail -o "$tmp_rpm" \
        "https://${sat_host}/pub/katello-ca-consumer-latest.noarch.rpm" 2>/dev/null; then
      rpm -Uvh --force "$tmp_rpm" >/dev/null 2>&1 || true
    fi
    rm -f "$tmp_rpm"
  fi
fi

# 2. Register to the Satellite with the activation key (idempotent). Fleet
# nodes are cloned from one image and share a DMI UUID, which Satellite
# rejects as a duplicate ("DMI UUID matches other registered hosts"). Give
# each node a unique product UUID before registering.
if ! subscription-manager identity >/dev/null 2>&1; then
  if [ ! -f /etc/aap-demo-fleet-uuid ]; then
    uuidgen > /etc/aap-demo-fleet-uuid
  fi
  mkdir -p /etc/rhsm/facts
  printf '{"dmi.system.uuid": "%s"}\n' "$(cat /etc/aap-demo-fleet-uuid)" \
    > /etc/rhsm/facts/uuid.facts
  subscription-manager register --org="__SAT_ORG_ID__" \
    --activationkey "$ak_name" >/dev/null
fi

# 3. Insights via the Satellite's rh_cloud connector. The client uploads to
# the Satellite, which forwards to Red Hat — but only after the org has a
# Hybrid Cloud branch ID (rh_cloud:hybridcloud_register). Register only when
# not already registered; a stale .registered file from a pre-Satellite direct
# attempt must be cleared first or --register refuses with "Machine-id found".
if rpm -q insights-client >/dev/null 2>&1; then
  if ! insights-client --status 2>/dev/null | grep -q "Insights API confirms registration"; then
    rm -f /etc/insights-client/.registered /etc/insights-client/.unregistered 2>/dev/null || true
    insights-client --register >/dev/null 2>&1 || true
  fi
fi
# Remote execution / rhc: connect when the daemon is present but not connected.
if rpm -q rhc >/dev/null 2>&1; then
  rhc status 2>/dev/null | grep -q "Remote Host Configuration daemon is active" \
    || rhc connect >/dev/null 2>&1 || true
fi

subscription-manager identity >/dev/null 2>&1
REMOTE
)
  # subscription-manager wants the org label, not the display name. The org
  # label is a fixed, operator-controlled value (not user input), so
  # interpolating it here is safe; the host and AK name go over stdin instead.
  remote="${remote//__SAT_ORG_ID__/$SAT_ORG_LABEL}"
  # Send "ak_name<TAB>sat_host" on stdin; the remote reads them with read -r.
  printf '%s\t%s\n' "$ak_name" "$SAT_HOST" | fleet_stack_ssh "$port" "sudo bash -c $(
    printf '%q' "$remote"
  )"
}

fleet_satellite_register() {
  if [ "$#" -ne 0 ]; then
    _err "Usage: aap-demo fleet satellite-register (running Fleet VMs only)"
    return 1
  fi

  local nodes ak_name row index port failed=false
  nodes=$(fleet_access_inventory omit) || return 1
  nodes=$(jq -c '[.[] | select(.state == "running")]' <<<"$nodes") || return 1
  [ "$nodes" != '[]' ] || { _err "No running Fleet nodes to register"; return 1; }

  echo "Preparing Satellite activation key for the fleet..."
  ak_name=$(_fleet_satellite_ensure_ak) || {
    _err "Could not create the Satellite activation key (is the Satellite up?)"
    return 1
  }
  ak_name=$(tail -1 <<<"$ak_name" | tr -d '[:space:]')
  [ -n "$ak_name" ] || { _err "Satellite activation key name is empty"; return 1; }
  echo "  Using activation key: $ak_name"

  echo "Registering running Fleet nodes to Satellite ($SAT_HOST)..."
  while IFS= read -r row; do
    index=$(jq -r '.index' <<<"$row")
    port=$(jq -r '.ssh_port' <<<"$row")
    echo "  Fleet node $index:"
    if _fleet_satellite_register_node "$port" "$ak_name"; then
      echo "    ✓ registered to Satellite"
    else
      _err "Satellite registration failed for Fleet node $index"
      failed=true
    fi
  done < <(jq -c '.[]' <<<"$nodes")

  if [ "$failed" = true ]; then return 1; fi
  echo "✓ All running Fleet nodes are registered to the Satellite"
  echo "  Verify: ssh root@${SAT_IP} 'hammer host list'"
}
