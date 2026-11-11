#!/usr/bin/env bash
# =============================================================================
# aap-demo-tier-select.sh — Hardware-aware installer tier selection
# =============================================================================
#
# Inspects host vCPU/RAM/disk and deploys either:
#   - SNO (Single Node OpenShift, CRC_PRESET=openshift): full OpenShift web UI
#   - MicroShift (CRC_PRESET=microshift): minimal edge footprint, CLI-only
#
# Usage:
#   scripts/aap-demo-tier-select.sh [--tier sno|microshift] [--yes] [--dry-run]
#
# Environment overrides (mainly for tests):
#   TIER_VCPUS, TIER_RAM_GB, TIER_DISK_GB   — override detected resources
#   AAP_DEMO_TIER_CHOICE                    — preset menu answer (1|2|sno|microshift)
#   AAP_DEMO_TIER_NO_EXEC=1                 — select only, never deploy
#
# Exit codes:
#   0  success (tier selected and deployment started/completed)
#   1  insufficient resources for MicroShift minimums
#   2  invalid arguments or invalid menu input
#   3  deployment command failed
# =============================================================================

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---------------------------------------------------------------------------
# Thresholds
# ---------------------------------------------------------------------------
SNO_MIN_CPUS=8
SNO_MIN_RAM_GB=16
SNO_REC_RAM_GB=32
SNO_MIN_DISK_GB=100

MICRO_MIN_CPUS=2
MICRO_MIN_RAM_GB=2
MICRO_MIN_DISK_GB=10

# ---------------------------------------------------------------------------
# Colors (disabled when not a terminal or NO_COLOR is set)
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED='\033[0;31m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[1;33m'
  C_BLUE='\033[0;34m'
  C_BOLD='\033[1m'
  C_NC='\033[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_NC=''
fi

msg_info() { printf "${C_BLUE}▸${C_NC} %s\n" "$*"; }
msg_ok() { printf "${C_GREEN}✓${C_NC} %s\n" "$*"; }
msg_warn() { printf "${C_YELLOW}WARNING:${C_NC} %s\n" "$*" >&2; }
msg_err() { printf "${C_RED}ERROR:${C_NC} %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# Resource inspection
# ---------------------------------------------------------------------------
detect_vcpus() {
  if [[ "${TIER_VCPUS:-}" =~ ^[0-9]+$ ]]; then
    echo "$TIER_VCPUS"
    return 0
  fi
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v getconf >/dev/null 2>&1; then
    getconf _NPROCESSORS_ONLN
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu
  else
    echo 0
  fi
}

detect_ram_gb() {
  if [[ "${TIER_RAM_GB:-}" =~ ^[0-9]+$ ]]; then
    echo "$TIER_RAM_GB"
    return 0
  fi
  if [ -r /proc/meminfo ]; then
    awk '/^MemTotal:/ {printf "%d", $2/1024/1024}' /proc/meminfo
  elif command -v sysctl >/dev/null 2>&1; then
    # macOS: hw.memsize is bytes
    echo $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
  else
    echo 0
  fi
}

detect_disk_gb() {
  if [[ "${TIER_DISK_GB:-}" =~ ^[0-9]+$ ]]; then
    echo "$TIER_DISK_GB"
    return 0
  fi
  # Available space on the root filesystem, in GiB
  df -k / 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}' || echo 0
}

# ---------------------------------------------------------------------------
# Evaluation logic
# ---------------------------------------------------------------------------
meets_sno() {
  [ "$1" -ge "$SNO_MIN_CPUS" ] \
    && [ "$2" -ge "$SNO_MIN_RAM_GB" ] \
    && [ "$3" -ge "$SNO_MIN_DISK_GB" ]
}

meets_microshift() {
  [ "$1" -ge "$MICRO_MIN_CPUS" ] \
    && [ "$2" -ge "$MICRO_MIN_RAM_GB" ] \
    && [ "$3" -ge "$MICRO_MIN_DISK_GB" ]
}

# Print the missing SNO prerequisites, one per line.
sno_missing() {
  local cpus="$1" ram="$2" disk="$3"
  [ "$cpus" -lt "$SNO_MIN_CPUS" ] \
    && echo "  - vCPUs: ${cpus} detected, ${SNO_MIN_CPUS} required"
  [ "$ram" -lt "$SNO_MIN_RAM_GB" ] \
    && echo "  - RAM: ${ram}GB detected, ${SNO_MIN_RAM_GB}GB required (${SNO_REC_RAM_GB}GB recommended)"
  [ "$disk" -lt "$SNO_MIN_DISK_GB" ] \
    && echo "  - Disk: ${disk}GB available, ${SNO_MIN_DISK_GB}GB required"
}

