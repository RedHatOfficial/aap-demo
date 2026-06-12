#!/usr/bin/env bash
# =============================================================================
# infra-api.sh — Infrastructure abstraction dispatch layer
# =============================================================================
#
# Provides backend-agnostic functions for interacting with the cluster host.
# Each function dispatches to the active backend (minc, vm) via INFRA_TYPE.
#
# Usage:
#   source "${SCRIPT_DIR}/includes/infra-api.sh"
#
#   infra_exec_cmd systemctl restart crio
#   infra_copy_to ./pull-secret.json /etc/crio/openshift-pull-secret
#   infra_copy_from /var/lib/microshift/resources/kubeadmin/kubeconfig ./kubeconfig
#   infra_service_action restart crio
#   infra_get_kubeconfig ~/.aap-demo/kubeconfig.microshift
#
# =============================================================================

# Guard against double-sourcing
if [ -n "$_INFRA_API_LOADED" ]; then return 0; fi
_INFRA_API_LOADED=1

# Load the active backend
_infra_load_backend() {
  local backend_file="${SCRIPT_DIR}/includes/infra-${INFRA_TYPE}.sh"
  if [ ! -f "$backend_file" ]; then
    echo "ERROR: No backend implementation for --infra ${INFRA_TYPE}"
    echo "  Expected: ${backend_file}"
    return 1
  fi
  source "$backend_file"
}

# Lazy-load backend on first call
_infra_ensure_backend() {
  if [ -z "$_INFRA_BACKEND_LOADED" ]; then
    _infra_load_backend || return 1
    _INFRA_BACKEND_LOADED=1
  fi
}

# ---------------------------------------------------------------------------
# Dispatch functions
# ---------------------------------------------------------------------------

# Execute a command on the cluster host
# Usage: infra_exec_cmd <command> [args...]
infra_exec_cmd() {
  _infra_ensure_backend || return 1
  "_infra_${INFRA_TYPE}_exec_cmd" "$@"
}

# Copy a file to the cluster host
# Usage: infra_copy_to <local_src> <remote_dest>
infra_copy_to() {
  _infra_ensure_backend || return 1
  "_infra_${INFRA_TYPE}_copy_to" "$@"
}

# Copy a file from the cluster host
# Usage: infra_copy_from <remote_src> <local_dest>
infra_copy_from() {
  _infra_ensure_backend || return 1
  "_infra_${INFRA_TYPE}_copy_from" "$@"
}

# Perform a systemctl action on a service
# Usage: infra_service_action <action> <service>
#   action: start, stop, restart, reload, is-active
infra_service_action() {
  _infra_ensure_backend || return 1
  "_infra_${INFRA_TYPE}_service_action" "$@"
}

# Get the cluster state
# Returns: running, stopped, not_created
infra_get_state() {
  _infra_ensure_backend || return 1
  "_infra_${INFRA_TYPE}_get_state"
}

# Extract kubeconfig to a local path
# Usage: infra_get_kubeconfig <local_dest>
infra_get_kubeconfig() {
  _infra_ensure_backend || return 1
  "_infra_${INFRA_TYPE}_get_kubeconfig" "$@"
}

# Find the container/VM name (for status display)
# Returns the name or empty string
infra_get_name() {
  _infra_ensure_backend || return 1
  "_infra_${INFRA_TYPE}_get_name"
}
