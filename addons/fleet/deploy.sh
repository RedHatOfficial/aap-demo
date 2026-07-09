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
#   - A RHEL/CentOS QCOW2 cloud image
#
# Usage:
#   ./deploy.sh          # Validate prerequisites
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
  echo "✓ Fleet addon enabled — prerequisites verified"
else
  echo ""
  echo "⚠ Fleet addon enabled — some prerequisites missing (see above)"
  echo "  Install missing tools before creating VMs"
fi

echo ""
echo "  Next steps:"
echo "    aap-demo fleet add <count> --image <path-to-qcow2>"
echo ""
echo "  Examples:"
echo "    aap-demo fleet add 3 --image ~/rhel9.qcow2"
echo "    aap-demo fleet list"
echo "    aap-demo fleet remove 1"
echo "    aap-demo fleet destroy"
echo ""
echo "  Options:"
echo "    FLEET_NODE_MEM=N   VM memory in MB (default: 1024)"
echo "    FLEET_NODE_CPUS=N  VM CPU count (default: 2)"
