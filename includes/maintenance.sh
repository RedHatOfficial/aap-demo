#!/usr/bin/env bash

if [ -n "${_AAP_DEMO_MAINTENANCE_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_MAINTENANCE_LOADED=1

cmd_maintenance() {
  local action="${1:-preview}" apply="${2:-false}" reconfigure="${3:-false}"

  if [ "$action" = "uninstall" ]; then
    _maintenance_uninstall "$apply" "$reconfigure"
    return
  fi
  if [ "$reconfigure" = true ]; then
    echo "ERROR: --reconfigure is supported only by maintenance uninstall" >&2
    return 1
  fi
  if [ "$action" != "preview" ]; then
    echo "ERROR: Unknown maintenance action: $action" >&2
    echo "Usage: aap-demo maintenance [uninstall] [--apply] [--reconfigure]" >&2
    return 1
  fi

  _infra_ensure_backend || return 1

  echo ""
  echo "aap-demo maintenance - Reclaiming safe-to-remove cluster VM data..."
  echo ""

  infra_exec_cmd bash -s -- "$apply" <<'EOF'
set -euo pipefail

apply="${1:-false}"

disk_snapshot() {
  df -Pk /var | awk 'NR == 2 { print $3, $4, $5 }'
}

print_report() {
  local exited image_refs unique_images
  exited=$(sudo crictl ps -a --state Exited -q | sed '/^$/d' | wc -l)
  image_refs=$(sudo crictl images -q | sed '/^$/d' | wc -l)
  unique_images=$(sudo crictl images -q | sed '/^$/d' | sort -u | wc -l)

  echo "Cluster VM disk:"
  df -hP /var | awk 'NR == 1 || NR == 2 { print "  " $0 }'
  echo ""
  echo "Reclaimable runtime objects:"
  echo "  Exited containers:   ${exited}"
  echo "  Image references:    ${image_refs}"
  echo "  Unique image IDs:    ${unique_images}"
  echo ""
  echo "Cleanup targets:"
  sudo du -sh /var/lib/containers/storage /var/log/journal /var/cache/dnf 2>/dev/null \
    | sed 's/^/  /' || true
}

read -r before_used before_available before_percent < <(disk_snapshot)
print_report

if [ "$apply" != true ]; then
  echo ""
  echo "Preview only. Run 'aap-demo maintenance --apply' to clean these safe targets."
  exit 0
fi

echo ""
echo "Cleaning safe targets..."

mapfile -t exited_ids < <(sudo crictl ps -a --state Exited -q | sed '/^$/d')
if [ "${#exited_ids[@]}" -gt 0 ]; then
  sudo crictl rm "${exited_ids[@]}"
  echo "  Removed ${#exited_ids[@]} exited container(s)"
else
  echo "  No exited containers to remove"
fi

sudo crictl rmi --prune
echo "  Pruned unused container images"

if command -v dnf >/dev/null 2>&1; then
  sudo dnf clean all
  echo "  Cleared DNF package metadata"
fi

sudo journalctl --vacuum-time=7d
echo "  Vacuumed system journals older than 7 days"

if command -v fstrim >/dev/null 2>&1; then
  sudo fstrim -av
  echo "  Trimmed freed filesystem blocks"
fi

read -r after_used after_available after_percent < <(disk_snapshot)
reclaimed_kib=$((before_used - after_used))
if [ "$reclaimed_kib" -lt 0 ]; then
  reclaimed_kib=0
fi

echo ""
echo "Maintenance complete:"
echo "  Disk usage: ${before_percent} -> ${after_percent}"
echo "  Reclaimed:  $((reclaimed_kib / 1024)) MiB"
EOF
}

_maintenance_uninstall_preview() {
  local reconfigure="${1:-false}"
  local data_dir="${AAP_DEMO_DIR:-$HOME/.aap-demo}"
  local crc_dir="${AAP_DEMO_CRC_DIR:-$HOME/.crc}"

  echo ""
  echo "aap-demo maintenance uninstall - Full environment removal preview"
  echo ""
  echo "The following aap-demo-managed resources will be permanently removed:"
  echo "  • CRC/MicroShift VM, containers, volumes, and libvirt resources"
  echo "  • All Fleet VMs, overlays, SSH keys, and cached Fleet images"
  echo "  • Downloaded CRC bundle and cache: ${crc_dir}"
  echo "  • Generated credentials, kubeconfig, addon state, caches, and virtualenvs"
  if [ "$reconfigure" = true ]; then
    echo "  • The aap_demo entries in the encrypted credential Vault (Vault files are kept)"
  fi
  echo "  • Persistent CRI-O image disk and local OCI image cache"
  echo "  • Temporary swap file created by aap-demo"
  echo "  • Ingress CA entries from system and browser trust stores"
  echo "  • Claude Code aap-demo MCP registration and shell CA export"
  echo "  • Dashboard process and logs"
  echo "  • Linux/macOS recovery services, configuration, and retained backups"
  echo "  • aap-demo CLI symlink and shell completion files"
  echo "  • Generated private system-information document and temporary logs"
  echo ""
  echo "Preserved:"
  echo "  • Source repository: ${SCRIPT_DIR}"
  if [ "$reconfigure" = true ]; then
    echo "  • Vault files env.yml and .vaultpass.txt (shared with other products/projects;"
    echo "    only the aap_demo entries are stripped)"
  else
    echo "  • Encrypted credential Vault env.yml and .vaultpass.txt, including the"
    echo "    aap_demo credentials, so rebuilds do not re-prompt (use --reconfigure to strip them)"
  fi
  echo "  • Unrelated keys in $HOME/.ansible/conf/env.yml"
  echo "  • Shared OS packages, command-line tools, and libvirt group membership"
  echo ""
  du -sh "$data_dir" "$crc_dir" 2>/dev/null | sed 's/^/  /' || true
}

_maintenance_validate_uninstall_path() {
  local path="$1"
  case "$path" in
    "" | "/" | "$HOME" | "$SCRIPT_DIR")
      echo "ERROR: Refusing unsafe uninstall path: ${path:-<empty>}" >&2
      return 1
      ;;
  esac
}

