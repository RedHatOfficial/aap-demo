#!/usr/bin/env bash
# aap-demo-crc-watchdog.sh — detect and recover a dropped CRC daemon vsock
# forward (the recurring "VM running but MicroShift/SSH unreachable" fault).
#
# The CRC daemon forwards the VM's SSH (port 2222) and API over vsock. Under
# load or after a daemon restart the forward can drop while the VM keeps
# running, leaving the cluster unreachable. This watchdog detects that state
# and recovers it with the least disruptive action that works:
#   1. restart crc-daemon.service (re-establishes the vsock forward), then
#   2. only if that fails, a full crc stop/start (VM reboot) as a last resort.
#
# Usage:
#   aap-demo-crc-watchdog.sh check     # one-shot: detect + recover; exit 0 if healthy
#   aap-demo-crc-watchdog.sh install   # install + enable a systemd user timer
#   aap-demo-crc-watchdog.sh uninstall # remove the timer
#   aap-demo-crc-watchdog.sh status    # show timer + last-run state
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../includes/infra-crc.sh
source "${SCRIPT_DIR}/../includes/infra-crc.sh"

LOCK_DIR="${AAP_DEMO_DIR:-$HOME/.aap-demo}/crc-watchdog.lock"
STATE_FILE="${AAP_DEMO_DIR:-$HOME/.aap-demo}/crc-watchdog.state"
TIMER_NAME="aap-demo-crc-watchdog.timer"
SERVICE_NAME="aap-demo-crc-watchdog.service"

_log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# --- detection --------------------------------------------------------------
# Healthy = VM running AND the SSH forward answers. We treat "VM running but
# SSH refused" as the dropped-forward fault.
#
# Detect the VM state from libvirt directly, not `crc status`: when the daemon
# loses its route to the VM, `crc status` errors out ("not setup correctly"),
# which would otherwise look like "VM stopped" and skip recovery exactly when
# it is needed.
_vm_running() {
  if command -v virsh >/dev/null 2>&1; then
    [ "$(virsh -c qemu:///system domstate crc 2>/dev/null)" = "running" ] && return 0
  fi
  # Fall back to crc status when virsh is unavailable.
  [ "$(crc status 2>/dev/null | awk -F': *' '/^CRC VM:/ {print $2}')" = "Running" ]
}

_ssh_forward_up() {
  refresh_crc_ssh_config 2>/dev/null || return 1
  [ -n "${CRC_SSH_KEY:-}" ] || return 1
  ssh -p "$CRC_SSH_PORT" "${CRC_SSH_OPTS[@]}" -o ConnectTimeout=5 \
    core@127.0.0.1 'true' 2>/dev/null
}

# --- recovery ---------------------------------------------------------------
_recover() {
  _log "watchdog: dropped vsock forward detected (VM running, SSH refused)"

  # Least disruptive first: restart the daemon to re-establish the forward.
  _log "watchdog: restarting crc-daemon.service"
  systemctl --user restart crc-daemon.service 2>/dev/null || true
  local attempt
  local daemon_retries="${AAP_DEMO_WATCHDOG_DAEMON_RETRIES:-20}"
  local reboot_retries="${AAP_DEMO_WATCHDOG_REBOOT_RETRIES:-40}"
  local retry_sleep="${AAP_DEMO_WATCHDOG_RETRY_SLEEP:-3}"
  for attempt in $(seq 1 "$daemon_retries"); do
    if _ssh_forward_up; then
      _log "watchdog: recovered after daemon restart"
      return 0
    fi
    sleep "$retry_sleep"
  done

  # Last resort: full VM reboot to reset the guest vsock agent.
  _log "watchdog: daemon restart did not recover; rebooting the CRC VM"
  crc stop -f >/dev/null 2>&1 || true
  sleep 5
  crc start >/dev/null 2>&1 || { _log "watchdog: crc start failed"; return 1; }
  for attempt in $(seq 1 "$reboot_retries"); do
    if _ssh_forward_up; then
      _log "watchdog: recovered after VM reboot"
      return 0
    fi
    sleep "$retry_sleep"
  done
  _log "watchdog: FAILED to recover the forward"
  return 1
}

cmd_check() {
  mkdir -p "$(dirname "$LOCK_DIR")"
  # Serialize concurrent watchdog runs.
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    _log "watchdog: another run in progress; skipping"
    return 0
  fi
  trap 'rm -rf "$LOCK_DIR"' EXIT

  if ! _vm_running; then
    _log "watchdog: VM not running; nothing to do"
    printf '%s\n' "vm-stopped $(date -u +%s)" >"$STATE_FILE"
    return 0
  fi
  if _ssh_forward_up; then
    _log "watchdog: healthy"
    printf '%s\n' "healthy $(date -u +%s)" >"$STATE_FILE"
    return 0
  fi
  if _recover; then
    printf '%s\n' "recovered $(date -u +%s)" >"$STATE_FILE"
    return 0
  fi
  printf '%s\n' "failed $(date -u +%s)" >"$STATE_FILE"
  return 1
}

# --- timer install ----------------------------------------------------------
cmd_install() {
  local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$unit_dir"
  cat >"$unit_dir/$SERVICE_NAME" <<EOF
[Unit]
Description=aap-demo CRC vsock forward watchdog

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/aap-demo-crc-watchdog.sh check
EOF
  cat >"$unit_dir/$TIMER_NAME" <<EOF
[Unit]
Description=Run the aap-demo CRC watchdog periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "$TIMER_NAME"
  _log "watchdog: installed and enabled $TIMER_NAME (runs every minute)"
}

cmd_uninstall() {
  systemctl --user disable --now "$TIMER_NAME" 2>/dev/null || true
  rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$TIMER_NAME" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$SERVICE_NAME"
  systemctl --user daemon-reload
  _log "watchdog: uninstalled"
}

cmd_status() {
  systemctl --user status "$TIMER_NAME" --no-pager 2>&1 | head -5 || true
  echo "---"
  [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "no state yet"
}

case "${1:-check}" in
  check) cmd_check ;;
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  status) cmd_status ;;
  *) echo "Usage: $0 {check|install|uninstall|status}" >&2; exit 2 ;;
esac
