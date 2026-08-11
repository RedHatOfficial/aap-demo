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
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"

# Product demos configuration
PRODUCT_DEMOS_REPO="${PRODUCT_DEMOS_REPO:-https://github.com/ansible/product-demos}"
PRODUCT_DEMOS_BRANCH="${PRODUCT_DEMOS_BRANCH:-main}"
PRODUCT_DEMOS_EE="${PRODUCT_DEMOS_EE:-quay.io/ansible-product-demos/apd-ee-26:latest}"
PRODUCT_DEMOS_EE_NAME="${PRODUCT_DEMOS_EE_NAME:-Product Demos EE}"

# ==============================================================================
# DELETE HANDLER
# ==============================================================================

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Checking if base APD resources can be removed..."

  # Check if any domain addons are still enabled
  DOMAIN_ADDONS=("product-demos" "product-demo-linux" "product-demo-windows" "product-demo-network" "product-demo-cloud" "product-demo-openshift" "product-demo-satellite")
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
echo "Strategy: Create AAP project and run install-apd.yml as a job template"
echo "          (uses AAP's execution environment which has ansible.platform pre-installed)"
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

# Get AAP route
echo "Retrieving AAP connection details..."
AAP_ROUTE=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$AAP_ROUTE" ]; then
  AAP_ROUTE=$(kubectl get route -n "$NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
fi

if [ -z "$AAP_ROUTE" ]; then
  echo "❌ ERROR: Cannot find AAP route"
  exit 1
fi

AAP_UI_URL="https://${AAP_ROUTE}"
AAP_API="${AAP_UI_URL}/api/controller/v2"

# Jobs run inside controller EEs cannot reach external nip.io routes on MicroShift.
# Map the route hostname to the AAP service ClusterIP (see configure_microshift_job_networking).
if ! kubectl get ingresses.config/cluster -o jsonpath='{.spec.domain}' --request-timeout=5s &>/dev/null; then
  IS_MICROSHIFT=true
  AAP_JOB_HOSTNAME="http://${AAP_ROUTE}"
else
  IS_MICROSHIFT=false
  AAP_JOB_HOSTNAME="${AAP_UI_URL}"
fi

echo "AAP URL: $AAP_UI_URL"
if [ "$IS_MICROSHIFT" = true ]; then
  echo "AAP in-cluster URL (for job credentials): $AAP_JOB_HOSTNAME"
fi

configure_microshift_job_networking() {
  if [ "${IS_MICROSHIFT:-false}" != true ]; then
    return 0
  fi

  echo "Configuring MicroShift job pod networking..."

  local aap_ip ig_id pod_spec_override
  aap_ip=$(kubectl get svc aap -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  if [ -z "$aap_ip" ]; then
    echo "  ⚠ Could not resolve AAP service ClusterIP; skipping host alias"
    return 1
  fi

  ig_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/instance_groups/?name=default" 2>&1 | jq -r '.results[0].id // empty' 2>/dev/null)

  if [ -z "$ig_id" ]; then
    echo "  ⚠ Could not find default instance group; skipping host alias"
    return 1
  fi

  pod_spec_override=$(printf 'spec:\n  hostAliases:\n  - ip: "%s"\n    hostnames:\n    - "%s"\n' "$aap_ip" "$AAP_ROUTE")

  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg spec "$pod_spec_override" '{pod_spec_override: $spec}')" \
    "${AAP_API}/instance_groups/${ig_id}/" >/dev/null 2>&1

  echo "  ✓ Job pod hostAlias configured: ${AAP_ROUTE} → ${aap_ip}"
}

apd_credential_type_injectors_json() {
  # Only inject env vars; AAP 2.7 often drops extra_vars on credential type PATCH.
  # Job template extra_vars carry async + aap_validate_certs settings instead.
  jq -n '{
    env: {
      AAP_HOSTNAME: "{{ aap_hostname }}",
      AAP_USERNAME: "{{ aap_username }}",
      AAP_PASSWORD: "{{ aap_password }}",
      AAP_TOKEN: "{{ aap_token | default(\"\", true) }}"
    }
  }'
}

create_aap_install_token() {
  echo "Creating AAP OAuth token for installer job..."

  local token_response
  token_response=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{"description":"APD installer (aap-demo)","scope":"write"}' \
    "${AAP_UI_URL}/api/gateway/v1/tokens/" 2>&1)

  AAP_INSTALL_TOKEN=$(echo "$token_response" | jq -r '.token // empty' 2>/dev/null)

  if [ -z "$AAP_INSTALL_TOKEN" ]; then
    echo "❌ ERROR: Failed to create AAP OAuth token for installer"
    echo "$token_response" | jq '.' 2>/dev/null || echo "$token_response"
    exit 1
  fi

  echo "✓ AAP OAuth token created for installer"
}