_maintenance_remove_shell_lines() {
  local profile tmp
  for profile in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
    [ -f "$profile" ] || continue
    tmp=$(mktemp)
    awk '
      $0 == "# >>> aap-demo PATH >>>" { skip_aap_demo_path=1; next }
      skip_aap_demo_path == 1 && $0 == "# <<< aap-demo PATH <<<" {
        skip_aap_demo_path=0
        next
      }
      skip_aap_demo_path == 1 { next }
      $0 == "# >>> aap-demo bash completion >>>" { skip_bash_completion=1; next }
      skip_bash_completion == 1 && $0 == "# <<< aap-demo bash completion <<<" {
        skip_bash_completion=0
        next
      }
      skip_bash_completion == 1 { next }
      $0 == "# AAP Demo - Trust self-signed ingress CA for Node.js (Claude Code MCP)" { skip=1; next }
      skip == 1 && /NODE_EXTRA_CA_CERTS.*crc-ingress-ca\.crt/ { skip=0; next }
      $0 == "fpath=(~/.zsh/completions $fpath)" { remove_compinit=1; next }
      remove_compinit == 1 && $0 == "autoload -Uz compinit && compinit" { remove_compinit=0; next }
      { remove_compinit=0; print }
    ' "$profile" >"$tmp"
    cat "$tmp" >"$profile"
    rm -f "$tmp"
  done
}

_maintenance_remove_data_dir() {
  local data_dir="$1"
  _maintenance_validate_uninstall_path "$data_dir" || return 1

  rm -rf -- "$data_dir"
}

_maintenance_stop_dashboard() {
  local port="${AAP_DEMO_DASHBOARD_PORT:-8765}" health pid repo_root
  command -v curl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  health=$(curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 \
    "http://127.0.0.1:${port}/api/health" 2>/dev/null) || return 0
  if [ "$(jq -r '.service // empty' <<<"$health")" != aap-demo-dashboard ]; then
    return 0
  fi
  repo_root=$(jq -r '.repo_root // empty' <<<"$health")
  [ "$repo_root" = "$SCRIPT_DIR" ] || return 0
  pid=$(jq -r '.pid // empty' <<<"$health")
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: Dashboard returned an invalid process ID" >&2
    return 1
  }
  kill "$pid" || {
    echo "ERROR: Failed to stop aap-demo dashboard process $pid" >&2
    return 1
  }
  local attempt
  for attempt in {1..20}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  echo "ERROR: aap-demo dashboard process $pid did not stop" >&2
  return 1
}

