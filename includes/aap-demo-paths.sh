#!/usr/bin/env bash
# =============================================================================
# aap-demo-paths.sh — Shared path constants for aap-demo
# =============================================================================

# Guard against double-sourcing
if [ -n "${_AAP_DEMO_PATHS_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_PATHS_LOADED=1

AAP_DEMO_DIR="${AAP_DEMO_DIR:-$HOME/.aap-demo}"
AAP_DEMO_KUBECONFIG="${AAP_DEMO_KUBECONFIG:-$AAP_DEMO_DIR/kubeconfig.microshift}"

# Resolve kubeconfig path (read-only discovery). Returns the write target even when
# missing; callers that read the file must still test -f/-s before use.
aap_demo_resolve_kubeconfig() {
  if [ -n "${1:-}" ]; then
    echo "$1"
    return 0
  fi
  if [ -f "$AAP_DEMO_KUBECONFIG" ]; then
    echo "$AAP_DEMO_KUBECONFIG"
  elif [ -f "$AAP_DEMO_DIR/kubeconfig" ]; then
    echo "$AAP_DEMO_DIR/kubeconfig"
  elif [ -f "$HOME/.crc/machines/crc/kubeconfig" ]; then
    echo "$HOME/.crc/machines/crc/kubeconfig"
  else
    echo "$AAP_DEMO_KUBECONFIG"
  fi
}