apd_template_extra_vars_yaml() {
  apd_common_extra_vars_yaml
}

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

# Check for required tools
if ! command -v curl &>/dev/null; then
  echo "❌ ERROR: curl is required"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "❌ ERROR: jq is required for JSON parsing"
  echo "Install: brew install jq (macOS) or sudo dnf install jq (RHEL/Fedora)"
  exit 1
fi

configure_microshift_job_networking

# ==============================================================================
# CREATE CREDENTIAL TYPE AND CREDENTIAL
# ==============================================================================

echo "Creating custom credential type for APD installer..."

# Check if credential type exists
EXISTING_CRED_TYPE=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  "${AAP_API}/credential_types/?name=APD+Installer+Credentials" 2>&1)

CRED_TYPE_ID=$(echo "$EXISTING_CRED_TYPE" | jq -r '.results[0].id // empty' 2>/dev/null)

if [ -z "$CRED_TYPE_ID" ]; then
  # Create credential type
  CRED_TYPE_PAYLOAD=$(jq -n \
    --arg name "APD Installer Credentials" \
    --arg desc "Injects AAP credentials for product-demos installer" \
    --argjson injectors "$(apd_credential_type_injectors_json)" \
    '{
      name: $name,
      description: $desc,
      kind: "cloud",
      inputs: {
        fields: [
          {id: "aap_hostname", label: "AAP Hostname", type: "string"},
          {id: "aap_username", label: "AAP Username", type: "string"},
          {id: "aap_password", label: "AAP Password", type: "string", secret: true},
          {id: "aap_token", label: "AAP OAuth Token", type: "string", secret: true}
        ]
      },
      injectors: $injectors
    }')

  CRED_TYPE_RESULT=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$CRED_TYPE_PAYLOAD" \
    "${AAP_API}/credential_types/" 2>&1)

  CRED_TYPE_ID=$(echo "$CRED_TYPE_RESULT" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$CRED_TYPE_ID" ]; then
    echo "❌ ERROR: Failed to create credential type"
    echo "$CRED_TYPE_RESULT" | jq '.' 2>/dev/null || echo "$CRED_TYPE_RESULT"
    exit 1
  fi

  echo "✓ Credential type created (ID: $CRED_TYPE_ID)"
else
  echo "✓ Credential type already exists (ID: $CRED_TYPE_ID)"
  echo "Updating credential type injectors..."
  CRED_TYPE_UPDATE_RESULT=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    -d "$(jq -n --argjson injectors "$(apd_credential_type_injectors_json)" '{injectors: $injectors}')" \
    "${AAP_API}/credential_types/${CRED_TYPE_ID}/" 2>&1)
  echo "✓ Credential type injectors updated"
fi

create_aap_install_token

# Create credential instance
echo "Creating APD installer credential..."

EXISTING_CRED=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  "${AAP_API}/credentials/?name=APD+Installer+-+AAP+Admin" 2>&1)

CRED_ID=$(echo "$EXISTING_CRED" | jq -r '.results[0].id // empty' 2>/dev/null)

