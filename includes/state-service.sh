#!/usr/bin/env bash

aap_demo_dashboard_autostart_install() {
  local launcher_args="${1:-}"
  local directory="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
  local launcher="${SCRIPT_DIR}/scripts/aap-demo-dashboard-login.sh"
  mkdir -p "$directory" || return 1
  # Escape Desktop Entry quoted arguments, including literal field-code markers.
  launcher="${launcher//\\/\\\\}"
  launcher="${launcher//\"/\\\"}"
  launcher="${launcher//\`/\\\`}"
  launcher="${launcher//\$/\\\$}"
  launcher="${launcher//%/%%}"
  cat >"$directory/aap-demo-dashboard.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=AAP Demo Dashboard
Comment=Open the local dashboard when AAP demo boot recovery is enabled
Exec=bash "$launcher"${launcher_args:+ $launcher_args}
Terminal=false
EOF
}

aap_demo_dashboard_autostart_remove() {
  rm -f -- "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/aap-demo-dashboard.desktop"
}

aap_demo_service_managed() {
  if [ "$(uname -s)" = Darwin ]; then
    [ "${AAP_DEMO_SERVICE_INTERNAL:-0}" != 1 ] \
      && [ -f "$HOME/Library/Application Support/aap-demo/enabled" ]
    return
  fi
  [ "${AAP_DEMO_SERVICE_INTERNAL:-0}" != 1 ] \
    && [ -r /etc/aap-demo/owner ] \
    && [ "$(cat /etc/aap-demo/owner)" = "$(id -un)" ] \
    && systemctl is-enabled --quiet aap-demo.service
}

aap_demo_service_lifecycle() {
  if [ "$(uname -s)" = Darwin ]; then
    bash "${SCRIPT_DIR}/scripts/aap-demo-macos-state.sh" "$1"
    return
  fi
  case "$1" in
    stop) sudo systemctl stop aap-demo.service ;;
    start | restart) sudo systemctl restart aap-demo.service ;;
    *) _err "Unsupported service lifecycle action: $1"; return 1 ;;
  esac
}

cmd_service() {
  case "$(uname -s)" in
    Darwin)
      bash "${SCRIPT_DIR}/scripts/aap-demo-macos-state.sh" "$@"
      return
      ;;
    Linux)
      command -v systemctl >/dev/null || {
        _err "The Linux state service requires a running systemd host; WSL users should use Windows login recovery"
        return 1
      }
      ;;
    *)
      _err "Use the native PowerShell CLI for Windows login recovery"
      return 1
      ;;
  esac
  local action="${1:-status}"
  shift || true
  case "$action" in
    install)
      local keep=1 force_stop=false stop_timeout=120
      if [ "${AAP_DEMO_DIR:-$HOME/.aap-demo}" != "$HOME/.aap-demo" ] \
        || [ "${AAP_DEMO_CONFIG:-$HOME/.aap-demo/config}" != "$HOME/.aap-demo/config" ] \
        || [ "${AAP_DEMO_VAULT_FILE:-$HOME/.ansible/conf/env.yml}" != "$HOME/.ansible/conf/env.yml" ] \
        || [ "${AAP_DEMO_VAULT_PASSWORD_FILE:-$HOME/.ansible/conf/.vaultpass.txt}" != "$HOME/.ansible/conf/.vaultpass.txt" ]; then
        _err "The state service currently supports standard local state and credential paths only"
        return 1
      fi
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --keep | --stop-timeout)
            [ "$#" -ge 2 ] || { _err "Missing value for $1"; return 1; }
            if [ "$1" = --keep ]; then keep="$2"; else stop_timeout="$2"; fi
            shift 2
            ;;
          --force-stop) force_stop=true; shift ;;
          *) _err "Usage: aap-demo service install [--keep N] [--force-stop] [--stop-timeout SECONDS]"; return 1 ;;
        esac
      done
      if ! [[ "$keep" =~ ^[1-9][0-9]*$ ]]; then
        _err "Retention must be a positive integer"
        return 1
      fi
      if ! [[ "$stop_timeout" =~ ^[1-9][0-9]*$ ]] \
        || [ "${#stop_timeout}" -gt 5 ] || [ "$stop_timeout" -gt 86400 ]; then
        _err "Stop timeout must be between 1 and 86400 seconds"
        return 1
      fi
      sudo bash "${SCRIPT_DIR}/scripts/aap-demo-state.sh" install "$(id -un)" \
        "$HOME" "$SCRIPT_DIR" "$keep" "$force_stop" "$stop_timeout" || return 1
      aap_demo_dashboard_autostart_install || {
        _err "Boot recovery is installed, but dashboard desktop autostart could not be installed"
        return 1
      }
      # Self-healing watchdog for the CRC vsock SSH forward (user timer).
      bash "${SCRIPT_DIR}/scripts/aap-demo-crc-watchdog.sh" install || {
        _err "Boot recovery is installed, but the CRC watchdog timer could not be installed"
        return 1
      }
      ;;
    retention)
      [ "$#" -eq 1 ] || { _err "Usage: aap-demo service retention N"; return 1; }
      [[ "$1" =~ ^[1-9][0-9]*$ ]] || { _err "Retention must be a positive integer"; return 1; }
      sudo /usr/local/libexec/aap-demo-state retention "$1"
      ;;
    status)
      systemctl status aap-demo.service --no-pager
      ;;
    backups)
      sudo /usr/local/libexec/aap-demo-state list
      ;;
    backup)
      if systemctl is-active --quiet aap-demo.service; then
        sudo systemctl restart aap-demo.service
      else
        sudo /usr/local/libexec/aap-demo-state save \
          && sudo systemctl start aap-demo.service
      fi
      ;;
    disable)
      sudo systemctl disable --now aap-demo.service || return 1
      aap_demo_dashboard_autostart_remove
      bash "${SCRIPT_DIR}/scripts/aap-demo-crc-watchdog.sh" uninstall || true
      ;;
    *)
      _err "Usage: aap-demo service {install [--keep N]|retention N|status|backups|backup|disable}"
      return 1
      ;;
  esac
}