_maintenance_remove_state_service() {
  local system_unit="${AAP_DEMO_SYSTEMD_UNIT_FILE:-/etc/systemd/system/aap-demo.service}"
  local system_config="${AAP_DEMO_SYSTEM_CONFIG_DIR:-/etc/aap-demo}"
  local system_libexec="${AAP_DEMO_SYSTEM_LIBEXEC_DIR:-/usr/local/libexec}"
  local system_backups="${AAP_DEMO_STATE_BACKUP_DIR:-/var/lib/aap-demo/$(id -un)}"
  local mac_root="${AAP_DEMO_MAC_STATE_ROOT:-$HOME/Library/Application Support/aap-demo}"
  local mac_plist="${AAP_DEMO_MAC_STATE_PLIST:-$HOME/Library/LaunchAgents/com.aap-demo.recovery.plist}"

  case "$(uname -s)" in
    Darwin)
      [ "$(basename "$mac_root")" = aap-demo ] || {
        echo "ERROR: Refusing unsafe macOS state path: $mac_root" >&2
        return 1
      }
      if command -v launchctl >/dev/null 2>&1 \
        && launchctl print "gui/$(id -u)/com.aap-demo.recovery" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/com.aap-demo.recovery" || return 1
      fi
      rm -f -- "$mac_plist"
      _maintenance_validate_uninstall_path "$mac_root" || return 1
      rm -rf -- "$mac_root"
      ;;
    Linux)
      rm -f -- "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/aap-demo-dashboard.desktop" || return 1
      [ "$(basename "$system_config")" = aap-demo ] \
        && [ "$(basename "$(dirname "$system_backups")")" = aap-demo ] || {
        echo "ERROR: Refusing unsafe Linux state-service paths" >&2
        return 1
      }
      if [ -f "$system_config/owner" ] \
        && [ "$(cat "$system_config/owner")" != "$(id -un)" ]; then
        echo "ERROR: Refusing to remove another user's aap-demo recovery service" >&2
        return 1
      fi
      if [ -e "$system_unit" ] || [ -d "$system_config" ]; then
        sudo systemctl disable --now aap-demo.service >/dev/null 2>&1 || {
          echo "ERROR: Failed to disable the aap-demo recovery service" >&2
          return 1
        }
      fi
      sudo rm -f -- \
        "$system_unit" \
        "$system_libexec/aap-demo-state" \
        "$system_libexec/aap-demo-operation-lock.sh"
      sudo rm -rf -- "$system_config" "$system_backups"
      sudo rmdir "$(dirname "$system_backups")" 2>/dev/null || true
      if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl daemon-reload >/dev/null
      fi
      ;;
  esac
}

_maintenance_remove_managed_credentials() {
  if ! declare -F aap_demo_vault_remove_managed >/dev/null; then
    # shellcheck source=credential-vault.sh
    source "${SCRIPT_DIR}/includes/credential-vault.sh"
  fi
  aap_demo_vault_remove_managed
}

