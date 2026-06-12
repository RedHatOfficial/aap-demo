#!/usr/bin/env bash
set -euo pipefail

# Preflight dependency checks for AAP operator deployment
# Can be used for any deployment method (MINC, CRC, OpenShift, etc.)
#
# Usage:
#   ./preflight-checks.sh
#   SKIP_PREFLIGHT=true ./preflight-checks.sh  # Skip checks
#
# Exit codes:
#   0 - All dependencies satisfied
#   1 - Missing required dependencies

if [ "${SKIP_PREFLIGHT:-false}" = "true" ]; then
  echo "Skipping preflight checks (SKIP_PREFLIGHT=true)"
  exit 0
fi

echo "Running preflight checks..."

# Check for required command-line tools
MISSING_DEPS=""

if ! command -v kubectl &>/dev/null; then
  MISSING_DEPS="$MISSING_DEPS kubectl"
fi

if ! command -v ansible-playbook &>/dev/null; then
  MISSING_DEPS="$MISSING_DEPS ansible-playbook"
fi

if ! command -v jq &>/dev/null; then
  MISSING_DEPS="$MISSING_DEPS jq"
fi

if ! command -v pip3 &>/dev/null; then
  MISSING_DEPS="$MISSING_DEPS pip3(python3-pip)"
fi

# Check for operator-sdk (macOS only requirement for OLM)
if [[ "$(uname)" == "Darwin" ]] && ! command -v operator-sdk &>/dev/null; then
  MISSING_DEPS="$MISSING_DEPS operator-sdk"
fi

# Exit if any required tools are missing
if [ -n "$MISSING_DEPS" ]; then
  echo "ERROR: Missing required dependencies:$MISSING_DEPS"
  echo ""
  echo "Please install missing dependencies:"
  echo ""
  echo "  Fedora/RHEL:"
  echo "    sudo dnf install ansible-core jq python3-pip"
  echo "    # kubectl must be installed from kubernetes repo or directly:"
  echo "    curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
  echo "    chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
  echo ""
  echo "  Ubuntu/Debian:"
  echo "    sudo apt install ansible jq python3-pip"
  echo "    # kubectl:"
  echo "    curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
  echo "    chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
  echo ""
  echo "  macOS:"
  echo "    # Install Homebrew if not present:"
  echo "    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  echo ""
  echo "    # Install dependencies:"
  echo "    brew install kubectl ansible jq python3 operator-sdk"
  exit 1
fi

# Install Python kubernetes library if missing
if ! python3 -c "import kubernetes" &>/dev/null; then
  echo "Installing Python kubernetes library..."
  pip3 install --user kubernetes
else
  echo "  ✓ Python kubernetes library already installed"
fi

# Install ansible kubernetes.core collection if missing
if ! ansible-galaxy collection verify kubernetes.core &>/dev/null; then
  echo "Installing kubernetes.core collection..."
  ansible-galaxy collection install kubernetes.core
else
  echo "  ✓ kubernetes.core already installed"
fi

# Check for mkcert if MINC_MKCERT is enabled (default: true)
# Note: mkcert is auto-installed during setup if not present
if [ "${MINC_MKCERT:-true}" = "true" ]; then
  if ! command -v mkcert &>/dev/null; then
    echo ""
    echo "ℹ  mkcert not found - will be auto-installed during setup"
    echo "   (installs to ~/.local/bin/mkcert from GitHub releases)"
    echo ""
    echo "   Or disable with: MINC_MKCERT=false"
    echo ""
  else
    # Check if mkcert CA is installed (mkcert -install was run)
    MKCERT_CA="$(mkcert -CAROOT 2>/dev/null)/rootCA.pem"
    if [ ! -f "$MKCERT_CA" ]; then
      echo ""
      echo "✗  mkcert CA not initialized - run 'mkcert -install' first"
      echo ""
      echo "   mkcert is installed but the CA is not set up."
      echo "   This is required for browsers and podman to trust certificates."
      echo ""
      echo "   Run:  mkcert -install"
      echo ""
      echo "   Or disable: MINC_MKCERT=false aap-demo"
      echo ""
    else
      echo "  ✓ mkcert installed and CA initialized (trusted SSL certs enabled)"
    fi
  fi
fi

echo "  ✓ All required dependencies found"
echo ""
