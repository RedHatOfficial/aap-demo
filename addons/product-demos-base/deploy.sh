#!/usr/bin/env bash
# Product Demos Base Addon
#
# Installs the Ansible Product Demos (APD) foundation in AAP.
# This addon creates the APD organization, project, execution environment,
# base credentials, and inventory. It is automatically invoked as a dependency
# by domain-specific product-demo-* addons.
#
# Environment variables:
#   PRODUCT_DEMOS_REPO   - Git repository URL (default: https://github.com/ansible/product-demos)
#   PRODUCT_DEMOS_BRANCH - Git branch to use (default: main)
#
# Usage:
#   ./deploy.sh          # Deploy base APD resources
#   ./deploy.sh --delete # Remove base APD resources

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"

# Product demos configuration
PRODUCT_DEMOS_REPO="${PRODUCT_DEMOS_REPO:-https://github.com/ansible/product-demos}"
PRODUCT_DEMOS_BRANCH="${PRODUCT_DEMOS_BRANCH:-main}"

# ==============================================================================
# DELETE HANDLER
# ==============================================================================

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Checking if base APD resources can be removed..."

  # Check if any domain addons are still enabled
  DOMAIN_ADDONS=("product-demo-linux" "product-demo-windows" "product-demo-network" "product-demo-cloud" "product-demo-openshift" "product-demo-satellite")
  ENABLED_DOMAINS=()

  if [ -f ~/.aap-demo/config ]; then
    for domain in "${DOMAIN_ADDONS[@]}"; do
      if grep -q "$domain" ~/.aap-demo/config 2>/dev/null; then
        ENABLED_DOMAINS+=("$domain")
      fi
    done
  fi

  if [ ${#ENABLED_DOMAINS[@]} -gt 0 ]; then
    echo "⚠ Cannot remove product-demos-base while domain addons are enabled:"
    for domain in "${ENABLED_DOMAINS[@]}"; do
      echo "  - $domain"
    done
    echo ""
    echo "Please disable all domain addons first:"
    for domain in "${ENABLED_DOMAINS[@]}"; do
      echo "  aap-demo disable $domain"
    done
    exit 1
  fi

  echo "Removing APD base resources from AAP..."
  echo "⚠ This will remove the 'Ansible Product Demos (APD)' organization and all its resources."
  echo ""
  read -p "Are you sure you want to continue? [y/N] " -n 1 -r
  echo

  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deletion cancelled."
    exit 0
  fi

  # Note: Deleting the organization would require AAP API calls or ansible-navigator
  # For now, provide manual instructions
  echo ""
  echo "To remove APD resources, log into AAP UI and:"
  echo "  1. Navigate to Organizations"
  echo "  2. Delete 'Ansible Product Demos (APD)' organization"
  echo "  3. (Optional) Remove the Product Demos EE from Execution Environments"
  echo ""
  echo "✓ product-demos-base addon disabled (resources remain in AAP until manually removed)"
  exit 0
fi

# ==============================================================================
# DEPLOYMENT
# ==============================================================================

echo "Deploying Ansible Product Demos base resources..."
echo "Repository: $PRODUCT_DEMOS_REPO"
echo "Branch: $PRODUCT_DEMOS_BRANCH"
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

# Get AAP gateway route
echo "Retrieving AAP connection details..."
AAP_ROUTE=$(kubectl get route -n "$NAMESPACE" -l app.kubernetes.io/component=gateway -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

if [ -z "$AAP_ROUTE" ]; then
  echo "❌ ERROR: Cannot find AAP gateway route"
  exit 1
fi

AAP_HOSTNAME="https://$AAP_ROUTE"
echo "AAP URL: $AAP_HOSTNAME"

# Get AAP admin credentials
echo "Retrieving AAP admin credentials..."
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
# ANSIBLE-NAVIGATOR INSTALLATION
# ==============================================================================

echo "Checking for ansible-navigator..."

if ! command -v ansible-navigator &> /dev/null; then
  echo "ansible-navigator not found. Installing..."

  # Try pipx first (isolated, recommended)
  if command -v pipx &> /dev/null; then
    echo "Installing via pipx (isolated environment)..."
    if pipx install ansible-navigator; then
      echo "✓ ansible-navigator installed via pipx"
    else
      echo "❌ ERROR: pipx installation failed"
      exit 1
    fi
  # Fall back to pip3
  elif command -v pip3 &> /dev/null; then
    echo "Installing via pip3 (user install)..."
    if pip3 install --user ansible-navigator; then
      echo "✓ ansible-navigator installed via pip3"
      echo "⚠ You may need to add ~/.local/bin to your PATH"
    else
      echo "❌ ERROR: pip3 installation failed"
      exit 1
    fi
  else
    echo "❌ ERROR: Cannot install ansible-navigator"
    echo "Please install pip3 or pipx first:"
    echo "  macOS: brew install pipx"
    echo "  Linux: sudo apt install pipx  # or sudo dnf install pipx"
    exit 1
  fi

  # Verify installation
  if ! command -v ansible-navigator &> /dev/null; then
    echo "❌ ERROR: ansible-navigator installation failed"
    echo "Please install manually: pip3 install ansible-navigator"
    exit 1
  fi

  echo ""
else
  echo "✓ ansible-navigator found: $(command -v ansible-navigator)"
  echo ""
fi

# ==============================================================================
# CLONE PRODUCT DEMOS REPOSITORY
# ==============================================================================

echo "Cloning product-demos repository..."

# Create temporary directory with cleanup trap
TEMP_DIR=$(mktemp -d /tmp/product-demos.XXXXXX)
trap 'rm -rf "$TEMP_DIR"' EXIT

cd "$TEMP_DIR"

if ! git clone --depth 1 --branch "$PRODUCT_DEMOS_BRANCH" "$PRODUCT_DEMOS_REPO" . 2>&1; then
  echo "❌ ERROR: Failed to clone $PRODUCT_DEMOS_REPO (branch: $PRODUCT_DEMOS_BRANCH)"
  echo "Please check the repository URL and branch name."
  exit 1
fi

echo "✓ Repository cloned to temporary directory"
echo ""

# ==============================================================================
# RUN ANSIBLE-NAVIGATOR
# ==============================================================================

echo "Installing APD base resources in AAP..."
echo "This may take a few minutes..."
echo ""

# Export environment variables for ansible-navigator
export AAP_HOSTNAME
export AAP_USERNAME
export AAP_PASSWORD
export AAP_VALIDATE_CERTS=false

# Run the installation playbook
if ansible-navigator run -m stdout install-apd.yml; then
  echo ""
  echo "✓ APD base resources installed successfully!"
  echo ""
  echo "Resources created:"
  echo "  - Organization: Ansible Product Demos (APD)"
  echo "  - Project: Ansible Product Demos"
  echo "  - Execution Environment: Product Demos EE"
  echo "  - Inventory: Ansible Product Demos Inventory"
  echo "  - Job Templates: APD | Single demo setup, APD | Multi-demo setup"
  echo ""
  echo "Next steps:"
  echo "  - Enable a domain-specific addon: aap-demo enable product-demo-linux"
  echo "  - Log into AAP UI at: $AAP_HOSTNAME"
  echo "  - Navigate to the 'Ansible Product Demos (APD)' organization"
  echo "  - Configure credentials as needed (Galaxy tokens, AWS, etc.)"
  echo ""
else
  echo ""
  echo "❌ ERROR: ansible-navigator installation failed"
  echo "Please check the output above for details."
  exit 1
fi

# Cleanup happens automatically via trap
