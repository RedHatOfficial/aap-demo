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
if ! kubectl get aap -n "$NAMESPACE" &> /dev/null; then
  echo "❌ ERROR: AAP not found in namespace $NAMESPACE"
  echo "Please deploy AAP first: aap-demo deploy"
  exit 1
fi

# Get AAP route
echo "Retrieving AAP connection details..."
# Try to get route by AAP CR name first, fall back to first route in namespace
AAP_ROUTE=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$AAP_ROUTE" ]; then
  AAP_ROUTE=$(kubectl get route -n "$NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
fi

if [ -z "$AAP_ROUTE" ]; then
  echo "❌ ERROR: Cannot find AAP route"
  exit 1
fi

AAP_HOSTNAME="https://$AAP_ROUTE"
echo "AAP URL: $AAP_HOSTNAME"

# Get AAP admin credentials
echo "Retrieving AAP admin credentials..."
AAP_USERNAME="admin"
AAP_PASSWORD=$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")

if [ -z "$AAP_PASSWORD" ]; then
  echo "❌ ERROR: Cannot retrieve AAP admin password"
  exit 1
fi

echo "✓ AAP credentials retrieved"
echo ""

# ==============================================================================
# ANSIBLE SETUP
# ==============================================================================

echo "Checking for ansible..."

# Use shared ansible virtual environment
ANSIBLE_VENV="$HOME/.ansible-venv"
ANSIBLE_PLAYBOOK="$ANSIBLE_VENV/bin/ansible-playbook"
ANSIBLE_GALAXY="$ANSIBLE_VENV/bin/ansible-galaxy"

# Verify venv exists
if [ ! -d "$ANSIBLE_VENV" ]; then
  echo "Creating shared ansible virtual environment..."
  if ! command -v python3 &> /dev/null; then
    echo "❌ ERROR: python3 not found"
    exit 1
  fi
  python3 -m venv "$ANSIBLE_VENV"
  echo "✓ Created virtual environment at $ANSIBLE_VENV"
fi

# Install ansible if not present
if [ ! -f "$ANSIBLE_PLAYBOOK" ]; then
  echo "Installing ansible in virtual environment..."
  if "$ANSIBLE_VENV/bin/pip" install ansible; then
    echo "✓ ansible installed successfully"
  else
    echo "❌ ERROR: Failed to install ansible"
    exit 1
  fi
  echo ""
else
  echo "✓ ansible found in shared venv"
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

echo "Installing required Ansible collections..."

# Get PAH URL and token if available
PAH_URL="https://aap-aap-operator.apps.127.0.0.1.nip.io/api/galaxy/"
PAH_TOKEN=""
if [ -f "$HOME/.aap-demo/galaxy-token" ]; then
  PAH_TOKEN=$(cat "$HOME/.aap-demo/galaxy-token")
fi

# Configure ansible-galaxy to use local PAH
if [ -n "$PAH_TOKEN" ]; then
  echo "Configuring ansible-galaxy to use Private Automation Hub..."
  export ANSIBLE_GALAXY_SERVER_LIST="pah,galaxy"
  export ANSIBLE_GALAXY_SERVER_PAH_URL="$PAH_URL"
  export ANSIBLE_GALAXY_SERVER_PAH_TOKEN="$PAH_TOKEN"
  export ANSIBLE_GALAXY_SERVER_GALAXY_URL="https://galaxy.ansible.com/"
  echo "✓ Using PAH at $PAH_URL"
else
  echo "⚠ No PAH token found, using galaxy.ansible.com only"
fi

# Install required collections
"$ANSIBLE_GALAXY" collection install infra.aap_configuration --force
"$ANSIBLE_GALAXY" collection install ansible.platform --force 2>/dev/null || echo "⚠ Could not install ansible.platform (may require PAH sync to complete)"
echo ""

echo "Installing APD base resources in AAP..."
echo "This may take a few minutes..."
echo ""

# Export environment variables for ansible playbook
export AAP_HOSTNAME
export AAP_USERNAME
export AAP_PASSWORD
export AAP_VALIDATE_CERTS=false

# Run the installation playbook
if "$ANSIBLE_PLAYBOOK" install-apd.yml; then
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
  echo "❌ ERROR: APD installation failed"
  echo "Please check the output above for details."
  exit 1
fi

# Cleanup happens automatically via trap
