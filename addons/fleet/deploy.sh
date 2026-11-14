#!/usr/bin/env bash
# Deploy Fleet — local QEMU VMs as AAP managed nodes
# ADDON_REQUIRES_AAP=true
#
# Creates lightweight QEMU VMs and registers them as managed nodes in AAP.
# VMs use cloud-init for provisioning and connect via SSH port forwarding.
#
# Prerequisites:
#   - qemu (qemu-system-aarch64 or qemu-system-x86_64)
#   - qemu-img
#   - mkisofs or genisoimage
#   - A RHEL/CentOS QCOW2 cloud image, or a download of CentOS Stream 9 GenericCloud
#
# Usage:
#   ./deploy.sh          # Install tools, bring in a QCOW2, and create VMs
#   ./deploy.sh --delete # Destroy all VMs and remove AAP resources

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing Fleet addon..."

  source "${SCRIPT_DIR}/fleet.sh"
  source "${SCRIPT_DIR}/fleet-aap.sh"

  if kubectl cluster-info >/dev/null 2>&1; then
    fleet_deregister_aap 2>/dev/null || true
  fi

  fleet_destroy_all 2>/dev/null || true

  echo "✓ Fleet addon removed"
  exit 0
fi

# --- Deploy mode: validate prerequisites ---

echo "Enabling Fleet addon..."

source "${SCRIPT_DIR}/fleet.sh"

if fleet_check_prereqs; then
  echo ""
  echo "✓ Fleet prerequisites verified"
else
  echo ""
  echo "⚠ Fleet prerequisites are missing."
  if [ "${QUIET:-false}" = true ] || [ ! -t 0 ]; then
    echo "  Automatic installation is disabled in quiet or non-interactive mode."
    echo "  Re-run interactively to be offered automatic installation."
    exit 1
  else
    read -r -p "  Install the missing Fleet prerequisites now? [y/N] " _install_prereqs
    case "$_install_prereqs" in
      y | Y | yes | YES)
        if fleet_install_prereqs && fleet_check_prereqs; then
          echo "  ✓ Fleet prerequisites installed and verified"
        else
          echo "  ERROR: Fleet prerequisites are still incomplete" >&2
          exit 1
        fi
        ;;
      *)
        echo "  Install missing tools before creating VMs" >&2
        exit 1
        ;;
    esac
  fi
fi

_fleet_image="${FLEET_IMAGE:-}"
if [ -z "$_fleet_image" ] && [ -f "${AAP_DEMO_CONFIG_FILE:-$HOME/.aap-demo/config}" ]; then
  _fleet_image=$(sed -n 's/^FLEET_IMAGE=//p' "${AAP_DEMO_CONFIG_FILE:-$HOME/.aap-demo/config}" | tail -n 1)
fi

if ! fleet_acquire_image "$_fleet_image"; then
  exit 1
fi
_fleet_image="${FLEET_ACQUIRED_IMAGE:-}"
if [ -z "$_fleet_image" ]; then
  echo "ERROR: Fleet did not resolve a QCOW2 image" >&2
  exit 1
fi

_fleet_count="${FLEET_NODE_COUNT:-}"
if [ -z "$_fleet_count" ]; then
  if [ "${QUIET:-false}" = true ] || [ ! -t 0 ]; then
    _fleet_count=2
  else
    read -r -p "  Number of fleet VMs to create [2]: " _fleet_count
    _fleet_count="${_fleet_count:-2}"
  fi
fi

if ! [[ "$_fleet_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: FLEET_NODE_COUNT must be a positive integer" >&2
  exit 1
fi

if ! fleet_check_prereqs "$_fleet_image"; then
  echo "ERROR: Fleet cannot start until its prerequisites and QCOW2 image are valid" >&2
  exit 1
fi

source "${SCRIPT_DIR}/fleet-aap.sh"
if ! fleet_create_all "$_fleet_count" "$_fleet_image"; then
  echo "ERROR: Fleet VM creation failed" >&2
  exit 1
fi
_fleet_save_image_config "$_fleet_image"

if ! fleet_register_aap; then
  echo "ERROR: AAP registration failed; removing the VMs created by this enable operation" >&2
  for _fleet_index in "${FLEET_CREATED_INDICES[@]}"; do
    fleet_node_delete "$_fleet_index" 2>/dev/null || true
  done
  exit 1
fi

echo ""
echo "✓ Fleet enabled with ${_fleet_count} managed VM(s)"
fleet_list

echo ""
echo "  Image: ${_fleet_image}"
echo ""
echo "  Next steps:"
echo "    aap-demo fleet add <count>"
echo "    aap-demo fleet add <count> --image <path-or-url>"
echo ""
echo "  Examples:"
echo "    aap-demo fleet add 3 --image ~/rhel9.qcow2"
echo "    aap-demo fleet list"
echo "    aap-demo fleet remove 1"
echo "    aap-demo fleet destroy"
echo ""
echo "  Options:"
echo "    FLEET_NODE_MEM=N          VM memory in MB (default: 1024)"
echo "    FLEET_NODE_CPUS=N         VM CPU count (default: 2)"
echo "    FLEET_DOWNLOAD_IMAGE=true Download CentOS Stream 9 when no image is set"
