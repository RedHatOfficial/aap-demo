#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../includes/galaxy-auth.sh
source "${REPO_ROOT}/includes/galaxy-auth.sh"

ACTION="${1:-status}"
UNIT_NAME="aap-demo-token-keepalive"
LINUX_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
MAC_LABEL="com.github.aap-demo.token-keepalive"
MAC_PLIST="$HOME/Library/LaunchAgents/${MAC_LABEL}.plist"
LOG_DIR="${AAP_DEMO_DIR:-$HOME/.aap-demo}/logs"
LOG_FILE="$LOG_DIR/token-keepalive.log"
CRON_MARKER="# aap-demo-hub-token-keepalive"

log_result() {
  local code="$1" message="$2"
  printf '%s rc=%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$code" "$message"
}

notify_invalid() {
  local message="$1"
  case "$(uname -s)" in
    Linux)
      command -v notify-send >/dev/null 2>&1 &&
        notify-send --urgency=critical "aap-demo offline token needs renewal" "$message" || true
      ;;
    Darwin)
      command -v osascript >/dev/null 2>&1 &&
        osascript -e "display notification \"${message//\"/\\\"}\" with title \"aap-demo offline token needs renewal\" sound name \"Basso\"" \
          >/dev/null 2>&1 || true
      ;;
  esac
}

check_token() {
  local label="$1" key="$2" client_id="$3" required="${4:-false}" token rc
  if token=$(aap_demo_vault_get "$key"); then
    :
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      if [ "$required" = true ]; then
        log_result 1 "$label token is missing; run 'aap-demo credentials keepalive setup'"
        return 1
      fi
      log_result 0 "$label token is not configured; skipped"
      return 0
    fi
    log_result 2 "$label Vault could not be read; credentials were not changed"
    return 2
  fi
  if galaxy_offline_token_status "$token" "$client_id"; then
    log_result 0 "$label offline token is live"
    return 0
  else
    rc=$?
  fi
  unset token
  if [ "$rc" -eq 2 ]; then
    log_result 2 "$label token could not be checked: Red Hat SSO is unavailable or returned an invalid response"
    return 2
  fi
  log_result 1 "$label offline token was rejected by Red Hat SSO"
  notify_invalid "$label token was rejected. Run the corresponding aap-demo credential command to replace it."
  return 1
}

run_checks() {
  local invalid=false unreachable=false rc
  check_token "Red Hat Customer Portal" "aap_demo.redhat.offline_token" "rhsm-api" || {
    rc=$?
    [ "$rc" -eq 1 ] && invalid=true
    [ "$rc" -eq 2 ] && unreachable=true
  }
  check_token "Automation Hub" "ah_offline_token" "cloud-services" || {
    rc=$?
    [ "$rc" -eq 1 ] && invalid=true
    [ "$rc" -eq 2 ] && unreachable=true
  }
  [ "$invalid" = false ] || return 1
  [ "$unreachable" = false ] || return 2
  return 0
}

read_crontab() {
  local target="$1" errors="$2" rc
  LC_ALL=C crontab -l >"$target" 2>"$errors" && return 0
  rc=$?
  # A first-time user has no crontab; permission and daemon errors must not erase one.
  if [ "$rc" -eq 1 ] && grep -q '^no crontab for ' "$errors"; then
    : >"$target"
    return 0
  fi
  _err "Unable to read the user crontab; existing jobs were not changed"
  return 1
}

cron_quote() {
  case "$1" in
    *$'\n'* | *$'\r'*) _err "Cron paths and settings must not contain newlines"; return 1 ;;
  esac
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

manage_cron() (
  local action="$1" work line setting quoted
  command -v crontab >/dev/null 2>&1 || {
    _err "crontab is required; install and enable your platform's cron service"
    return 1
  }
  work=$(mktemp -d) || return 1
  trap 'rm -f "$work/current" "$work/errors" "$work/updated"; rmdir "$work"' EXIT
  read_crontab "$work/current" "$work/errors" || return 2
  if [ "$action" = status ]; then
    grep -F "$CRON_MARKER" "$work/current"
    return $?
  fi
  grep -v -F "$CRON_MARKER" "$work/current" >"$work/updated" || {
    [ "$?" -eq 1 ] || return 1
  }
  if [ "$action" = install ]; then
    line="0 0 */4 * * /usr/bin/env"
    for setting in "HOME=$HOME" "PATH=$PATH" \
      "AAP_DEMO_VAULT_FILE=$AAP_DEMO_VAULT_FILE" \
      "AAP_DEMO_VAULT_PASSWORD_FILE=$AAP_DEMO_VAULT_PASSWORD_FILE" \
      "AAP_DEMO_ANSIBLE_VAULT=$AAP_DEMO_ANSIBLE_VAULT" \
      "AAP_DEMO_VAULT_PYTHON=$AAP_DEMO_VAULT_PYTHON" \
      "$BASH" "$SCRIPT_DIR/aap-demo-token-keepalive.sh" run-hub; do
      quoted=$(cron_quote "$setting") || return 1
      line+=" $quoted"
    done
    # Cron treats percent signs specially even inside shell quotes.
    printf '%s %s\n' "${line//%/\\%}" "$CRON_MARKER" >>"$work/updated"
  fi
  if ! cmp -s "$work/current" "$work/updated"; then
    crontab "$work/updated" || {
      _err "Unable to update the user crontab"
      return 1
    }
  fi
)

