#!/usr/bin/env bash
set -euo pipefail

# Install OLM (Operator Lifecycle Manager) on MicroShift
#
# MicroShift doesn't include OLM by default. This addon installs it
# via operator-sdk, enabling CatalogSources, Subscriptions, and CSV-based
# operator installs.
#
# Works on both CRC and MINC backends.
#
# Usage:
#   ./deploy.sh          # Install OLM
#   ./deploy.sh --delete # Remove OLM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACTION="${1:-deploy}"

# Auto-install operator-sdk if not present
ensure_operator_sdk() {
  if command -v operator-sdk >/dev/null 2>&1; then
    return 0
  fi

  echo "operator-sdk not found. Installing..."
  echo ""

  # Detect platform and architecture
  case "$(uname -s)" in
    Darwin) SDK_OS="darwin" ;;
    Linux) SDK_OS="linux" ;;
    *)
      echo "ERROR: Unsupported OS: $(uname -s)"
      exit 1
      ;;
  esac
  case "$(uname -m)" in
    x86_64) SDK_ARCH="amd64" ;;
    aarch64 | arm64) SDK_ARCH="arm64" ;;
    *)
      echo "ERROR: Unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac

  # Download from GitHub releases
  SDK_VERSION="v1.38.0"
  SDK_URL="https://github.com/operator-framework/operator-sdk/releases/download/${SDK_VERSION}/operator-sdk_${SDK_OS}_${SDK_ARCH}"
  echo "Downloading operator-sdk ${SDK_VERSION} for ${SDK_OS}/${SDK_ARCH}..."

  SDK_BIN_DIR="${HOME}/.local/bin"
  mkdir -p "$SDK_BIN_DIR"
  SDK_DEST="${SDK_BIN_DIR}/operator-sdk"

  if ! curl -fsSL -o "$SDK_DEST" "$SDK_URL"; then
    echo "ERROR: Failed to download operator-sdk"
    exit 1
  fi

  chmod +x "$SDK_DEST"

  # Try system install if user has sudo, otherwise use ~/.local/bin
  if sudo -n true 2>/dev/null && [ -w /usr/local/bin ]; then
    mv "$SDK_DEST" /usr/local/bin/operator-sdk
    echo "✓ operator-sdk installed to /usr/local/bin/"
  else
    echo "✓ operator-sdk installed to ${SDK_DEST}"
    if [[ ":$PATH:" != *":$SDK_BIN_DIR:"* ]]; then
      echo "NOTE: Add to PATH: export PATH=\$HOME/.local/bin:\$PATH"
    fi
  fi
  echo ""
}

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing OLM..."
  operator-sdk olm uninstall 2>/dev/null || {
    # Manual cleanup if operator-sdk uninstall fails
    kubectl delete namespace olm 2>/dev/null || true
    kubectl delete namespace operators 2>/dev/null || true
    kubectl delete crd catalogsources.operators.coreos.com 2>/dev/null || true
    kubectl delete crd clusterserviceversions.operators.coreos.com 2>/dev/null || true
    kubectl delete crd installplans.operators.coreos.com 2>/dev/null || true
    kubectl delete crd operatorgroups.operators.coreos.com 2>/dev/null || true
    kubectl delete crd subscriptions.operators.coreos.com 2>/dev/null || true
    kubectl delete crd operators.operators.coreos.com 2>/dev/null || true
    kubectl delete crd operatorconditions.operators.coreos.com 2>/dev/null || true
  }
  echo "✓ OLM removed"
  exit 0
fi

# Check cluster connectivity
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl not connected to cluster"
  echo "Make sure your cluster is running: aap-demo start"
  exit 1
fi

# Ensure operator-sdk is available (auto-install if missing)
ensure_operator_sdk

# Check if OLM is already installed
if kubectl get crd subscriptions.operators.coreos.com &>/dev/null; then
  echo "✓ OLM is already installed"
  operator-sdk olm status 2>/dev/null | grep -E "^  " | head -5 || true
  exit 0
fi

echo "Installing OLM..."
if operator-sdk olm install 2>&1 | tail -10; then
  # Remove operatorhubio catalog (causes pod creation issues on MicroShift)
  kubectl delete catsrc operatorhubio-catalog -n olm 2>/dev/null || true
  echo ""
  echo "✓ OLM installed"
  echo ""
  echo "You can now create CatalogSources and Subscriptions."
  echo "Example: aap-demo deploy 2.6-ga"
else
  echo ""
  echo "⚠ OLM install may have issues"
  echo "Check: operator-sdk olm status"
  # Even if operator-sdk reports failure, OLM often installs successfully
  # (the timeout is aggressive). Check if CRDs exist.
  if kubectl get crd subscriptions.operators.coreos.com &>/dev/null; then
    kubectl delete catsrc operatorhubio-catalog -n olm 2>/dev/null || true
    echo "OLM CRDs are present — installation likely succeeded despite timeout."
  fi
fi
