#!/usr/bin/env bash
# =============================================================================
# cmd-dashboard.sh — Dashboard and OpenShift console command handlers
# =============================================================================
#
# Extracted from aap-demo.sh. Expects the caller to have sourced
# aap-demo-paths.sh and preset.sh, and to define SCRIPT_DIR and
# DASHBOARD_NO_OPEN.

# Guard against double-sourcing
if [ -n "${_AAP_DEMO_CMD_DASHBOARD_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_CMD_DASHBOARD_LOADED=1

cmd_dashboard() {
  local dashboard_script="${SCRIPT_DIR}/dashboard/server.py"
  local args=(--repo-root "$SCRIPT_DIR" --background)
  if [ ! -f "$dashboard_script" ]; then
    echo "ERROR: Dashboard server not found: $dashboard_script" >&2
    return 1
  fi
  if [ "$DASHBOARD_NO_OPEN" = true ]; then
    args+=(--no-open)
  fi
  python3 "$dashboard_script" "${args[@]}"
}

# Print (and optionally open) the OpenShift web console. Only the full
# OpenShift preset ships one; MicroShift does not.
cmd_console() {
  local preset url
  preset="$(aap_demo_detect_crc_preset)"
  if [ "$preset" != "openshift" ]; then
    echo "The ${preset} preset has no OpenShift web console." >&2
    echo "  Recreate with the full OpenShift preset: CRC_PRESET=openshift aap-demo create --full-demo" >&2
    return 1
  fi
  if ! command -v crc >/dev/null 2>&1; then
    echo "ERROR: crc not found" >&2
    return 1
  fi
  url="$(crc console --url 2>/dev/null | tail -1)"
  if [ -z "$url" ]; then
    echo "ERROR: OpenShift console URL unavailable (is the cluster running? crc status)" >&2
    return 1
  fi
  echo "OpenShift console: $url"
  crc console --credentials 2>/dev/null | sed 's/^/  /' | sed -E 's/(-p )[^ ]+/\1********/'
  echo "  (full credentials: crc console --credentials)"
  if [ "$DASHBOARD_NO_OPEN" != true ]; then
    xdg-open "$url" >/dev/null 2>&1 || open "$url" >/dev/null 2>&1 || true
  fi
}

# Best-effort: open the OpenShift console when the full preset is in use.
_aap_demo_auto_console() {
  [ "${AAP_DEMO_CONSOLE_AUTOOPEN:-true}" = false ] && return 0
  [ "$(aap_demo_detect_crc_preset)" = "openshift" ] || return 0
  cmd_console >/dev/null 2>&1 || true
  return 0
}

# Best-effort: start/reuse the dashboard after a successful lifecycle command.
# Opt out with AAP_DEMO_DASHBOARD_AUTOSTART=false.
_aap_demo_auto_dashboard() {
  [ "${AAP_DEMO_DASHBOARD_AUTOSTART:-true}" = false ] && return 0
  if [ "$(uname -s)" = Linux ] && [ ! -e "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/aap-demo-dashboard.desktop" ]; then
    source "${SCRIPT_DIR}/includes/state-service.sh"
    aap_demo_dashboard_autostart_install --always 2>/dev/null || true
  fi
  cmd_dashboard || echo "WARNING: Could not start the dashboard (run: aap-demo dashboard)" >&2
  _aap_demo_auto_console
  return 0
}

