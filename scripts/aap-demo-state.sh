#!/usr/bin/env bash
# Root-owned systemd runner; demo CLI commands always run as the installing user.
set -euo pipefail
export LC_ALL=C

state_error() { printf 'ERROR: %s\n' "$*" >&2; }

state_user() {
  runuser -u "$STATE_USER" -- env -i \
    HOME="$STATE_HOME" USER="$STATE_USER" LOGNAME="$STATE_USER" \
    PATH="$STATE_HOME/.local/bin:$STATE_HOME/.crc/bin/oc:$STATE_HOME/.aap-demo/venv/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin" \
    XDG_RUNTIME_DIR="/run/user/$STATE_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$STATE_UID/bus" \
    QUIET=true AAP_DEMO_SERVICE_INTERNAL=1 AAP_DEMO_TRUST_CA=false \
    AAP_DEMO_LOCK_TOKEN="${AAP_DEMO_LOCK_TOKEN:-}" "$@"
}

state_cli() { state_user bash "$STATE_REPO/aap-demo.sh" "$@"; }

state_stopped() {
  local status meta pid
  status=$(virsh -c qemu:///system domstate crc) || return 1
  [ "$status" = "shut off" ] || { state_error "CRC is not shut off; refusing disk access"; return 1; }
  for meta in "$STATE_HOME"/.aap-demo/fleet/node-*/meta; do
    [ -f "$meta" ] || continue
    pid=$(sed -n 's/^PID=//p' "$meta")
    if [[ "$pid" =~ ^[0-9]+$ ]] && [ -e "/proc/$pid" ] \
      && grep -aq 'qemu-system' "/proc/$pid/cmdline"; then
      state_error "Fleet VM PID $pid is still running"
      return 1
    fi
  done
}

state_stop() {
  local meta pid index deadline status
  STATE_CRC_SHUTDOWN=clean
  # Fleet's ordinary stop terminates QEMU. Request guest shutdown first so its
  # filesystem is clean before making a recoverable disk backup.
  for meta in "$STATE_HOME"/.aap-demo/fleet/node-*/meta; do
    [ -f "$meta" ] || continue
    pid=$(sed -n 's/^PID=//p' "$meta")
    index=$(sed -n 's/^INDEX=//p' "$meta")
    [[ "$index" =~ ^[1-9][0-9]*$ ]] || { state_error "Invalid Fleet index in $meta"; return 1; }
    if [[ "$pid" =~ ^[0-9]+$ ]] && [ -e "/proc/$pid" ] \
      && grep -aq 'qemu-system' "/proc/$pid/cmdline"; then
      state_user ssh -i "$STATE_HOME/.aap-demo/fleet/ssh_key" \
        -p "$((2200 + index))" -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "ansible@127.0.0.1" 'sudo -n systemd-run --on-active=2s /usr/bin/systemctl poweroff' || {
        state_error "Fleet node $index could not shut down cleanly; previous backup preserved"
        return 1
      }
      deadline=$((SECONDS + 120))
      while [ -e "/proc/$pid" ]; do
        [ "$SECONDS" -lt "$deadline" ] || { state_error "Fleet node $index shutdown timed out"; return 1; }
        sleep 1
      done
    fi
  done
  status=$(virsh -c qemu:///system domstate crc) || return 1
  if [ "$status" != "shut off" ]; then
    state_stop_crc || return 1
  fi
  state_stopped
}

state_stop_crc() {
  local status deadline
  if state_cli stop; then
    return 0
  fi
  if [ "${STATE_FORCE_STOP:-false}" != true ]; then
    state_error "CRC graceful shutdown failed; forced shutdown is disabled"
    return 1
  fi
  deadline=$((SECONDS + ${STATE_STOP_TIMEOUT:-120}))
  echo "WARNING: CRC graceful shutdown failed; waiting ${STATE_STOP_TIMEOUT:-120} additional seconds before forced power-off." >&2
  while :; do
    status=$(virsh -c qemu:///system domstate crc) || return 1
    [ "$status" != "shut off" ] || return 0
    [ "$status" = running ] || {
      state_error "Unexpected CRC state '$status'; refusing forced power-off"
      return 1
    }
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 1
  done
  echo "WARNING: Forcing CRC power-off after timeout. Unsaved guest data may be lost; this checkpoint is crash-consistent, not a clean shutdown backup." >&2
  virsh -c qemu:///system destroy crc || return 1
  STATE_CRC_SHUTDOWN=forced
}

state_copy() {
  # Do not include process-local sockets, locks or logs in a persistent state.
  rsync -aS --exclude='*.sock' --exclude='*.log' --exclude='operation.lock' \
    --exclude='qemu.pid' "$@"
}

state_verify() (
  cd "$1" || return 1
  test -f COMPLETE || return 1
  test -s SHA256SUMS || return 1
  sha256sum --check --quiet SHA256SUMS
)

state_prune() {
  local path latest count=1
  latest=$(readlink -f "$STATE_ROOT/latest") || return 1
  while IFS= read -r path; do
    [ -f "$path/COMPLETE" ] || continue
    [ "$path" != "$latest" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$STATE_KEEP" ]; then
      # Only concrete completed state directories under this user's state store.
      case "$path" in
        "$STATE_ROOT"/state-*) rm -rf -- "$path" ;;
        *) state_error "Refusing unsafe retention path: $path"; return 1 ;;
      esac
    fi
  done < <(find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'state-*' | sort -r)
}

state_save() (
  local stage final disk relative format meta nvram required available
  state_stopped || return 1
  umask 077
  mkdir -p "$STATE_ROOT" || return 1
  required=$(du -sk "$STATE_HOME/.crc" "$STATE_HOME/.aap-demo" \
    | awk '{sum += $1} END {printf "%.0f", sum * 2}')
  available=$(df -Pk "$STATE_ROOT" | awk 'NR == 2 {print $4}')
  if ! [[ "$required" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] || [ "$available" -lt "$required" ]; then
    state_error "Insufficient backup space (need approximately twice the allocated demo disk footprint)"
    return 1
  fi
  stage=$(mktemp -d "$STATE_ROOT/.incomplete.XXXXXX") || return 1
  trap 'rm -rf -- "$stage"' EXIT
  final="$STATE_ROOT/state-$(date -u +%Y%m%dT%H%M%S%N)-${stage##*.}"
  mkdir -p "$stage/home/.crc" "$stage/home/.aap-demo" "$stage/home/.ansible/conf" "$stage/disks" || return 1
  chown "$STATE_USER:" "$stage/home/.ansible/conf" || return 1
  chmod 700 "$stage/home/.ansible/conf" || return 1
  echo "Saving stopped demo state to $final ..."
  state_copy "$STATE_HOME/.crc/" "$stage/home/.crc/" || return 1
  state_copy "$STATE_HOME/.aap-demo/" "$stage/home/.aap-demo/" || return 1
  for relative in env.yml .vaultpass.txt; do
    if [ -f "$STATE_HOME/.ansible/conf/$relative" ]; then
      if [ -L "$STATE_HOME/.ansible/conf/$relative" ]; then
        state_error "Credential files must be local regular files: $relative"
        return 1
      fi
      cp -a "$STATE_HOME/.ansible/conf/$relative" "$stage/home/.ansible/conf/" || return 1
    fi
  done
  virsh -c qemu:///system dumpxml crc --inactive >"$stage/domain.xml" || return 1
  # All attached disk files are required, including an optional persistent
  # image-store disk. Block-device storage is deliberately unsupported.
  if xmllint --xpath '/domain/devices/disk[@device="disk"]/@type' "$stage/domain.xml" \
    | grep -qvE '^( type="file")+$'; then
    state_error "Backup supports file-backed CRC disks only"
    return 1
  fi
  xmllint --xpath '//disk[@device="disk"]/source/@file' "$stage/domain.xml" \
    | sed -E 's/ file="/\n/g; s/"//g' | sed '/^$/d' >"$stage/disk-paths"
  while IFS= read -r disk; do
    case "$disk" in
      "$STATE_HOME/.crc/"* | "$STATE_HOME/.aap-demo/"*) ;;
      *) state_error "Attached disk outside managed directories: $disk"; return 1 ;;
    esac
    relative="${disk#"$STATE_HOME/"}"
    format=$(qemu-img info --output=json "$disk" | jq -er '.format') || return 1
    # Flatten backing chains: the backup must not depend on a mutable base image.
    rm -f "$stage/home/$relative"
    case "$format" in
      qcow2 | raw) ;;
      *) state_error "Unsupported attached disk format: $format"; return 1 ;;
    esac
    qemu-img convert -f "$format" -O "$format" "$disk" "$stage/home/$relative" || return 1
    chown --reference="$disk" "$stage/home/$relative" || return 1
    chmod --reference="$disk" "$stage/home/$relative" || return 1
    if [ "$format" = qcow2 ]; then
      qemu-img check "$stage/home/$relative" || return 1
    fi
  done <"$stage/disk-paths"
  for disk in "$STATE_HOME"/.aap-demo/fleet/node-*/disk.qcow2; do
    [ -f "$disk" ] || continue
    relative="${disk#"$STATE_HOME/"}"
    rm -f "$stage/home/$relative"
    qemu-img convert -O qcow2 "$disk" "$stage/home/$relative" || return 1
    chown --reference="$disk" "$stage/home/$relative" || return 1
    chmod --reference="$disk" "$stage/home/$relative" || return 1
    qemu-img check "$stage/home/$relative" || return 1
  done
  for meta in "$stage"/home/.aap-demo/fleet/node-*/meta; do
    [ -f "$meta" ] || continue
    sed -i -e 's/^PID=.*/PID=/' -e 's/^STATUS=.*/STATUS=stopped/' "$meta" || return 1
  done
  nvram=$(xmllint --xpath 'string(/domain/os/nvram)' "$stage/domain.xml")
  if [ -n "$nvram" ]; then
    case "$nvram" in
      /var/lib/libvirt/qemu/nvram/crc_VARS.qcow2 | /var/lib/libvirt/qemu/nvram/crc_VARS.fd) ;;
      *) state_error "Unexpected CRC firmware path: $nvram"; return 1 ;;
    esac
    cp -a "$nvram" "$stage/nvram" || return 1
    printf '%s\n' "$nvram" >"$stage/nvram-path" || return 1
  fi
  jq -n --arg user "$STATE_USER" --arg home "$STATE_HOME" \
    --arg created "$(date -u +%FT%TZ)" --arg shutdown "${STATE_CRC_SHUTDOWN:-clean}" \
    '{version:1,user:$user,home:$home,created:$created,crc_shutdown:$shutdown}' >"$stage/manifest.json"
  (
    cd "$stage"
    find home disks domain.xml disk-paths manifest.json -type f -print0 \
      | sort -z | xargs -0 sha256sum >SHA256SUMS
    if [ -f nvram ]; then sha256sum nvram nvram-path >>SHA256SUMS; fi
    touch COMPLETE
  ) || return 1
  state_verify "$stage" || return 1
  sync -f "$stage" || return 1
  mv "$stage" "$final" || return 1
  ln -s "${final##*/}" "$STATE_ROOT/.latest.$$" || return 1
  mv -Tf "$STATE_ROOT/.latest.$$" "$STATE_ROOT/latest" || return 1
  sync -f "$STATE_ROOT" || return 1
  state_prune || return 1
  echo "Completed backup: $final (retaining $STATE_KEEP)"
)

