#!/usr/bin/env bash
# Product Demos
#
# Installs all Ansible Product Demos domains in one command: base APD resources
# plus linux, windows, network, cloud, openshift, and satellite demo content.
#
# Environment variables:
#   PRODUCT_DEMOS_DOMAINS - Space-separated domain list (default: all six)
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
PRODUCT_DEMOS_DOMAINS="${PRODUCT_DEMOS_DOMAINS:-linux windows network cloud openshift satellite}"

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

AAP_ROUTE=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$AAP_ROUTE" ]; then
  AAP_ROUTE=$(kubectl get route -n "$NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
fi

AAP_UI_URL="https://${AAP_ROUTE}"
AAP_API="${AAP_UI_URL}/api/controller/v2"
AAP_USERNAME="admin"
AAP_PASSWORD=$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")

if [ -z "$AAP_PASSWORD" ]; then
  echo "❌ ERROR: Cannot retrieve AAP admin password"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "❌ ERROR: jq is required"
  exit 1
fi

DEFAULT_ORG_ID=$(apd_default_org_id)
if [ -z "$DEFAULT_ORG_ID" ]; then
  echo "❌ ERROR: Cannot resolve Default organization ID"
  exit 1
fi
export DEFAULT_ORG_ID

PROJECT_ID=$(apd_default_bootstrap_project_id)
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/projects/?name=Ansible+Product+Demos" 2>&1 \
    | jq -r --argjson org "$DEFAULT_ORG_ID" \
      '[.results[] | select(.summary_fields.organization.id == $org)] | .[0].id // empty')
fi
EE_ID=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  "${AAP_API}/execution_environments/?name=$(jq -rn --arg n "$PRODUCT_DEMOS_EE_NAME" '$n|@uri')" 2>&1 | jq -r '.results[0].id // empty')
CRED_ID=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  "${AAP_API}/credentials/?name=$(jq -rn --arg n "APD Installer - AAP Admin" '$n|@uri')" 2>&1 | jq -r '.results[0].id // empty')

if [ -z "$PROJECT_ID" ] || [ -z "$EE_ID" ] || [ -z "$CRED_ID" ]; then
  echo "❌ ERROR: Missing APD project, execution environment, or installer credential"
  echo "  project=${PROJECT_ID:-missing} ee=${EE_ID:-missing} credential=${CRED_ID:-missing}"
  exit 1
fi

echo "Cleaning up legacy templates and duplicate Default org projects..."
apd_cleanup_legacy_install_templates
apd_cleanup_default_org_apd_projects

echo "Creating per-domain install job templates..."
FAILED_DOMAINS=()
for demo in "${DEMO_DOMAINS[@]}"; do
  echo ""
  template_name=$(apd_domain_template_name "$demo")
  echo "Installing ${demo} demos (${template_name})..."

  TEMPLATE_ID=$(apd_ensure_domain_job_template "$demo" "$PROJECT_ID" "$EE_ID" "$CRED_ID") || {
    FAILED_DOMAINS+=("$demo")
    continue
  }

  LAUNCH_RESULT=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    "${AAP_API}/job_templates/${TEMPLATE_ID}/launch/" 2>&1)

  JOB_ID=$(echo "$LAUNCH_RESULT" | jq -r '.id // empty' 2>/dev/null)
  if [ -z "$JOB_ID" ]; then
    echo "❌ ERROR: Failed to launch ${demo} install job"
    echo "$LAUNCH_RESULT" | jq '.' 2>/dev/null || echo "$LAUNCH_RESULT"
    FAILED_DOMAINS+=("$demo")
    continue
  fi

  echo "✓ Job launched for ${demo} (ID: ${JOB_ID})"
  echo "View in UI: ${AAP_UI_URL}/#/jobs/playbook/${JOB_ID}/output"
  if ! apd_monitor_job "$JOB_ID" "${demo} demo install" 80; then
    FAILED_DOMAINS+=("$demo")
  fi
  apd_cleanup_default_org_apd_projects
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