_maintenance_uninstall_apply() {
  local reconfigure="${1:-false}"
  local data_dir="${AAP_DEMO_DIR:-$HOME/.aap-demo}"
  local crc_dir="${AAP_DEMO_CRC_DIR:-$HOME/.crc}"
  local image_disk cli_path

  _maintenance_validate_uninstall_path "$data_dir" || return 1
  _maintenance_validate_uninstall_path "$crc_dir" || return 1

  echo ""
  echo "Removing aap-demo environment..."

  _maintenance_stop_dashboard || return 1

  if command -v claude >/dev/null 2>&1; then
    claude mcp remove aap-demo --scope user >/dev/null 2>&1 || true
  fi
  _maintenance_remove_shell_lines

  if declare -F _purge_ingress_ca_trust >/dev/null; then
    _purge_ingress_ca_trust || {
      echo "ERROR: Failed to remove ingress CA trust entries" >&2
      return 1
    }
  fi

  if declare -F _remove_temp_swap >/dev/null; then
    _remove_temp_swap || {
      echo "ERROR: Failed to remove temporary swap" >&2
      return 1
    }
  fi

  if [ -d "$data_dir/fleet" ] && [ -f "${SCRIPT_DIR}/addons/fleet/fleet.sh" ]; then
    # shellcheck source=../addons/fleet/fleet.sh
    source "${SCRIPT_DIR}/addons/fleet/fleet.sh"
    fleet_destroy_all
  fi

  image_disk="$(_persistent_crio_store_disk)"
  if [ -e "$image_disk" ]; then
    AAP_PERSISTENT_IMAGE_STORE=true persistent_crio_store_detach || {
      echo "ERROR: Failed to detach persistent CRI-O image storage" >&2
      return 1
    }
    rm -f -- "$image_disk"
  fi

  if command -v crc >/dev/null 2>&1; then
    if [ -d "$crc_dir/machines/crc" ] \
      || { command -v virsh >/dev/null 2>&1 && virsh -c qemu:///system dominfo crc >/dev/null 2>&1; }; then
      if ! crc delete -f >/dev/null 2>&1 && ! crc delete >/dev/null 2>&1; then
        echo "ERROR: CRC VM deletion failed; preserving host state for recovery" >&2
        return 1
      fi
    fi
    crc cleanup >/dev/null 2>&1 || {
      echo "ERROR: crc cleanup failed" >&2
      return 1
    }
  fi

  podman system connection remove aap-demo >/dev/null 2>&1 || true

  if [ -f "${SCRIPT_DIR}/scripts/aap-demo-token-keepalive.sh" ]; then
    bash "${SCRIPT_DIR}/scripts/aap-demo-token-keepalive.sh" disable >/dev/null || {
      echo "ERROR: Failed to disable the token keepalive scheduler" >&2
      return 1
    }
  fi

  if [ "$reconfigure" = true ]; then
    _maintenance_remove_managed_credentials || {
      echo "ERROR: Failed to remove aap-demo credentials from the encrypted Vault" >&2
      return 1
    }
  else
    echo "  Preserved the encrypted credential Vault (env.yml and .vaultpass.txt)"
  fi
  _maintenance_remove_data_dir "$data_dir"
  rm -rf -- "$crc_dir"
  cli_path="$HOME/.local/bin/aap-demo"
  if [ -L "$cli_path" ] \
    && [ "$(readlink "$cli_path")" = "${SCRIPT_DIR}/aap-demo.sh" ]; then
    rm -f -- "$cli_path"
  fi
  rm -f -- \
    "$HOME/.zsh/completions/_aap-demo" \
    "$HOME/.local/share/bash-completion/completions/aap-demo" \
    "${SCRIPT_DIR}/docs/aap-demo-system-info.md" \
    "${SCRIPT_DIR}/docs/aap-demo-system-info.json" \
    /tmp/crc-start.log \
    /tmp/crc-recovery.log \
    /tmp/crc-daemon.log \
    /tmp/aap-demo-local-cache.oci

  echo ""
  echo "✓ aap-demo environment uninstalled"
  if [ "$reconfigure" = true ]; then
    echo "  Removed all aap-demo settings and managed credentials"
  else
    echo "  Removed all aap-demo settings; kept the credential Vault for rebuilds"
  fi
  echo "  Preserved source repository: ${SCRIPT_DIR}"
  echo "  Preserved shared tools and unrelated Vault content"
}

_maintenance_uninstall() {
  local apply="${1:-false}" reconfigure="${2:-false}" confirmation=""
  _maintenance_uninstall_preview "$reconfigure"

  if [ "$apply" != true ]; then
    echo ""
    echo "Preview only. Run 'aap-demo maintenance uninstall --apply' to continue."
    return 0
  fi

  if [ "${QUIET:-false}" = "true" ] || [ ! -t 0 ]; then
    if [ "${AAP_DEMO_UNINSTALL_CONFIRM:-}" != "UNINSTALL" ]; then
      echo ""
      echo "ERROR: Noninteractive uninstall requires AAP_DEMO_UNINSTALL_CONFIRM=UNINSTALL" >&2
      return 1
    fi
  else
    echo "Type UNINSTALL to permanently remove the environment:"
    read -r confirmation </dev/tty
    if [ "$confirmation" != "UNINSTALL" ]; then
      echo "Uninstall cancelled."
      return 1
    fi
  fi

  _maintenance_remove_state_service || return 1
  if declare -F aap_demo_acquire_operation_lock >/dev/null; then
    aap_demo_acquire_operation_lock "maintenance-uninstall" || return 1
  fi
  _maintenance_uninstall_apply "$reconfigure"
}
