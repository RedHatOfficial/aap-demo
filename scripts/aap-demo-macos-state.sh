#!/usr/bin/env bash
# Cold checkpoints and user-login recovery for CRC's macOS vfkit backend.

mac_state_init() {
  MAC_STATE_ROOT="$HOME/Library/Application Support/aap-demo"
  MAC_STATE_PLIST="$HOME/Library/LaunchAgents/com.aap-demo.recovery.plist"
  MAC_STATE_LABEL="gui/$(id -u)/com.aap-demo.recovery"
  MAC_STATE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
}

mac_state_error() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

mac_state_cli() {
  QUIET=true AAP_DEMO_SERVICE_INTERNAL=1 AAP_DEMO_TRUST_CA=false \
    bash "$MAC_STATE_REPO/aap-demo.sh" "$@"
}

mac_state_status() {
  crc status -o json | jq -er '.crcStatus | select(. == "Running" or . == "Stopped")'
}

mac_state_wait_daemon() {
  local deadline=$((SECONDS + 120))
  until launchctl list com.redhat.crc.daemon >/dev/null 2>&1 \
    && mac_state_status >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || {
      mac_state_error "CRC daemon is not available; complete 'crc setup' in this user account"; return 1;
    }
    sleep 2
  done
}

mac_state_paths() {
  local path
  for path in "$HOME/.crc" "$HOME/.aap-demo" "$HOME/.ansible" "$HOME/.ansible/conf" \
    "$HOME/.ansible/conf/env.yml" "$HOME/.ansible/conf/.vaultpass.txt" \
    "$HOME/Library" "$HOME/Library/Application Support" "$MAC_STATE_ROOT"; do
    [ ! -L "$path" ] || {
      mac_state_error "Recovery does not support externally linked state paths: $path"; return 1;
    }
  done
}

mac_state_layout() {
  local dir
  mac_state_paths || return 1
  for dir in "$HOME/.crc" "$HOME/.aap-demo"; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || {
      mac_state_error "Expected a real local directory: $dir"; return 1;
    }
  done
  jq -e --arg store "$HOME/.crc" '
    .DriverName == "vfkit" and .Driver.ImageFormat == "raw"
    and (.Driver.StorePath == $store or .Driver.StorePath == ($store + "/machines"))
    and ((.Driver.SharedDirs // []) | length == 0)
  ' "$HOME/.crc/machines/crc/config.json" >/dev/null || {
    mac_state_error "Recovery requires standard vfkit/raw CRC storage with no external shared directories"
    return 1
  }
  [ -f "$HOME/.crc/machines/crc/crc.img" ] \
    && [ ! -L "$HOME/.crc/machines/crc/crc.img" ] || {
    mac_state_error "CRC raw disk is missing or externally linked"; return 1;
  }
}

mac_state_stopped() {
  local meta pid
  [ "$(mac_state_status)" = Stopped ] || {
    mac_state_error "CRC must be stopped before disk access"; return 1;
  }
  for meta in "$HOME"/.aap-demo/fleet/node-*/meta; do
    [ -f "$meta" ] || continue
    pid=$(sed -n 's/^PID=//p' "$meta")
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      mac_state_error "Fleet PID $pid is still alive; refusing cold disk access"
      return 1
    fi
  done
}

mac_state_stop() {
  local meta pid index deadline command
  for meta in "$HOME"/.aap-demo/fleet/node-*/meta; do
    [ -f "$meta" ] || continue
    pid=$(sed -n 's/^PID=//p' "$meta")
    index=$(sed -n 's/^INDEX=//p' "$meta")
    [[ "$index" =~ ^[1-9][0-9]*$ ]] || {
      mac_state_error "Invalid Fleet metadata: $meta"; return 1;
    }
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      command=$(ps -p "$pid" -o comm=) || return 1
      [[ "$command" == *qemu-system* ]] || {
        mac_state_error "Fleet PID $pid belongs to another process"; return 1;
      }
      ssh -i "$HOME/.aap-demo/fleet/ssh_key" -p "$((2200 + index))" \
        -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null ansible@127.0.0.1 \
        'sudo -n systemd-run --on-active=2s /usr/bin/systemctl poweroff' || return 1
      deadline=$((SECONDS + 120))
      while kill -0 "$pid" 2>/dev/null; do
        [ "$SECONDS" -lt "$deadline" ] || {
          mac_state_error "Fleet guest shutdown timed out; no forced stop attempted"; return 1;
        }
        sleep 1
      done
    fi
  done
  if [ "$(mac_state_status)" = Running ]; then
    mac_state_cli stop || return 1
  fi
  mac_state_stopped
}

mac_state_copy() {
  rsync -aS --exclude='*.sock' --exclude='*.log' --exclude='*.pid' \
    --exclude='operation.lock' "$@"
}

mac_state_verify() (
  cd "$1" || exit 1
  [ -f COMPLETE ] && [ -s SHA256SUMS ] || exit 1
  shasum -a 256 -c SHA256SUMS >/dev/null || exit 1
  jq -e --arg home "$HOME" --arg arch "$(uname -m)" \
    '.home == $home and .arch == $arch and .format == 1' metadata.json >/dev/null
)

mac_state_prune() {
  local latest path count=1 keep
  latest=$(cat "$MAC_STATE_ROOT/latest") || return 1
  keep=$(cat "$MAC_STATE_ROOT/retention") || return 1
  [[ "$keep" =~ ^[1-9][0-9]*$ ]] || { mac_state_error "Invalid retention"; return 1; }
  while IFS= read -r path; do
    [ -f "$path/COMPLETE" ] || continue
    [ "${path##*/}" != "$latest" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$keep" ]; then
      case "$path" in
        "$MAC_STATE_ROOT"/states/state-*) rm -rf -- "$path" || return 1 ;;
        *) mac_state_error "Unsafe retention path"; return 1 ;;
      esac
    fi
  done < <(find "$MAC_STATE_ROOT/states" -type d -name 'state-*' -prune | sort -r)
}

