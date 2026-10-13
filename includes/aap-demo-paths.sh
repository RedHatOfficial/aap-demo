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

aap_demo_offer_kubeconfig_shell_setup() {
  local quiet="${1:-false}"
  local inherited_kubeconfig="${2:-}"
  local marker="${AAP_DEMO_DIR}/.kubeconfig-shell-setup"
  local shell_path shell_name profile escaped_path export_line

  # Return early if any skip condition is met
  [ "$quiet" = true ] && return 0
  [ -n "$inherited_kubeconfig" ] && return 0
  [ ! -t 0 ] && return 0
  [ ! -s "$AAP_DEMO_KUBECONFIG" ] && return 0
  [ -e "$marker" ] && return 0

  shell_path="${SHELL:-$(ps -p $$ -o command= 2>/dev/null | awk '{print $1}')}"
  shell_name="${shell_path##*/}"
  case "$shell_name" in
    bash)
      if [ "$(uname -s)" = Darwin ] && [ -f "$HOME/.bash_profile" ]; then
        profile="$HOME/.bash_profile"
      else
        profile="$HOME/.bashrc"
      fi
      ;;
    zsh) profile="${ZDOTDIR:-$HOME}/.zshrc" ;;
    fish) profile="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" ;;
    pwsh | powershell)
      if [ "$(uname -s)" = Darwin ] || [ "$(uname -s)" = Linux ]; then
        profile="${PROFILE:-${XDG_CONFIG_HOME:-$HOME/.config}/powershell/Microsoft.PowerShell_profile.ps1}"
      else
        profile="${PROFILE:-$HOME/Documents/PowerShell/Microsoft.PowerShell_profile.ps1}"
      fi
      ;;
    *)
      return 0
      ;;
  esac

  echo ""
  echo "Kubeconfig saved to: $AAP_DEMO_KUBECONFIG"
  read -r -p "Add KUBECONFIG to ${profile}? [y/N] " _answer
  case "$_answer" in
    y | Y | yes | YES) ;;
    *)
      touch "$marker"
      echo "  Run this in the current shell when needed:"
      echo "    export KUBECONFIG=\"$AAP_DEMO_KUBECONFIG\""
      return 0
      ;;
  esac

  mkdir -p "$(dirname "$profile")" 2>/dev/null || true
  if [ ! -f "$profile" ]; then
    touch "$profile" 2>/dev/null || true
  fi
  if [ ! -w "$profile" ]; then
    echo "  WARNING: Cannot write $profile"
    echo "  Run this in the current shell instead:"
    echo "    export KUBECONFIG=\"$AAP_DEMO_KUBECONFIG\""
    return 0
  fi

  escaped_path="${AAP_DEMO_KUBECONFIG//\\/\\\\}"
  escaped_path="${escaped_path//\"/\\\"}"
  escaped_path="${escaped_path//\'/\\\'}"
  case "$shell_name" in
    fish) export_line="set -gx KUBECONFIG \"$escaped_path\"" ;;
    pwsh | powershell) export_line="\$env:KUBECONFIG = \"$escaped_path\"" ;;
    *) export_line="export KUBECONFIG=\"$escaped_path\"" ;;
  esac

  if ! grep -Fq "$AAP_DEMO_KUBECONFIG" "$profile" 2>/dev/null; then
    {
      echo ""
      echo "# aap-demo kubeconfig"
      echo "$export_line"
    } >>"$profile"
    echo "  ✓ Added KUBECONFIG to $profile"
  else
    echo "  ✓ KUBECONFIG is already configured in $profile"
  fi
  echo "  Restart your shell or source $profile to apply it."
  touch "$marker"
}
