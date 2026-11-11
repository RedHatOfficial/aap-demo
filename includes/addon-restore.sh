#!/usr/bin/env bash
# Dependency-safe restoration of addons after a full cluster rebuild.

if [ -n "${_AAP_DEMO_ADDON_RESTORE_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_ADDON_RESTORE_LOADED=1

aap_demo_validate_redeploy_addon_capacity() {
  local saved_addons="$1"
  local memory_mb="${CRC_MEMORY:-16384}"

  if echo " $saved_addons " | grep -q " apme-eap " \
    && { echo " $saved_addons " | grep -q " ao " \
      || echo " $saved_addons " | grep -q " ollama "; } \
    && [ "$memory_mb" -lt 24576 ]; then
    _err "Configured addons require at least 24 GiB of CRC memory"
    echo "  APME cannot run with AO/Ollama in the current $((memory_mb / 1024)) GiB cluster."
    echo "  Set CRC_MEMORY=24576 in ~/.aap-demo/config, then retry."
    return 1
  fi
}

aap_demo_preserve_addon_selection() {
  local saved_addons="$1"
  _addons_save "$(printf '%s' "$saved_addons" | tr ' ' ',')"
}

aap_demo_order_addons_for_restore() {
  local saved_addons="$1"
  local ordered="" addon

  for addon in mcp-server ollama setup-pah; do
    if echo " $saved_addons " | grep -q " $addon "; then
      ordered="${ordered}${ordered:+ }${addon}"
    fi
  done

  for addon in $saved_addons; do
    case "$addon" in
      mcp-server | ollama | setup-pah | ao) ;;
      *) ordered="${ordered}${ordered:+ }${addon}" ;;
    esac
  done

  if echo " $saved_addons " | grep -q " ao "; then
    ordered="${ordered}${ordered:+ }ao"
  fi

  printf '%s\n' "$ordered"
}

aap_demo_restore_addons() {
  local saved_addons="$1"
  local ordered_addons addon
  ordered_addons=$(aap_demo_order_addons_for_restore "$saved_addons")
  [ -n "$ordered_addons" ] || return 0

  echo ""
  printf "\033[1mRestoring configured addons...\033[0m\n"
  echo ""

  for addon in $ordered_addons; do
    echo "Restoring addon: $addon"
    if ! FORCE=true QUIET=true cmd_enable "$addon"; then
      _err "Failed to restore addon: $addon"
      return 1
    fi
  done

  echo ""
  echo "Restoring addon integrations..."
  _aap_demo_run_addon_wire true || {
    _err "Failed to restore addon integrations"
    return 1
  }
  echo "✓ Configured addons and integrations restored"
}
