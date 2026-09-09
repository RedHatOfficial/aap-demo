#!/usr/bin/env bash
# One-time host prep for local aap-demo deploy (Fedora/Linux + CRC).
#
# Prepares a Linux workstation before the first deploy:
#   1. Red Hat pull secret in ~/.aap-demo/
#   2. libvirt group membership for CRC
#   3. crc setup (admin helper + bundle download)
#
# Temp swap is offered interactively during `aap-demo create` (alongside CPU/RAM).
# To enable swap manually: ./scripts/enable-temp-swap.sh
#
# Usage:
#   ./scripts/local-prereq.sh
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

echo "=== aap-demo local prerequisites ==="
echo ""

# 1. Pull secret
if [[ ! -f "${HOME}/.aap-demo/pull-secret.txt" ]]; then
  echo "ERROR: Missing Red Hat pull secret at ~/.aap-demo/pull-secret.txt"
  echo "  Download: https://console.redhat.com/openshift/install/pull-secret"
  echo "  Then run:  cp ~/Downloads/pull-secret.txt ~/.aap-demo/pull-secret.txt"
  exit 1
fi
echo "✓ Pull secret found"

# 2. libvirt group (needed for CRC VM)
if ! groups | grep -q libvirt; then
  echo "Adding ${USER} to libvirt group (requires sudo)..."
  sudo usermod -aG libvirt "${USER}"
  echo "  ✓ Added to libvirt — log out/in or run: newgrp libvirt"
  NEED_RELOGIN=1
else
  echo "✓ User is in libvirt group"
fi

# 3. CRC setup (installs crc-admin-helper, downloads bundle)
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
echo "Temp swap is offered during aap-demo create. Manage manually with:"
echo "  ./scripts/enable-temp-swap.sh"
