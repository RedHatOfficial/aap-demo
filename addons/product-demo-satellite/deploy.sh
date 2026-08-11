#!/usr/bin/env bash
# Product Demo - Satellite
#
# Installs Red Hat Satellite integration demos from the Ansible Product Demos collection.
# Requires product-demos-base addon (automatically installed if needed).
#
# Environment variables:
#   PRODUCT_DEMOS_REPO   - Git repository URL (default: https://github.com/ansible/product-demos)
#   PRODUCT_DEMOS_BRANCH - Git branch to use (default: main)
#
# Usage:
#   ./deploy.sh          # Deploy satellite demos
#   ./deploy.sh --delete # Remove satellite demos

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../product-demos-base/lib.sh
source "${SCRIPT_DIR}/../product-demos-base/lib.sh"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"
DEMO_CATEGORY="satellite"

# Product demos configuration
PRODUCT_DEMOS_REPO="${PRODUCT_DEMOS_REPO:-https://github.com/ansible/product-demos}"
PRODUCT_DEMOS_BRANCH="${PRODUCT_DEMOS_BRANCH:-main}"

# ==============================================================================
# DELETE HANDLER
# ==============================================================================

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing Red Hat Satellite integration demo resources from AAP..."
  echo ""
  echo "To remove satellite demo job templates, log into AAP UI and:"
  echo "  1. Navigate to the 'Ansible Product Demos (APD)' organization"
  echo "  2. Go to Templates"
  echo "  3. Delete templates starting with 'SATELLITE |'"
  echo ""
  echo "✓ product-demo-satellite addon disabled"
  exit 0
fi

# ==============================================================================
# DEPLOYMENT
# ==============================================================================

echo "Deploying Ansible Product Demos - Satellite..."
echo ""

# Check cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
  echo "❌ ERROR: Cannot connect to cluster"
  echo "Please ensure your cluster is running: aap-demo status"
  exit 1
fi

# Check if AAP is deployed
if ! kubectl get aap -n "$NAMESPACE" &>/dev/null; then
  echo "❌ ERROR: AAP not found in namespace $NAMESPACE"
  echo "Please deploy AAP first: aap-demo deploy"
  exit 1
fi

# ==============================================================================
# ENSURE BASE ADDON IS INSTALLED
# ==============================================================================

echo "Checking for product-demos-base..."

if ! grep -q "product-demos-base" ~/.aap-demo/config 2>/dev/null; then
  echo "product-demos-base not found. Installing dependency..."
  echo ""

  if [ -f "$SCRIPT_DIR/../product-demos-base/deploy.sh" ]; then
    bash "$SCRIPT_DIR/../product-demos-base/deploy.sh"
    echo ""
  else
    echo "❌ ERROR: Cannot find product-demos-base addon"
    echo "Please ensure product-demos-base exists in addons/ directory"
    exit 1
  fi
else
  echo "✓ product-demos-base is installed"
  echo ""
fi

# ==============================================================================
# INSTALL VIA AAP JOB TEMPLATE
# ==============================================================================

echo "Retrieving AAP connection details..."

if ! command -v jq &>/dev/null; then
  echo "❌ ERROR: jq is required"
  exit 1
fi

apd_init_aap_connection || exit 1
echo "✓ AAP credentials retrieved"
echo ""

apd_resolve_domain_install_ids || exit 1

echo "Installing $DEMO_CATEGORY demo resources via AAP job template..."
echo "This may take a few minutes..."
echo ""

if apd_install_domain_demo "$DEMO_CATEGORY"; then
  echo ""
  echo "✓ Red Hat Satellite integration demos installed successfully!"
  echo ""
  echo "Job templates created (prefix: SATELLITE |):"
  echo "  - SATELLITE | Server Registration"
  echo "  - SATELLITE | Promote Content"
  echo "  - SATELLITE | OpenSCAP Scan"
  echo "  - SATELLITE | Publish Content View"
  echo "  ... and more"
  echo ""
  echo "Next steps:"
  echo "  - Log into AAP UI at: ${AAP_UI_URL}"
  echo "  - Navigate to 'Ansible Product Demos (APD)' organization"
  echo "  - Update Satellite credentials (see addons/product-demo-satellite/README.md)"
  echo "  - Run demo job templates"
  echo ""
else
  echo ""
  echo "❌ ERROR: Red Hat Satellite integration demo installation failed"
  echo "Re-run from Templates: $(apd_domain_template_name "$DEMO_CATEGORY")"
  exit 1
fi