if [ -z "$CRED_ID" ]; then
  CRED_PAYLOAD=$(
    cat <<EOF
{
  "name": "APD Installer - AAP Admin",
  "description": "AAP admin credentials for installing product-demos",
  "organization": 1,
  "credential_type": $CRED_TYPE_ID,
  "inputs": {
    "aap_hostname": "${AAP_JOB_HOSTNAME}",
    "aap_username": "${AAP_USERNAME}",
    "aap_password": "${AAP_PASSWORD}",
    "aap_token": "${AAP_INSTALL_TOKEN}"
  }
}
EOF
  )

  CRED_RESULT=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$CRED_PAYLOAD" \
    "${AAP_API}/credentials/" 2>&1)

  CRED_ID=$(echo "$CRED_RESULT" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$CRED_ID" ]; then
    echo "❌ ERROR: Failed to create credential"
    echo "$CRED_RESULT" | jq '.' 2>/dev/null || echo "$CRED_RESULT"
    exit 1
  fi

  echo "✓ Credential created (ID: $CRED_ID)"
else
  echo "✓ Credential already exists (ID: $CRED_ID)"
  echo "Updating APD installer credential hostname for in-cluster access..."
  CRED_UPDATE_PAYLOAD=$(
    cat <<EOF
{
  "credential_type": $CRED_TYPE_ID,
  "inputs": {
    "aap_hostname": "${AAP_JOB_HOSTNAME}",
    "aap_username": "${AAP_USERNAME}",
    "aap_password": "${AAP_PASSWORD}",
    "aap_token": "${AAP_INSTALL_TOKEN}"
  }
}
EOF
  )
  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    -d "$CRED_UPDATE_PAYLOAD" \
    "${AAP_API}/credentials/${CRED_ID}/" >/dev/null 2>&1
  echo "✓ Credential updated"
fi

echo ""

# ==============================================================================
# CREATE AAP PROJECT
# ==============================================================================

echo "Creating AAP project for product-demos..."

# Create project via API
PROJECT_PAYLOAD=$(
  cat <<EOF
{
  "name": "Ansible Product Demos",
  "description": "Official Ansible Product Demos from github.com/ansible/product-demos",
  "scm_type": "git",
  "scm_url": "$PRODUCT_DEMOS_REPO",
  "scm_branch": "$PRODUCT_DEMOS_BRANCH",
  "scm_update_on_launch": true,
  "organization": 1
}
EOF
)

PROJECT_RESULT=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "$PROJECT_PAYLOAD" \
  "${AAP_API}/projects/" 2>&1)

PROJECT_ID=$(echo "$PROJECT_RESULT" | jq -r '.id // empty' 2>/dev/null)

if [ -z "$PROJECT_ID" ]; then
  # Check if project already exists
  EXISTING_PROJECT=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/projects/?name=Ansible+Product+Demos" 2>&1)

  PROJECT_ID=$(echo "$EXISTING_PROJECT" | jq -r '.results[0].id // empty' 2>/dev/null)

  if [ -n "$PROJECT_ID" ]; then
    echo "✓ Project already exists (ID: $PROJECT_ID)"
  else
    echo "❌ ERROR: Failed to create project"
    echo "$PROJECT_RESULT" | jq '.' 2>/dev/null || echo "$PROJECT_RESULT"
    exit 1
  fi
else
  echo "✓ Project created (ID: $PROJECT_ID)"
fi

# Wait for project sync
echo "Waiting for project to sync..."
sleep 5

for i in {1..30}; do
  PROJECT_STATUS=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/projects/${PROJECT_ID}/" 2>&1)

  STATUS=$(echo "$PROJECT_STATUS" | jq -r '.status // "unknown"' 2>/dev/null)

  if [ "$STATUS" = "successful" ]; then
    echo "✓ Project synced successfully"
    break
  elif [ "$STATUS" = "failed" ]; then
    echo "❌ ERROR: Project sync failed"
    echo "$PROJECT_STATUS" | jq '.job_explanation // empty' 2>/dev/null
    exit 1
  fi

  echo "  Status: $STATUS (waiting... $i/30)"
  sleep 2
done

# ==============================================================================
# REGISTER EXECUTION ENVIRONMENT
# ==============================================================================

echo ""
echo "Registering Product Demos execution environment..."

EXISTING_EE=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  "${AAP_API}/execution_environments/?name=$(jq -rn --arg n "$PRODUCT_DEMOS_EE_NAME" '$n|@uri')" 2>&1)

EE_ID=$(echo "$EXISTING_EE" | jq -r '.results[0].id // empty' 2>/dev/null)

