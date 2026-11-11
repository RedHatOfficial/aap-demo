#!/usr/bin/env bash
# One-time host prep for local aap-demo deploy (Fedora/Linux + CRC).
#
# Prepares a Linux workstation before the first deploy:
#   1. Red Hat pull secret in ~/.aap-demo/
#   2. libvirt group membership for CRC
#   3. crc setup (admin helper + bundle download)
#
# Temp swap is offered on Linux during interactive `aap-demo create` (alongside CPU/RAM).
# To enable swap manually on Linux: ./scripts/enable-temp-swap.sh
#
# Usage:
#   ./scripts/local-prereq.sh [--deploy | --full] [--pull-secret PATH]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ORIGINAL_ARGS=("$@")
AAP_DEMO_CLI="${AAP_DEMO_CLI:-${REPO_ROOT}/aap-demo.sh}"
AAP_DEMO_INSTALLER="${AAP_DEMO_INSTALLER:-${REPO_ROOT}/install.sh}"
CRC_DOWNLOAD_URL="${CRC_DOWNLOAD_URL:-https://developers.redhat.com/content-gateway/rest/mirror/pub/cgw/crc/latest/crc-linux-amd64.tar.xz}"
DEPLOY_AFTER_SETUP=false
FULL_SETUP=false
PULL_SECRET_SOURCE=""

usage() {
  echo "Usage: ${BASH_SOURCE[0]} [--deploy | --full] [--pull-secret PATH]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy) DEPLOY_AFTER_SETUP=true ;;
    --full)
      DEPLOY_AFTER_SETUP=true
      FULL_SETUP=true
      ;;
    --pull-secret)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi
      PULL_SECRET_SOURCE="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

if [[ "$(uname -s)" != Linux ]] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
  echo "ERROR: This host bootstrap requires native Linux with libvirt." >&2
  echo "Use MAC_Quickstart.md or Windows_Quickstart.md; WSL users should follow WSL_Quickstart.md." >&2
  exit 1
fi

export PATH="${HOME}/.local/bin:${PATH}"
cd "$REPO_ROOT"

echo "=== aap-demo local prerequisites ==="
echo ""

# 1. Pull secret
if [[ -z "$PULL_SECRET_SOURCE" && -f "${HOME}/Downloads/pull-secret.txt" ]]; then
  PULL_SECRET_SOURCE="${HOME}/Downloads/pull-secret.txt"
fi

if [[ ! -f "${HOME}/.aap-demo/pull-secret.txt" ]]; then
  if [[ -n "$PULL_SECRET_SOURCE" && -f "$PULL_SECRET_SOURCE" ]]; then
    mkdir -p "${HOME}/.aap-demo"
    install -m 600 "$PULL_SECRET_SOURCE" "${HOME}/.aap-demo/pull-secret.txt"
    echo "✓ Pull secret installed from ${PULL_SECRET_SOURCE}"
  else
    echo "ERROR: Missing Red Hat pull secret at ~/.aap-demo/pull-secret.txt"
    echo "  Download: https://console.redhat.com/openshift/install/pull-secret"
    echo "  Then rerun with: ${BASH_SOURCE[0]} --full --pull-secret /path/to/pull-secret.txt"
    exit 1
  fi
else
  echo "✓ Pull secret found"
fi

if [[ "$FULL_SETUP" == "true" && "${AAP_DEMO_INSTALL_DONE:-false}" != "true" ]]; then
  "$AAP_DEMO_INSTALLER"
fi

# 2. libvirt group (needed for CRC VM)
if ! groups | grep -qw libvirt; then
  echo "Adding ${USER} to libvirt group (requires sudo)..."
  sudo usermod -aG libvirt "${USER}"
  echo "  ✓ Added to libvirt"
  NEED_RELOGIN=1
  if [[ "$FULL_SETUP" == "true" ]] && command -v sg &>/dev/null; then
    printf -v RESTART_COMMAND '%q ' env AAP_DEMO_INSTALL_DONE=true \
      "${SCRIPT_DIR}/local-prereq.sh" "${ORIGINAL_ARGS[@]}"
    echo "Continuing setup with the new libvirt group..."
    exec sg libvirt -c "$RESTART_COMMAND"
  fi
else
  echo "✓ User is in libvirt group"
fi

# 3. CRC setup (installs crc-admin-helper, downloads bundle)
if ! command -v crc &>/dev/null; then
  if [[ "$FULL_SETUP" != "true" ]]; then
    echo "ERROR: crc not in PATH. Install to ~/.local/bin first, or rerun with --full."
    exit 1
  fi
  if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
    echo "ERROR: Automatic CRC installation currently supports Linux x86_64 only." >&2
    echo "  Install OpenShift Local, then rerun this command." >&2
    exit 1
  fi
  if ! command -v curl &>/dev/null || ! command -v tar &>/dev/null; then
    echo "ERROR: curl and tar are required to install CRC." >&2
    exit 1
  fi

  echo "Downloading OpenShift Local (CRC)..."
  CRC_TMP_DIR="$(mktemp -d)"
  curl -fL "$CRC_DOWNLOAD_URL" -o "${CRC_TMP_DIR}/crc.tar.xz"
  tar -xJf "${CRC_TMP_DIR}/crc.tar.xz" -C "$CRC_TMP_DIR"
  CRC_BINARY="$(find "$CRC_TMP_DIR" -type f -name crc -print -quit)"
  if [[ -z "$CRC_BINARY" ]]; then
    rm -rf "$CRC_TMP_DIR"
    echo "ERROR: CRC binary not found in downloaded archive." >&2
    exit 1
  fi
  mkdir -p "${HOME}/.local/bin"
  install -m 755 "$CRC_BINARY" "${HOME}/.local/bin/crc"
  rm -rf "$CRC_TMP_DIR"
  echo "✓ CRC installed to ~/.local/bin/crc"
fi

echo "Running crc setup (requires sudo once)..."
crc config set preset microshift
crc setup

echo ""
if [[ -n "${NEED_RELOGIN:-}" ]]; then
  echo "Next: open a new shell (or: newgrp libvirt), then:"
  printf "  cd %q && ./aap-demo.sh deploy\n" "$REPO_ROOT"
elif [[ "$DEPLOY_AFTER_SETUP" == "true" ]]; then
  echo "Starting deployment from ${REPO_ROOT}..."
  cd "$REPO_ROOT"
  if [[ "$FULL_SETUP" == "true" ]]; then
    AAP_DEMO_SKIP_STANDARD_AO=true "$AAP_DEMO_CLI" deploy
    for addon in mcp-server apme-eap product-demos ao; do
      echo "Enabling addon: ${addon}"
      QUIET=true "$AAP_DEMO_CLI" enable "$addon"
    done
    "$AAP_DEMO_CLI" status
  else
    "$AAP_DEMO_CLI" deploy
  fi
else
  echo "Ready. Deploy with:"
  printf "  cd %q && ./aap-demo.sh deploy\n" "$REPO_ROOT"
  echo "Or prepare and deploy in one command:"
  printf "  %q --deploy\n" "${SCRIPT_DIR}/local-prereq.sh"
  echo "Or install CRC, deploy AAP, and enable the demo addons:"
  printf "  %q --full --pull-secret ~/Downloads/pull-secret.txt\n" "${SCRIPT_DIR}/local-prereq.sh"
fi
echo ""
echo "On Linux, temp swap is offered during aap-demo create. Manage manually with:"
echo "  ./scripts/enable-temp-swap.sh"