install_linux() {
  mkdir -p "$LINUX_UNIT_DIR"
  chmod 700 "$LINUX_UNIT_DIR"
  cat >"$LINUX_UNIT_DIR/${UNIT_NAME}.service" <<EOF
[Unit]
Description=aap-demo offline-token keepalive

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash "${SCRIPT_DIR}/aap-demo-token-keepalive.sh" run
EOF
  cat >"$LINUX_UNIT_DIR/${UNIT_NAME}.timer" <<EOF
[Unit]
Description=Run aap-demo offline-token keepalive daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
Unit=${UNIT_NAME}.service

[Install]
WantedBy=timers.target
EOF
  chmod 600 "$LINUX_UNIT_DIR/${UNIT_NAME}.service" "$LINUX_UNIT_DIR/${UNIT_NAME}.timer"
  systemctl --user daemon-reload
  systemctl --user enable --now "${UNIT_NAME}.timer"
  systemctl --user start "${UNIT_NAME}.service"
}

install_macos() {
  mkdir -p "$(dirname "$MAC_PLIST")" "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  cat >"$MAC_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${MAC_LABEL}</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/env</string><string>bash</string>
    <string>${SCRIPT_DIR}/aap-demo-token-keepalive.sh</string><string>run</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>0</integer></dict>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${LOG_FILE}</string>
  <key>StandardErrorPath</key><string>${LOG_FILE}</string>
</dict></plist>
EOF
  chmod 600 "$MAC_PLIST"
  plutil -lint "$MAC_PLIST" >/dev/null
  launchctl bootout "gui/$(id -u)/${MAC_LABEL}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$MAC_PLIST"
}

status_keepalive() {
  local rc
  if command -v crontab >/dev/null 2>&1; then
    if manage_cron status; then
      return 0
    else
      rc=$?
    fi
    [ "$rc" -ne 2 ] || return 2
  fi
  case "$(uname -s)" in
    Linux)
      if [ ! -f "$LINUX_UNIT_DIR/${UNIT_NAME}.timer" ]; then
        echo "aap-demo token keepalive is not enabled"
        return 1
      fi
      systemctl --user --no-pager status "${UNIT_NAME}.timer" || return 1
      systemctl --user list-timers "${UNIT_NAME}.timer" --no-pager
      ;;
    Darwin)
      if [ ! -f "$MAC_PLIST" ]; then
        echo "aap-demo token keepalive is not enabled"
        return 1
      fi
      launchctl print "gui/$(id -u)/${MAC_LABEL}"
      [ ! -f "$LOG_FILE" ] || tail -n 5 "$LOG_FILE"
      ;;
    *) printf 'Unsupported platform\n' >&2; return 1 ;;
  esac
}

disable_keepalive() {
  if command -v crontab >/dev/null 2>&1; then
    manage_cron remove || return 1
  fi
  case "$(uname -s)" in
    Linux)
      if [ -f "$LINUX_UNIT_DIR/${UNIT_NAME}.timer" ]; then
        systemctl --user disable --now "${UNIT_NAME}.timer" || return 1
        rm -f "$LINUX_UNIT_DIR/${UNIT_NAME}.service" "$LINUX_UNIT_DIR/${UNIT_NAME}.timer"
        systemctl --user daemon-reload || return 1
      fi
      ;;
    Darwin)
      launchctl bootout "gui/$(id -u)/${MAC_LABEL}" >/dev/null 2>&1 || true
      rm -f "$MAC_PLIST"
      ;;
    *) printf 'Unsupported platform\n' >&2; return 1 ;;
  esac
  echo "✓ aap-demo token keepalive disabled"
}

case "$ACTION" in
  setup)
    _aap_demo_vault_require_tools || exit 1
    for path in "$AAP_DEMO_VAULT_FILE" "$AAP_DEMO_VAULT_PASSWORD_FILE" \
      "$AAP_DEMO_ANSIBLE_VAULT" "$AAP_DEMO_VAULT_PYTHON"; do
      case "$path" in
        /*) ;;
        *) _err "Cron requires absolute Vault, password-file, and tool paths"; exit 1 ;;
      esac
    done
    command -v crontab >/dev/null 2>&1 || {
      _err "crontab is required for the four-day keepalive"
      exit 1
    }
    ensure_galaxy_credentials || exit $?
    manage_cron install || exit 1
    echo "✓ Automation Hub token validated; Vault-backed cron enabled (0 0 */4 * *)"
    ;;
  enable)
    run_checks || {
      rc=$?
      [ "$rc" -eq 2 ] || exit "$rc"
      echo "WARNING: Red Hat SSO is unreachable; installing the keepalive for a later retry." >&2
    }
    case "$(uname -s)" in
      Linux) install_linux ;;
      Darwin) install_macos ;;
      *) echo "ERROR: Token keepalive supports Linux and macOS" >&2; exit 1 ;;
    esac
    echo "✓ aap-demo token keepalive enabled"
    ;;
  status) status_keepalive ;;
  disable) disable_keepalive ;;
  run) run_checks ;;
  run-hub) check_token "Automation Hub" "ah_offline_token" "cloud-services" true ;;
  *)
    echo "Usage: aap-demo credentials keepalive [setup|enable|status|disable|run]" >&2
    exit 2
    ;;
esac