state_restore() {
  local latest nvram
  latest=$(readlink -f "$STATE_ROOT/latest") || return 1
  case "$latest" in
    "$STATE_ROOT"/state-*) ;;
    *) state_error "No valid completed backup selected"; return 1 ;;
  esac
  state_verify "$latest" || { state_error "Backup verification failed; current disks left untouched"; return 1; }
  jq -e --arg user "$STATE_USER" --arg home "$STATE_HOME" \
    '.version == 1 and .user == $user and .home == $home' "$latest/manifest.json" >/dev/null || return 1
  if [ "$(jq -r '.crc_shutdown // "clean"' "$latest/manifest.json")" = forced ]; then
    echo "WARNING: Restoring a crash-consistent checkpoint captured after forced CRC power-off; guest filesystem/application recovery may be required." >&2
  fi
  state_stopped || return 1
  if [ -L "$STATE_HOME/.crc" ] || [ -L "$STATE_HOME/.aap-demo" ] || [ -L "$STATE_HOME/.ansible/conf" ]; then
    state_error "Managed restore directories must not be symbolic links"
    return 1
  fi
  echo "Restoring $latest; local changes after that backup will be replaced."
  state_copy --delete "$latest/home/.crc/" "$STATE_HOME/.crc/" || return 1
  state_copy --delete "$latest/home/.aap-demo/" "$STATE_HOME/.aap-demo/" || return 1
  if [ ! -d "$STATE_HOME/.ansible/conf" ]; then
    state_user mkdir -p "$STATE_HOME/.ansible/conf" || return 1
  fi
  state_copy "$latest/home/.ansible/conf/" "$STATE_HOME/.ansible/conf/" || return 1
  chown "$STATE_USER:" "$STATE_HOME/.ansible/conf" || return 1
  chmod 700 "$STATE_HOME/.ansible/conf" || return 1
  if [ -f "$latest/nvram-path" ]; then
    nvram=$(cat "$latest/nvram-path")
    case "$nvram" in
      /var/lib/libvirt/qemu/nvram/crc_VARS.qcow2 | /var/lib/libvirt/qemu/nvram/crc_VARS.fd)
        cp -a "$latest/nvram" "$nvram" || return 1
        ;;
      *) state_error "Invalid firmware restore path"; return 1 ;;
    esac
  fi
  virsh -c qemu:///system define "$latest/domain.xml" || return 1
  restorecon -RF "$STATE_HOME/.crc/machines/crc" || return 1
  if [ -d "$STATE_HOME/.aap-demo/fleet" ]; then
    restorecon -RF "$STATE_HOME/.aap-demo/fleet" || return 1
  fi
}

