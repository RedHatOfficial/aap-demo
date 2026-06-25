#!/usr/bin/env bash
# =============================================================================
# infra-crc.sh — CRC backend for infra abstraction
# =============================================================================
#
# Implements infra_*() functions for the CRC (OpenShift Local) backend.
# Operations use SSH to the CRC VM.
#
# =============================================================================

# Guard against double-sourcing
if [ -n "$_INFRA_CRC_LOADED" ]; then return 0; fi
_INFRA_CRC_LOADED=1

# CRC SSH port
CRC_SSH_PORT=2222

# Detect SSH key — CRC creates id_ed25519 (OpenShift) or id_ecdsa (MicroShift)
_detect_crc_ssh_key() {
  local base="${HOME}/.crc/machines/crc"
  if [ -f "${base}/id_ed25519" ]; then
    echo "${base}/id_ed25519"
  elif [ -f "${base}/id_ecdsa" ]; then
    echo "${base}/id_ecdsa"
  else
    return 1
  fi
}

CRC_SSH_KEY="$(_detect_crc_ssh_key 2>/dev/null || echo "${HOME}/.crc/machines/crc/id_ed25519")"
CRC_SSH_OPTS="-i ${CRC_SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# ---------------------------------------------------------------------------
# SSH helpers
# ---------------------------------------------------------------------------

_crc_exec() {
  ssh -p "$CRC_SSH_PORT" $CRC_SSH_OPTS core@127.0.0.1 "$@"
}

_crc_copy_to() {
  local src="$1" dest="$2"
  local tmp_dest
  tmp_dest="/tmp/infra-copy-$(basename "$dest")"
  scp -P "$CRC_SSH_PORT" $CRC_SSH_OPTS "$src" "core@127.0.0.1:${tmp_dest}"
  _crc_exec sudo cp "$tmp_dest" "$dest"
  _crc_exec sudo rm -f "$tmp_dest"
}

_crc_copy_from() {
  local src="$1" dest="$2"
  scp -P "$CRC_SSH_PORT" $CRC_SSH_OPTS "core@127.0.0.1:${src}" "$dest"
}

# ---------------------------------------------------------------------------
# Backend implementation
# ---------------------------------------------------------------------------

_infra_crc_exec_cmd() {
  _crc_exec sudo "$@"
}

_infra_crc_copy_to() {
  _crc_copy_to "$1" "$2"
}

_infra_crc_copy_from() {
  _crc_copy_from "$1" "$2"
}

_infra_crc_service_action() {
  local action="$1" service="$2"
  _crc_exec sudo systemctl "$action" "$service"
}

_infra_crc_get_state() {
  # Check if CRC is installed
  if ! command -v crc &>/dev/null; then
    echo "not_created"
    return 0
  fi

  # Check CRC status
  local crc_status
  crc_status=$(crc status --output json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('crcStatus','Unknown'))" 2>/dev/null) || crc_status="Unknown"

  case "$crc_status" in
    Running) echo "running" ;;
    Stopped) echo "stopped" ;;
    *) echo "not_created" ;;
  esac
  return 0
}

_infra_crc_get_kubeconfig() {
  local dest="$1"
  _crc_exec sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig >"$dest" 2>/dev/null \
    || cp ~/.crc/machines/crc/kubeconfig "$dest" 2>/dev/null
}

_infra_crc_get_name() {
  local preset
  preset=$(crc config get preset 2>/dev/null | awk '{print $NF}')
  echo "crc-${preset:-microshift}"
}