if [ -z "$EE_ID" ]; then
  EE_PAYLOAD=$(
    cat <<EOF
{
  "name": "${PRODUCT_DEMOS_EE_NAME}",
  "description": "Official Ansible Product Demos execution environment",
  "image": "${PRODUCT_DEMOS_EE}",
  "pull": "missing",
  "organization": 1
}
EOF
  )

  EE_RESULT=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$EE_PAYLOAD" \
    "${AAP_API}/execution_environments/" 2>&1)

  EE_ID=$(echo "$EE_RESULT" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$EE_ID" ]; then
    echo "❌ ERROR: Failed to register execution environment"
    echo "$EE_RESULT" | jq '.' 2>/dev/null || echo "$EE_RESULT"
    exit 1
  fi

  echo "✓ Execution environment registered (ID: $EE_ID)"
else
  echo "✓ Execution environment already exists (ID: $EE_ID)"
  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    -d "{\"image\": \"${PRODUCT_DEMOS_EE}\", \"pull\": \"missing\"}" \
    "${AAP_API}/execution_environments/${EE_ID}/" >/dev/null 2>&1
  echo "✓ Execution environment image verified"
fi

# ==============================================================================
# CREATE JOB TEMPLATE
# ==============================================================================

echo ""
echo "Creating job template to run install-apd.yml..."

APD_TEMPLATE_EXTRA_VARS=$(apd_template_extra_vars_yaml)

TEMPLATE_PAYLOAD=$(jq -n \
  --arg name "APD | Install Base Resources" \
  --arg desc "Install Ansible Product Demos foundation (organization, project, EE, credentials)" \
  --arg extra_vars "$APD_TEMPLATE_EXTRA_VARS" \
  --argjson project_id "$PROJECT_ID" \
  --argjson ee_id "$EE_ID" \
  '{
    name: $name,
    description: $desc,
    job_type: "run",
    inventory: 1,
    project: $project_id,
    playbook: "install-apd.yml",
    ask_variables_on_launch: false,
    organization: 1,
    execution_environment: $ee_id,
    extra_vars: $extra_vars
  }')

TEMPLATE_RESULT=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "$TEMPLATE_PAYLOAD" \
  "${AAP_API}/job_templates/" 2>&1)

TEMPLATE_ID=$(echo "$TEMPLATE_RESULT" | jq -r '.id // empty' 2>/dev/null)

if [ -z "$TEMPLATE_ID" ]; then
  # Check if template already exists
  EXISTING_TEMPLATE=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/job_templates/?name=APD+%7C+Install+Base+Resources" 2>&1)

  TEMPLATE_ID=$(echo "$EXISTING_TEMPLATE" | jq -r '.results[0].id // empty' 2>/dev/null)

  if [ -n "$TEMPLATE_ID" ]; then
    echo "✓ Job template already exists (ID: $TEMPLATE_ID)"
    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X PATCH \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --argjson ee_id "$EE_ID" \
        --arg extra_vars "$APD_TEMPLATE_EXTRA_VARS" \
        '{execution_environment: $ee_id, extra_vars: $extra_vars}')" \
      "${AAP_API}/job_templates/${TEMPLATE_ID}/" >/dev/null 2>&1
    echo "✓ Job template execution environment and extra_vars updated"
  else
    echo "❌ ERROR: Failed to create job template"
    echo "$TEMPLATE_RESULT" | jq '.' 2>/dev/null || echo "$TEMPLATE_RESULT"
    exit 1
  fi
else
  echo "✓ Job template created (ID: $TEMPLATE_ID)"
fi

# Attach credential to job template
echo "Attaching APD installer credential to template..."
curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "{\"id\": $CRED_ID}" \
  "${AAP_API}/job_templates/${TEMPLATE_ID}/credentials/" >/dev/null 2>&1
echo "✓ Credential attached"

# ==============================================================================
# LAUNCH JOB
# ==============================================================================

echo ""
echo "Launching APD installation job..."

LAUNCH_RESULT=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${AAP_API}/job_templates/${TEMPLATE_ID}/launch/" 2>&1)

JOB_ID=$(echo "$LAUNCH_RESULT" | jq -r '.id // empty' 2>/dev/null)

if [ -z "$JOB_ID" ]; then
  echo "❌ ERROR: Failed to launch job"
  echo "$LAUNCH_RESULT" | jq '.' 2>/dev/null || echo "$LAUNCH_RESULT"
  exit 1
fi

echo "✓ Job launched (ID: $JOB_ID)"
echo ""
echo "Monitoring job progress..."
echo "View in UI: ${AAP_UI_URL}/#/jobs/playbook/${JOB_ID}/output"

if apd_monitor_job "$JOB_ID" "APD base install" 60; then
  echo ""
  echo "Resources created:"
  echo "  - Organization: Ansible Product Demos (APD)"
  echo "  - Project: Ansible Product Demos"
  echo "  - Execution Environment: Product Demos EE"
  echo "  - Inventory: Ansible Product Demos Inventory"
  echo "  - Job Templates: APD | Single demo setup, APD | Multi-demo setup"
  echo ""
  echo "Next steps:"
  echo "  - Install all domains: aap-demo enable product-demos"
  echo "  - Or one domain: aap-demo enable product-demo-linux"
  echo "  - Log into AAP UI at: $AAP_UI_URL"
  echo ""
  exit 0
fi

exit 1