state_config_write() {
  local path="$1" tmp
  umask 077
  tmp=$(mktemp "${path}.tmp.XXXXXX") || return 1
  if ! printf 'STATE_USER=%q\nSTATE_UID=%q\nSTATE_HOME=%q\nSTATE_REPO=%q\nSTATE_KEEP=%q\nSTATE_FORCE_STOP=%q\nSTATE_STOP_TIMEOUT=%q\n' \
    "$STATE_USER" "$STATE_UID" "$STATE_HOME" "$STATE_REPO" "$STATE_KEEP" \
    "${STATE_FORCE_STOP:-false}" "${STATE_STOP_TIMEOUT:-120}" >"$tmp" \
    || ! mv "$tmp" "$path"; then
    rm -f "$tmp"
    state_error "Could not save the service configuration"
    return 1
  fi
}

state_unit() {
  cat <<EOF
[Unit]
Description=AAP demo shutdown backup and latest-state boot recovery ($STATE_USER)
Wants=network-online.target
Requires=user@${STATE_UID}.service
After=network-online.target user@${STATE_UID}.service libvirtd.service virtqemud.service
RequiresMountsFor=$STATE_HOME $STATE_REPO /var/lib/aap-demo

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/aap-demo-state start
ExecStop=/usr/local/libexec/aap-demo-state save
TimeoutStartSec=1h
TimeoutStopSec=30min
UMask=0077
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

state_activate() {
  systemctl daemon-reload || return 1
  # Restart also validates upgrades of an already-active installation.
  if ! systemctl restart aap-demo.service; then
    systemctl disable aap-demo.service || return 1
    state_error "Recovery validation failed; automatic recovery is disabled"
    return 1
  fi
  systemctl enable aap-demo.service
}

state_install() {
  STATE_USER="$1" STATE_HOME="$2" STATE_REPO="$3" STATE_KEEP="$4"
  STATE_FORCE_STOP="${5:-false}" STATE_STOP_TIMEOUT="${6:-120}"
  [[ "$STATE_KEEP" =~ ^[1-9][0-9]*$ ]] || { state_error "Retention must be a positive integer"; return 1; }
  [[ "$STATE_FORCE_STOP" = true || "$STATE_FORCE_STOP" = false ]] \
    && [[ "$STATE_STOP_TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
    && [ "${#STATE_STOP_TIMEOUT}" -le 5 ] && [ "$STATE_STOP_TIMEOUT" -le 86400 ] \
    || { state_error "Invalid forced-stop policy or timeout (1-86400 seconds)"; return 1; }
  [ "$(uname -s)" = Linux ] || { state_error "This service requires Linux systemd/libvirt"; return 1; }
  [[ "$STATE_USER" =~ ^[a-z_][a-z0-9_-]*$ && "$STATE_HOME" =~ ^/[a-zA-Z0-9_./-]+$ \
    && "$STATE_REPO" =~ ^/[a-zA-Z0-9_./-]+$ ]] || { state_error "Unsupported service user or path"; return 1; }
  [ "$STATE_HOME" = "$(getent passwd "$STATE_USER" | cut -d: -f6)" ] || return 1
  [ -f "$STATE_REPO/aap-demo.sh" ] || return 1
  [ -f "$STATE_HOME/.crc/machines/crc/config.json" ] || { state_error "Deploy CRC first"; return 1; }
  local tool owner_pid
  for tool in rsync qemu-img xmllint virsh runuser jq sha256sum systemctl restorecon; do
    command -v "$tool" >/dev/null || { state_error "Required tool not found: $tool"; return 1; }
  done
  if [ -f /etc/aap-demo/owner ] && [ "$(cat /etc/aap-demo/owner)" != "$STATE_USER" ]; then
    state_error "The system service is already owned by another user"
    return 1
  fi
  STATE_UID=$(id -u "$STATE_USER")
  [ "$STATE_UID" -ne 0 ] || { state_error "CRC must run as a non-root user"; return 1; }
  if [ -f "$STATE_HOME/.aap-demo/operation.lock/owner" ]; then
    owner_pid=$(sed -n 's/^pid=//p' "$STATE_HOME/.aap-demo/operation.lock/owner")
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$owner_pid" ]; then
      state_error "Another demo operation is running (PID $owner_pid); finish it before installing the service"
      return 1
    fi
  fi
  install -d -m 755 /etc/aap-demo /usr/local/libexec
  install -m 755 "$STATE_REPO/scripts/aap-demo-state.sh" /usr/local/libexec/aap-demo-state
  install -m 644 "$STATE_REPO/includes/operation-lock.sh" /usr/local/libexec/aap-demo-operation-lock.sh
  state_config_write /etc/aap-demo/state.conf
  printf '%s\n' "$STATE_USER" >/etc/aap-demo/owner
  chmod 644 /etc/aap-demo/owner
  state_unit >/etc/systemd/system/aap-demo.service
  systemd-analyze verify /etc/systemd/system/aap-demo.service
  loginctl enable-linger "$STATE_USER"
  state_activate
}

state_boot() {
  if [ -f "$STATE_ROOT/.shutdown-pending" ]; then
    echo "WARNING: The last shutdown backup did not complete; preserving the current disks and configuration, not restoring an older checkpoint." >&2
  fi
  # Live persistent state is authoritative, even after an interrupted shutdown.
  # Automatic checkpoint rollback would discard changes made since that copy.
  echo "Starting the latest persistent CRC and demo state in place."
  # Restarting the daemon on an already-running VM drops the vsock SSH forward
  # (port 2222) and leaves the VM unreachable. Only restart it when the VM is
  # not yet running; a running VM keeps its daemon connection from crc start.
  if [ "$(state_user crc status 2>/dev/null | awk -F': *' '/^CRC VM:/ {print $2}')" != "Running" ]; then
    state_user systemctl --user restart crc-daemon.service || return 1
  fi
  state_cli start || return 1
  state_cli dashboard --no-open || return 1
  rm -f "$STATE_ROOT/.shutdown-pending"
}

state_mark_shutdown() {
  (umask 077; mkdir -p "$STATE_ROOT" \
    && cat /proc/sys/kernel/random/boot_id >"$STATE_ROOT/.shutdown-pending")
}

state_shutdown() {
  state_mark_shutdown || return 1
  state_stop || return 1
  state_save || return 1
  rm -f "$STATE_ROOT/.shutdown-pending"
}

state_main() {
  [ "$EUID" -eq 0 ] || { state_error "Use sudo for state-service operations"; return 1; }
  local action="${1:-}"
  shift || true
  if [ "$action" = install ]; then
    [ "$#" -eq 4 ] || [ "$#" -eq 6 ] || return 1
    state_install "$@"
    return
  fi
  # Only the installed, root-owned configuration is interpreted by this runner.
  source /etc/aap-demo/state.conf
  STATE_ROOT="/var/lib/aap-demo/$STATE_USER/states"
  case "$action" in
    retention)
      [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || { state_error "Retention must be a positive integer"; return 1; }
      STATE_KEEP="$1"
      state_config_write /etc/aap-demo/state.conf
      echo "Retention set to $STATE_KEEP; pruning occurs after the next completed backup."
      return
      ;;
    list)
      if [ -d "$STATE_ROOT" ]; then
        find "$STATE_ROOT" -mindepth 2 -maxdepth 2 -name COMPLETE -printf '%h\n' | sort -r
      fi
      return
      ;;
    start | save) ;;
    *) state_error "Unknown state-service operation: $action"; return 1 ;;
  esac
  if [ -L "$STATE_HOME/.aap-demo" ] || [ -L "$STATE_HOME/.aap-demo/operation.lock" ]; then
    state_error "Service state and operation lock must not be symbolic links"
    return 1
  fi
  state_user mkdir -p "$STATE_HOME/.aap-demo"
  AAP_DEMO_DIR="$STATE_HOME/.aap-demo"
  source /usr/local/libexec/aap-demo-operation-lock.sh
  # Root-owned service PIDs must remain visible to the user's CLI lock check.
  if [ "$action" = save ]; then
    state_mark_shutdown || return 1
  fi
  aap_demo_acquire_operation_lock "service-$action"
  chown "$STATE_USER" "$AAP_DEMO_LOCK_DIR" "$AAP_DEMO_LOCK_DIR/owner"
  state_user systemctl --user start crc-http.socket crc-vsock.socket
  if [ "$action" = save ]; then
    state_shutdown
  else
    state_boot
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  state_main "$@"
fi
