#!/usr/bin/env bash
# Product Demos
#
# Installs all Ansible Product Demos domains in one command: base APD resources
# plus linux, windows, network, cloud, and openshift demo content (Satellite is opt-in).
#
# Environment variables:
#   PRODUCT_DEMOS_DOMAINS - Space-separated domain list (default: five domains, no satellite)
#   PRODUCT_DEMOS_REPO    - Git repository URL
#   PRODUCT_DEMOS_BRANCH  - Git branch to use
#
# Usage:
#   ./deploy.sh          # Deploy base + all domain demos
#   ./deploy.sh --delete # Disable addon (manual AAP cleanup)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../product-demos-base/lib.sh
source "${SCRIPT_DIR}/../product-demos-base/lib.sh"

NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"

PRODUCT_DEMOS_REPO="${PRODUCT_DEMOS_REPO:-https://github.com/ansible/product-demos}"
PRODUCT_DEMOS_BRANCH="${PRODUCT_DEMOS_BRANCH:-main}"
PRODUCT_DEMOS_EE_NAME="${PRODUCT_DEMOS_EE_NAME:-Product Demos EE}"
PRODUCT_DEMOS_DOMAINS="${PRODUCT_DEMOS_DOMAINS:-linux windows network cloud openshift}"

read -r -a DEMO_DOMAINS <<<"$PRODUCT_DEMOS_DOMAINS"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing product demos from AAP..."
  echo ""
  echo "To remove demo job templates, log into AAP UI and delete templates named:"
  echo "  APD | Install Linux Demos"
  echo "  APD | Install Windows Demos"
  echo "  APD | Install Network Demos"
  echo "  APD | Install Cloud Demos"
  echo "  APD | Install OpenShift Demos"
  echo "  APD | Install Satellite Demos"
  echo ""
  echo "Also remove legacy template if present:"
  echo "  APD | Install Domain Demo"
  echo ""
  echo "Also remove demo content templates with prefixes:"
  echo "  LINUX |, WINDOWS |, NETWORK |, CLOUD |, OPENSHIFT |, SATELLITE |"
  echo ""
  echo "✓ product-demos addon disabled"
  exit 0
fi

echo "Deploying Ansible Product Demos (all domains)..."
echo "Domains: ${DEMO_DOMAINS[*]}"
echo ""

if ! kubectl cluster-info &>/dev/null; then
  echo "❌ ERROR: Cannot connect to cluster"
  exit 1
fi

if ! kubectl get aap -n "$NAMESPACE" &>/dev/null; then
  echo "❌ ERROR: AAP not found in namespace $NAMESPACE"
  exit 1
fi

echo "Installing product-demos-base..."
bash "${SCRIPT_DIR}/../product-demos-base/deploy.sh"
echo ""

if ! command -v jq &>/dev/null; then
  echo "❌ ERROR: jq is required"
  exit 1
fi

apd_init_aap_connection || exit 1
apd_resolve_domain_install_ids "$PRODUCT_DEMOS_EE_NAME" || exit 1

echo "Creating per-domain install job templates..."
FAILED_DOMAINS=()
for demo in "${DEMO_DOMAINS[@]}"; do
  echo ""
  if ! apd_install_domain_demo "$demo"; then
    FAILED_DOMAINS+=("$demo")
  fi
done

echo ""
if [ ${#FAILED_DOMAINS[@]} -gt 0 ]; then
  echo "❌ ERROR: Some domains failed to install: ${FAILED_DOMAINS[*]}"
  echo ""
  echo "Re-run a failed domain from Templates in the Default organization:"
  for demo in "${FAILED_DOMAINS[@]}"; do
    echo "  $(apd_domain_template_name "$demo")"
  done
  exit 1
fi

echo "✓ All Ansible Product Demos domains installed!"
echo ""
echo "Domains installed: ${DEMO_DOMAINS[*]}"
echo "Per-domain install templates (Default org):"
for demo in "${DEMO_DOMAINS[@]}"; do
  echo "  $(apd_domain_template_name "$demo")"
done
echo ""
echo "Log into AAP UI at: ${AAP_UI_URL}"
echo "Navigate to the 'Ansible Product Demos (APD)' organization to run demo job templates."
