#!/usr/bin/env bash
# One-time host prep for local aap-demo deploy (Fedora/Linux + CRC).
#
# Prepares a memory-constrained Linux workstation before the first deploy:
#   1. Optional temp swap (see scripts/enable-temp-swap.sh)
#   2. Red Hat pull secret in ~/.aap-demo/
#   3. libvirt group membership for CRC
#   4. crc setup (admin helper + bundle download)
#
# Usage:
#   ./scripts/local-prereq.sh
#   SKIP_TEMP_SWAP=true ./scripts/local-prereq.sh   # skip swap step
#   AAP_SWAP_SIZE_GB=24 ./scripts/local-prereq.sh  # larger temp swap
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"

echo "=== aap-demo local prerequisites ==="
echo ""

# 1. Temporary swap for deploy bursts (optional; skip with SKIP_TEMP_SWAP=true)
"${SCRIPT_DIR}/enable-temp-swap.sh" enable
echo ""

# 2. Pull secret
if [[ ! -f "${HOME}/.aap-demo/pull-secret.txt" ]]; then
  echo "ERROR: Missing Red Hat pull secret at ~/.aap-demo/pull-secret.txt"
  echo "  Download: https://console.redhat.com/openshift/install/pull-secret"
  echo "  Then run:  cp ~/Downloads/pull-secret.txt ~/.aap-demo/pull-secret.txt"
  exit 1
fi
echo "✓ Pull secret found"

# 3. libvirt group (needed for CRC VM)
if ! groups | grep -q libvirt; then
  echo "Adding ${USER} to libvirt group (requires sudo)..."
  sudo usermod -aG libvirt "${USER}"
  echo "  ✓ Added to libvirt — log out/in or run: newgrp libvirt"
  NEED_RELOGIN=1
else
  echo "✓ User is in libvirt group"
fi

# 4. CRC setup (installs crc-admin-helper, downloads bundle)
if ! command -v crc &>/dev/null; then
  echo "ERROR: crc not in PATH. Install to ~/.local/bin first."
  exit 1
fi

echo "Running crc setup (requires sudo once)..."
crc config set preset microshift
crc setup

echo ""
if [[ -n "${NEED_RELOGIN:-}" ]]; then
  echo "Next: open a new shell (or: newgrp libvirt), then:"
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo "  aap-demo deploy"
else
  echo "Ready. Deploy with:"
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo "  aap-demo deploy"
fi
echo ""
echo "After deploy, remove temp swap with:"
echo "  ${SCRIPT_DIR}/enable-temp-swap.sh disable"