mac_state_save() (
  local stage name disk meta required available
  mac_state_layout || exit 1
  mac_state_stopped || exit 1
  umask 077
  mkdir -p "$MAC_STATE_ROOT/states" || exit 1
  required=$(du -sk "$HOME/.crc" "$HOME/.aap-demo" |
    awk '{sum += $1} END {printf "%.0f", sum * 2}')
  available=$(df -Pk "$MAC_STATE_ROOT" | awk 'NR == 2 {print $4}')
  [[ "$required" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] \
    && [ "$available" -ge "$required" ] || {
    mac_state_error "Insufficient host space for a full cold checkpoint"; exit 1;
  }
  stage=$(mktemp -d "$MAC_STATE_ROOT/states/.incomplete.XXXXXX") || exit 1
  trap 'rm -rf -- "$stage"' EXIT
  mkdir -p "$stage/payload/crc" "$stage/payload/demo" "$stage/payload/vault" || exit 1
  mac_state_copy "$HOME/.crc/" "$stage/payload/crc/" || exit 1
  mac_state_copy "$HOME/.aap-demo/" "$stage/payload/demo/" || exit 1
  for name in env.yml .vaultpass.txt; do
    if [ -e "$HOME/.ansible/conf/$name" ]; then
      [ ! -L "$HOME/.ansible/conf/$name" ] || {
        mac_state_error "External credential symlinks are not supported"; exit 1;
      }
      cp -p "$HOME/.ansible/conf/$name" "$stage/payload/vault/$name" || exit 1
    fi
  done
  for disk in "$HOME"/.aap-demo/fleet/node-*/disk.qcow2; do
    [ -f "$disk" ] || continue
    command -v qemu-img >/dev/null || {
      mac_state_error "qemu-img is required for Fleet recovery"; exit 1;
    }
    name="${disk#"$HOME/.aap-demo/"}"
    rm -f "$stage/payload/demo/$name" || exit 1
    qemu-img convert -O qcow2 "$disk" "$stage/payload/demo/$name" || exit 1
    qemu-img check "$stage/payload/demo/$name" || exit 1
  done
  for meta in "$stage"/payload/demo/fleet/node-*/meta; do
    [ -f "$meta" ] || continue
    sed -i.bak -e 's/^PID=.*/PID=/' -e 's/^STATUS=.*/STATUS=stopped/' "$meta" || exit 1
    rm -f "$meta.bak" || exit 1
  done
  jq -n --arg home "$HOME" --arg arch "$(uname -m)" \
    '{format:1, home:$home, arch:$arch}' >"$stage/metadata.json" || exit 1
  (cd "$stage" && find payload metadata.json -type f -exec shasum -a 256 {} + >SHA256SUMS) || exit 1
  touch "$stage/COMPLETE" || exit 1
  mac_state_verify "$stage" || exit 1
  name="state-$(date -u +%Y%m%dT%H%M%S)-${stage##*.}"
  mv "$stage" "$MAC_STATE_ROOT/states/$name" || exit 1
  printf '%s\n' "$name" >"$MAC_STATE_ROOT/latest.tmp" || exit 1
  mv "$MAC_STATE_ROOT/latest.tmp" "$MAC_STATE_ROOT/latest" || exit 1
  sync || exit 1
  mac_state_prune
)

mac_state_latest() {
  local name
  name=$(cat "$MAC_STATE_ROOT/latest") || return 1
  [[ "$name" =~ ^state-[0-9]{8}T[0-9]{6}-[a-zA-Z0-9]+$ ]] || {
    mac_state_error "Invalid latest checkpoint reference"; return 1;
  }
  printf '%s/states/%s\n' "$MAC_STATE_ROOT" "$name"
}

mac_state_restore() {
  local latest name
  latest=$(mac_state_latest) || return 1
  mac_state_verify "$latest" || { mac_state_error "Checkpoint verification failed"; return 1; }
  mac_state_paths || return 1
  mac_state_stopped || return 1
  touch "$MAC_STATE_ROOT/restore-pending" || return 1
  mac_state_copy --delete "$latest/payload/crc/" "$HOME/.crc/" || return 1
  mac_state_copy --delete "$latest/payload/demo/" "$HOME/.aap-demo/" || return 1
  mkdir -p "$HOME/.ansible/conf" || return 1
  for name in env.yml .vaultpass.txt; do
    if [ -f "$latest/payload/vault/$name" ]; then
      cp -p "$latest/payload/vault/$name" "$HOME/.ansible/conf/$name" || return 1
    else
      rm -f "$HOME/.ansible/conf/$name" || return 1
    fi
  done
  # Refresh the existing CRC daemon after restoring its disk/config metadata.
  launchctl stop com.redhat.crc.daemon || return 1
  launchctl start com.redhat.crc.daemon || return 1
  mac_state_wait_daemon || return 1
  rm -f "$MAC_STATE_ROOT/restore-pending"
}

mac_state_checkpoint() {
  [ ! -f "$MAC_STATE_ROOT/restore-pending" ] || {
    mac_state_error "An interrupted restore must be retried with 'aap-demo start' before saving"; return 1;
  }
  sysctl -n kern.boottime >"$MAC_STATE_ROOT/checkpoint-pending" || return 1
  mac_state_stop && mac_state_save || return 1
  rm -f "$MAC_STATE_ROOT/checkpoint-pending"
}

mac_state_start() {
  local boot
  boot=$(sysctl -n kern.boottime) || return 1
  if [ -f "$MAC_STATE_ROOT/checkpoint-pending" ] \
    && [ "$(cat "$MAC_STATE_ROOT/checkpoint-pending")" = "$boot" ]; then
    mac_state_error "The last checkpoint failed; retry 'aap-demo service backup' before recovery"
    return 1
  fi
  if [ ! -f "$MAC_STATE_ROOT/restore-pending" ] && [ "$(mac_state_status)" = Running ]; then
    mac_state_checkpoint || return 1
  fi
  mac_state_restore || return 1
  rm -f "$MAC_STATE_ROOT/checkpoint-pending"
  mac_state_cli start
}

mac_state_plist() {
  local xml
  xml=$(jq -nr --arg s "$MAC_STATE_REPO/scripts/aap-demo-macos-state.sh" '$s | @html')
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.aap-demo.recovery</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$xml</string><string>login</string></array>
<key>RunAtLoad</key><true/>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>$(jq -nr --arg s "$PATH" '$s | @html')</string></dict>
<key>StandardOutPath</key><string>$(jq -nr --arg s "$MAC_STATE_ROOT/recovery.log" '$s | @html')</string>
<key>StandardErrorPath</key><string>$(jq -nr --arg s "$MAC_STATE_ROOT/recovery.log" '$s | @html')</string>
</dict></plist>
EOF
}

mac_state_main() {
  local action="${1:-status}" keep=1 tool
  shift || true
  [ "$(uname -s)" = Darwin ] || { mac_state_error "This runner requires macOS"; return 1; }
  mac_state_init
  for tool in crc jq rsync shasum launchctl plutil; do
    command -v "$tool" >/dev/null || { mac_state_error "Missing tool: $tool"; return 1; }
  done
  for tool in AAP_DEMO_DIR AAP_DEMO_CONFIG AAP_DEMO_VAULT_FILE AAP_DEMO_VAULT_PASSWORD_FILE; do
    [ -z "${!tool:-}" ] || case "$tool:${!tool}" in
      "AAP_DEMO_DIR:$HOME/.aap-demo" | "AAP_DEMO_CONFIG:$HOME/.aap-demo/config" \
        | "AAP_DEMO_VAULT_FILE:$HOME/.ansible/conf/env.yml" \
        | "AAP_DEMO_VAULT_PASSWORD_FILE:$HOME/.ansible/conf/.vaultpass.txt") ;;
      *) mac_state_error "Recovery requires standard state/credential paths ($tool)"; return 1 ;;
    esac
  done
  umask 077
  mac_state_paths || return 1
  mkdir -p "$MAC_STATE_ROOT"
  chmod 700 "$MAC_STATE_ROOT"
  # shellcheck source=../includes/operation-lock.sh
  source "$MAC_STATE_REPO/includes/operation-lock.sh"
  aap_demo_acquire_operation_lock "macOS recovery $action" || return 1
  case "$action" in
    start | restart | login | stop | backup | disable)
      [ -f "$MAC_STATE_ROOT/enabled" ] || {
        mac_state_error "Login recovery is not installed; run 'aap-demo service install'"; return 1;
      }
      ;;
  esac
  case "$action" in
    install)
      if [ "$#" -ne 0 ]; then
        [ "$#" -eq 2 ] && [ "$1" = --keep ] || {
          mac_state_error "Usage: aap-demo service install [--keep N]"; return 1;
        }
        keep="$2"
      fi
      [[ "$keep" =~ ^[1-9][0-9]*$ ]] || { mac_state_error "Retention must be positive"; return 1; }
      [ ! -f "$MAC_STATE_ROOT/enabled" ] || {
        mac_state_error "Disable the login recovery service before reinstalling"; return 1;
      }
      mac_state_layout || return 1
      printf '%s\n' "$keep" >"$MAC_STATE_ROOT/retention"
      echo "macOS recovery uses explicit cold checkpoints and restore at user login, not a shutdown hook."
      echo "Backups contain credentials. Verify recovery before relying on it; checkpoint before reboot."
      if [ ! -f "$MAC_STATE_ROOT/restore-pending" ]; then
        mac_state_checkpoint || return 1
      fi
      mac_state_start || return 1
      mkdir -p "$(dirname "$MAC_STATE_PLIST")"
      mac_state_plist >"$MAC_STATE_PLIST"
      plutil -lint "$MAC_STATE_PLIST" || return 1
      touch "$MAC_STATE_ROOT/enabled"
      # Already running after validation. Bootstrap at next login, not mid-session.
      echo "Recovery enabled for next login. Checkpoint before reboot: aap-demo stop"
      ;;
    start | restart | login)
      mac_state_wait_daemon || return 1
      mac_state_start
      ;;
    stop) mac_state_checkpoint ;;
    backup) mac_state_checkpoint && mac_state_start ;;
    retention)
      [ "$#" -eq 1 ] && [[ "$1" =~ ^[1-9][0-9]*$ ]] || {
        mac_state_error "Usage: aap-demo service retention N (positive integer)"; return 1;
      }
      printf '%s\n' "$1" >"$MAC_STATE_ROOT/retention"
      ;;
    status)
      if [ -f "$MAC_STATE_ROOT/enabled" ]; then
        echo "Login recovery enabled; backup on explicit stop/checkpoint (NOT host shutdown)."
        echo "Log: $MAC_STATE_ROOT/recovery.log"
        if launchctl print "$MAC_STATE_LABEL" >/dev/null 2>&1; then
          launchctl print "$MAC_STATE_LABEL"
        else
          echo "LaunchAgent not loaded in this session; it loads at the next login."
        fi
      else
        echo "Login recovery disabled."
      fi
      ;;
    backups)
      if [ -d "$MAC_STATE_ROOT/states" ]; then
        find "$MAC_STATE_ROOT/states" -type f -name COMPLETE -print
      else
        echo "No completed checkpoints."
      fi
      ;;
    disable)
      mac_state_checkpoint || return 1
      if launchctl print "$MAC_STATE_LABEL" >/dev/null 2>&1; then
        launchctl bootout "$MAC_STATE_LABEL" || return 1
      fi
      rm -f "$MAC_STATE_PLIST" "$MAC_STATE_ROOT/enabled"
      ;;
    *) mac_state_error "Unknown service action: $action"; return 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  mac_state_main "$@"
fi
