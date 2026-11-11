#!/usr/bin/env bash
# =============================================================================
# preset.sh — Canonical CRC preset detection for aap-demo
# =============================================================================
#
# Single source of truth for the configured CRC preset. Resolution order:
#   1. CRC_PRESET environment variable
#   2. CRC_PRESET in ~/.aap-demo/config (or $AAP_DEMO_CONFIG)
#   3. `crc config get preset`
#   4. Default: microshift
#
# This module has no dependencies beyond aap-demo-paths.sh (AAP_DEMO_DIR) so it
# is safe to source before the infra backend is loaded.

# Guard against double-sourcing
if [ -n "${_AAP_DEMO_PRESET_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_PRESET_LOADED=1

if [ -z "${_AAP_DEMO_PATHS_LOADED:-}" ]; then
  # shellcheck source=aap-demo-paths.sh
  source "$(dirname "${BASH_SOURCE[0]}")/aap-demo-paths.sh"
fi

aap_demo_detect_crc_preset() {
  if [ -n "${CRC_PRESET:-}" ]; then
    echo "$CRC_PRESET"
    return 0
  fi

  local config="${AAP_DEMO_CONFIG:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/config}"
  if [ -f "$config" ]; then
    local saved
    saved=$(grep '^CRC_PRESET=' "$config" 2>/dev/null | cut -d= -f2)
    if [ -n "$saved" ]; then
      echo "$saved"
      return 0
    fi
  fi

  if command -v crc >/dev/null 2>&1; then
    local preset_raw
    preset_raw=$(crc config get preset 2>&1 || true)
    if ! echo "$preset_raw" | grep -q "not set"; then
      local preset
      preset=$(echo "$preset_raw" | awk '{print $NF}')
      if [ -n "$preset" ]; then
        echo "$preset"
        return 0
      fi
    fi
  fi

  echo "microshift"
  return 0
}

# Route domain for the configured preset. MicroShift uses the nip.io baseDomain
# aap-demo writes into the VM; full OpenShift keeps CRC's apps-crc.testing.
aap_demo_route_domain() {
  if [ "$(aap_demo_detect_crc_preset)" = "openshift" ]; then
    echo "apps-crc.testing"
  else
    echo "apps.127.0.0.1.nip.io"
  fi
}

# Path to the kubeadmin kubeconfig inside the CRC VM (MicroShift only; the
# OpenShift preset uses the kubeconfig CRC writes to ~/.crc/machines/crc).
aap_demo_microshift_kubeconfig_vm_path() {
  echo "/var/lib/microshift/resources/kubeadmin/kubeconfig"
}