# Print the missing MicroShift prerequisites, one per line.
microshift_missing() {
  local cpus="$1" ram="$2" disk="$3"
  [ "$cpus" -lt "$MICRO_MIN_CPUS" ] \
    && echo "  - vCPUs: ${cpus} detected, ${MICRO_MIN_CPUS} required"
  [ "$ram" -lt "$MICRO_MIN_RAM_GB" ] \
    && echo "  - RAM: ${ram}GB detected, ${MICRO_MIN_RAM_GB}GB required"
  [ "$disk" -lt "$MICRO_MIN_DISK_GB" ] \
    && echo "  - Disk: ${disk}GB available, ${MICRO_MIN_DISK_GB}GB required"
}

# ---------------------------------------------------------------------------
# Interactive menu (both tiers supported)
# ---------------------------------------------------------------------------
print_menu() {
  local cpus="$1" ram="$2" disk="$3"
  echo ""
  printf "${C_BOLD}Host resources:${C_NC} %s vCPUs, %sGB RAM, %sGB disk available\n" \
    "$cpus" "$ram" "$disk"
  echo ""
  printf "${C_BOLD}This host supports both deployment tiers:${C_NC}\n"
  echo ""
  printf "  ${C_GREEN}1) Single Node OpenShift (SNO)${C_NC}\n"
  echo "     Specs:     full OpenShift control plane + worker on one node"
  echo "     Requires:  >= ${SNO_MIN_CPUS} vCPUs, >= ${SNO_MIN_RAM_GB}GB RAM (${SNO_REC_RAM_GB}GB recommended), >= ${SNO_MIN_DISK_GB}GB disk"
  echo "     Footprint: large (multi-GB bundle, higher steady-state RAM)"
  printf "     UI:        ${C_GREEN}full OpenShift web console${C_NC}\n"
  echo ""
  printf "  ${C_BLUE}2) MicroShift${C_NC}\n"
  echo "     Specs:     minimal OpenShift-compatible edge runtime"
  echo "     Requires:  >= ${MICRO_MIN_CPUS} vCPUs, >= ${MICRO_MIN_RAM_GB}GB RAM, >= ${MICRO_MIN_DISK_GB}GB disk"
  echo "     Footprint: small (edge/IoT oriented)"
  printf "     UI:        ${C_YELLOW}CLI-only (no web console)${C_NC}\n"
  echo ""
}

# Read and validate the user's menu choice. Echoes "sno" or "microshift".
prompt_choice() {
  local answer
  while true; do
    printf "Select deployment tier [1=SNO, 2=MicroShift]: " >&2
    if ! read -r answer; then
      msg_err "No input received (stdin closed)"
      return 2
    fi
    case "${answer,,}" in
      1 | sno | openshift) echo "sno"; return 0 ;;
      2 | microshift | micro) echo "microshift"; return 0 ;;
      *) msg_warn "Invalid choice '${answer}' — enter 1 (SNO) or 2 (MicroShift)" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------
deploy_tier() {
  local tier="$1" preset
  case "$tier" in
    sno) preset="openshift" ;;
    microshift) preset="microshift" ;;
    *) msg_err "Unknown tier '${tier}'"; return 2 ;;
  esac

  msg_info "Deploying ${tier} (CRC_PRESET=${preset})..."
  if [ "${DRY_RUN:-false}" = true ]; then
    echo "DRY-RUN: CRC_PRESET=${preset} ${SCRIPT_DIR}/aap-demo.sh create"
    return 0
  fi
  if [ "${AAP_DEMO_TIER_NO_EXEC:-}" = "1" ]; then
    echo "SELECTED_PRESET=${preset}"
    return 0
  fi

  if [ ! -x "${SCRIPT_DIR}/aap-demo.sh" ]; then
    msg_err "aap-demo.sh not found at ${SCRIPT_DIR}/aap-demo.sh"
    return 3
  fi
  if ! CRC_PRESET="$preset" "${SCRIPT_DIR}/aap-demo.sh" create; then
    msg_err "Deployment failed for tier '${tier}'"
    return 3
  fi
  msg_ok "Deployment started for tier '${tier}'"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $0 [--tier sno|microshift] [--yes] [--dry-run] [--help]

