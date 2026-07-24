#!/usr/bin/env bash
# Product Demo - Linux
#
# Installs Linux automation demos from the Ansible Product Demos collection.
# Requires product-demos-base addon (automatically installed if needed).
#
# Creates job templates for:
#   - RHEL system roles
#   - Patching and compliance
#   - Insights integration
#   - Podman containers
#   - Troubleshooting workflows
#
# Environment variables:
#   PRODUCT_DEMOS_REPO   - Git repository URL (default: https://github.com/ansible/product-demos)
#   PRODUCT_DEMOS_BRANCH - Git branch to use (default: main)
#
# Usage:
#   ./deploy.sh          # Deploy Linux demos
#   ./deploy.sh --delete # Remove Linux demos

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"
DEMO_CATEGORY="linux"

# Product demos configuration
PRODUCT_DEMOS_REPO="${PRODUCT_DEMOS_REPO:-https://github.com/ansible/product-demos}"
PRODUCT_DEMOS_BRANCH="${PRODUCT_DEMOS_BRANCH:-main}"

# ==============================================================================
# DELETE HANDLER
# ==============================================================================

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing Linux demo resources from AAP..."
  echo ""
  echo "To remove Linux demo job templates, log into AAP UI and:"
  echo "  1. Navigate to the 'Ansible Product Demos (APD)' organization"
  echo "  2. Go to Templates"
  echo "  3. Delete templates starting with 'LINUX |'"
  echo ""
  echo "✓ product-demo-linux addon disabled"
  exit 0
fi

# ==============================================================================
# DEPLOYMENT
# ==============================================================================

echo "Deploying Ansible Product Demos - Linux..."
echo ""

# Check cluster connectivity
if ! kubectl cluster-info &> /dev/null; then
  echo "❌ ERROR: Cannot connect to cluster"
  echo "Please ensure your cluster is running: aap-demo status"
  exit 1
fi

# Check if AAP is deployed
if ! kubectl get aap-gateway -n "$NAMESPACE" &> /dev/null; then
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
# GET AAP CREDENTIALS
# ==============================================================================

echo "Retrieving AAP connection details..."

AAP_ROUTE=$(kubectl get route -n "$NAMESPACE" -l app.kubernetes.io/component=gateway -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

if [ -z "$AAP_ROUTE" ]; then
  echo "❌ ERROR: Cannot find AAP gateway route"
  exit 1
fi

AAP_HOSTNAME="https://$AAP_ROUTE"

ADMIN_SECRET=$(kubectl get secret -n "$NAMESPACE" -l app.kubernetes.io/component=gateway-admin-password -o name 2>/dev/null | head -n1)

if [ -z "$ADMIN_SECRET" ]; then
  echo "❌ ERROR: Cannot find AAP admin secret"
  exit 1
fi

AAP_USERNAME="admin"
AAP_PASSWORD=$(kubectl get "$ADMIN_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

if [ -z "$AAP_PASSWORD" ]; then
  echo "❌ ERROR: Cannot retrieve AAP admin password"
  exit 1
fi

echo "✓ AAP credentials retrieved"
echo ""

# ==============================================================================
# VERIFY ANSIBLE-NAVIGATOR
# ==============================================================================

if ! command -v ansible-navigator &> /dev/null; then
  echo "❌ ERROR: ansible-navigator not found"
  echo "This should have been installed by product-demos-base."
  echo "Please try: aap-demo enable product-demos-base"
  exit 1
fi

# ==============================================================================
# CLONE PRODUCT DEMOS REPOSITORY
# ==============================================================================

echo "Cloning product-demos repository..."

TEMP_DIR=$(mktemp -d /tmp/product-demos.XXXXXX)
trap 'rm -rf "$TEMP_DIR"' EXIT

cd "$TEMP_DIR"

if ! git clone --depth 1 --branch "$PRODUCT_DEMOS_BRANCH" "$PRODUCT_DEMOS_REPO" . 2>&1; then
  echo "❌ ERROR: Failed to clone $PRODUCT_DEMOS_REPO (branch: $PRODUCT_DEMOS_BRANCH)"
  exit 1
fi

echo "✓ Repository cloned"
echo ""

# ==============================================================================
# RUN DOMAIN-SPECIFIC SETUP
# ==============================================================================

echo "Installing $DEMO_CATEGORY demo resources in AAP..."
echo "This may take a few minutes..."
echo ""

# Export environment variables
export AAP_HOSTNAME
export AAP_USERNAME
export AAP_PASSWORD
export AAP_VALIDATE_CERTS=false

# Run the domain-specific setup playbook
if ansible-navigator run -m stdout setup_demo.yml -e "demo=$DEMO_CATEGORY"; then
  echo ""
  echo "✓ Linux demos installed successfully!"
  echo ""
  echo "Job templates created (prefix: LINUX |):"
  echo "  - LINUX | Register with Insights"
  echo "  - LINUX | Fact Scan"
  echo "  - LINUX | Patching"
  echo "  - LINUX | Hardening"
  echo "  - LINUX | System Roles"
  echo "  - LINUX | Podman"
  echo "  - LINUX | Troubleshooting"
  echo "  ... and more"
  echo ""
  echo "Next steps:"
  echo "  - Log into AAP UI at: $AAP_HOSTNAME"
  echo "  - Navigate to 'Ansible Product Demos (APD)' organization"
  echo "  - Configure the 'Insights Inventory' credential with your Red Hat account"
  echo "  - Add managed Linux hosts to the inventory"
  echo "  - Run demo job templates"
  echo ""
else
  echo ""
  echo "❌ ERROR: Linux demo installation failed"
  echo "Please check the output above for details."
  exit 1
fi

# Cleanup happens automatically via trap
