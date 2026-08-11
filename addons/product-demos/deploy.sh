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
  echo "To remove demo job templates, log into AAP UI and delete templates with prefixes:"
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

PROJECT_ID=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  "${AAP_API}/projects/?name=$(jq -rn --arg n "Ansible Product Demos" '$n|@uri')" 2>&1 | jq -r '.results[0].id // empty')
EE_ID=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  "${AAP_API}/execution_environments/?name=$(jq -rn --arg n "$PRODUCT_DEMOS_EE_NAME" '$n|@uri')" 2>&1 | jq -r '.results[0].id // empty')
CRED_ID=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  "${AAP_API}/credentials/?name=$(jq -rn --arg n "APD Installer - AAP Admin" '$n|@uri')" 2>&1 | jq -r '.results[0].id // empty')

if [ -z "$PROJECT_ID" ] || [ -z "$EE_ID" ] || [ -z "$CRED_ID" ]; then
  echo "❌ ERROR: Missing APD project, execution environment, or installer credential"
  echo "  project=${PROJECT_ID:-missing} ee=${EE_ID:-missing} credential=${CRED_ID:-missing}"
  exit 1
fi

DOMAIN_TEMPLATE_NAME="APD | Install Domain Demo"
DOMAIN_TEMPLATE_EXTRA_VARS=$(apd_common_extra_vars_yaml)

TEMPLATE_PAYLOAD=$(jq -n \
  --arg name "$DOMAIN_TEMPLATE_NAME" \
  --arg desc "Install one Ansible Product Demos domain via setup_demo.yml" \
  --arg extra_vars "$DOMAIN_TEMPLATE_EXTRA_VARS" \
  --argjson project_id "$PROJECT_ID" \
  --argjson ee_id "$EE_ID" \
  '{
    name: $name,
    description: $desc,
    job_type: "run",
    inventory: 1,
    project: $project_id,
    playbook: "setup_demo.yml",
    ask_variables_on_launch: true,
    organization: 1,
    execution_environment: $ee_id,
    extra_vars: $extra_vars
  }')

echo "Creating domain install job template..."
TEMPLATE_RESULT=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "$TEMPLATE_PAYLOAD" \
  "${AAP_API}/job_templates/" 2>&1)

DOMAIN_TEMPLATE_ID=$(echo "$TEMPLATE_RESULT" | jq -r '.id // empty' 2>/dev/null)

if [ -z "$DOMAIN_TEMPLATE_ID" ]; then
  EXISTING_TEMPLATE=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/job_templates/?name=APD+%7C+Install+Domain+Demo" 2>&1)
  DOMAIN_TEMPLATE_ID=$(echo "$EXISTING_TEMPLATE" | jq -r '.results[0].id // empty' 2>/dev/null)

  if [ -z "$DOMAIN_TEMPLATE_ID" ]; then
    echo "❌ ERROR: Failed to create domain install job template"
    echo "$TEMPLATE_RESULT" | jq '.' 2>/dev/null || echo "$TEMPLATE_RESULT"
    exit 1
  fi

  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --argjson ee_id "$EE_ID" \
      --argjson project_id "$PROJECT_ID" \
      --arg extra_vars "$DOMAIN_TEMPLATE_EXTRA_VARS" \
      '{execution_environment: $ee_id, project: $project_id, extra_vars: $extra_vars, ask_variables_on_launch: true}')" \
    "${AAP_API}/job_templates/${DOMAIN_TEMPLATE_ID}/" >/dev/null 2>&1
  echo "✓ Domain install job template already exists (ID: $DOMAIN_TEMPLATE_ID)"
else
  echo "✓ Domain install job template created (ID: $DOMAIN_TEMPLATE_ID)"
fi

curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "{\"id\": $CRED_ID}" \
  "${AAP_API}/job_templates/${DOMAIN_TEMPLATE_ID}/credentials/" >/dev/null 2>&1 || true

FAILED_DOMAINS=()
for demo in "${DEMO_DOMAINS[@]}"; do
  echo ""
  echo "Installing ${demo} demos..."
  LAUNCH_PAYLOAD=$(apd_launch_extra_vars_json "$demo")

  LAUNCH_RESULT=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$(jq -n --argjson extra_vars "$LAUNCH_PAYLOAD" '{extra_vars: $extra_vars}')" \
    "${AAP_API}/job_templates/${DOMAIN_TEMPLATE_ID}/launch/" 2>&1)

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
done

echo ""
if [ ${#FAILED_DOMAINS[@]} -gt 0 ]; then
  echo "❌ ERROR: Some domains failed to install: ${FAILED_DOMAINS[*]}"
  exit 1
fi

echo "✓ All Ansible Product Demos domains installed!"
echo ""
echo "Domains installed: ${DEMO_DOMAINS[*]}"
echo "Log into AAP UI at: ${AAP_UI_URL}"
echo "Navigate to the 'Ansible Product Demos (APD)' organization to run demo job templates."