Evaluates host hardware and deploys Single Node OpenShift (SNO) or MicroShift.

Options:
  --tier TIER   Skip the menu and deploy the given tier (sno|microshift)
  --yes         Non-interactive: pick SNO when supported, else MicroShift
  --dry-run     Print what would be deployed without running it
  --help        Show this help
EOF
}

main() {
  local forced_tier="" assume_yes=false
  DRY_RUN=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --tier)
        [ $# -ge 2 ] || { msg_err "--tier requires a value"; usage; return 2; }
        forced_tier="$2"
        shift 2
        ;;
      --tier=*) forced_tier="${1#*=}"; shift ;;
      --yes | -y) assume_yes=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --help | -h) usage; return 0 ;;
      *) msg_err "Unknown argument: $1"; usage; return 2 ;;
    esac
  done

  if [ -n "$forced_tier" ]; then
    case "${forced_tier,,}" in
      sno | openshift) forced_tier="sno" ;;
      microshift | micro) forced_tier="microshift" ;;
      *) msg_err "Invalid tier '${forced_tier}' (use sno or microshift)"; return 2 ;;
    esac
  fi

  msg_info "Inspecting host resources..."
  local cpus ram disk
  cpus="$(detect_vcpus)"
  ram="$(detect_ram_gb)"
  disk="$(detect_disk_gb)"

  if ! [[ "$cpus" =~ ^[0-9]+$ && "$ram" =~ ^[0-9]+$ && "$disk" =~ ^[0-9]+$ ]]; then
    msg_err "Resource detection failed (cpus='${cpus}' ram='${ram}' disk='${disk}')"
    return 1
  fi

  msg_ok "Detected: ${cpus} vCPUs, ${ram}GB RAM, ${disk}GB disk available"

  # Forced tier still validates against minimums.
  if [ -n "$forced_tier" ]; then
    if [ "$forced_tier" = "sno" ] && ! meets_sno "$cpus" "$ram" "$disk"; then
      msg_err "Host does not meet SNO requirements:"
      sno_missing "$cpus" "$ram" "$disk" >&2
      return 1
    fi
    if [ "$forced_tier" = "microshift" ] && ! meets_microshift "$cpus" "$ram" "$disk"; then
      msg_err "Host does not meet MicroShift minimum requirements:"
      microshift_missing "$cpus" "$ram" "$disk" >&2
      return 1
    fi
    deploy_tier "$forced_tier"
    return $?
  fi

  if meets_sno "$cpus" "$ram" "$disk"; then
    local choice=""
    if [ -n "${AAP_DEMO_TIER_CHOICE:-}" ]; then
      case "${AAP_DEMO_TIER_CHOICE,,}" in
        1 | sno | openshift) choice="sno" ;;
        2 | microshift | micro) choice="microshift" ;;
        *) msg_err "Invalid AAP_DEMO_TIER_CHOICE '${AAP_DEMO_TIER_CHOICE}'"; return 2 ;;
      esac
      print_menu "$cpus" "$ram" "$disk"
      msg_info "Tier selected via AAP_DEMO_TIER_CHOICE: ${choice}"
    elif [ "$assume_yes" = true ]; then
      print_menu "$cpus" "$ram" "$disk"
      choice="sno"
      msg_info "Non-interactive mode: defaulting to SNO (use --tier microshift to override)"
    else
      print_menu "$cpus" "$ram" "$disk"
      if ! choice="$(prompt_choice)"; then
        msg_err "Re-run with --yes or --tier to select non-interactively"
        return 2
      fi
    fi
    deploy_tier "$choice"
    return $?
  fi

  if meets_microshift "$cpus" "$ram" "$disk"; then
    msg_warn "Insufficient resources for Single Node OpenShift:"
    sno_missing "$cpus" "$ram" "$disk" >&2
    msg_info "Falling back to MicroShift (minimal edge footprint, CLI-only)"
    deploy_tier "microshift"
    return $?
  fi

  msg_err "Host does not meet the minimum requirements for MicroShift:"
  microshift_missing "$cpus" "$ram" "$disk" >&2
  msg_err "Cannot deploy either tier on this host"
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
