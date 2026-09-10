#!/usr/bin/env bash
# Deploy OPA (Open Policy Agent) for AAP Policy as Code
# ADDON_REQUIRES_AAP=true
#
# Deploys an OPA server to enable Policy as Code functionality in AAP 2.7+.
# Downloads deployment manifests from upstream GitHub repository and creates
# job templates for managing policy examples.
#
# Prerequisites:
#   - AAP deployed (aap-demo deploy)
#   - kubectl, curl, jq, base64 available
#
# Environment Variables:
#   OPA_VERSION        - OPA container image version (default: 1.20.2)
#   OPA_REPO           - Upstream OPA examples repo (default: ansible/example-opa-policy-for-aap)
#   OPA_BRANCH         - Branch of upstream repo (default: main)
#   AAP_DEMO_REPO      - AAP Demo repo containing playbooks (default: RedHatOfficial/aap-demo)
#   AAP_DEMO_BRANCH    - Branch with playbooks (default: main)
#
# Usage:
#   ./deploy.sh          # Deploy OPA server and create job templates
#   ./deploy.sh --delete # Remove OPA server and job templates

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"

# Configuration
# Note: Using latest stable OPA. Some upstream example policies fail due to
# missing 'import rego.v1' statements (upstream issue, not version problem).
OPA_VERSION="${OPA_VERSION:-1.20.2}"
OPA_REPO="${OPA_REPO:-https://github.com/ansible/example-opa-policy-for-aap}"
OPA_MANIFEST_REF="${OPA_MANIFEST_REF:-59d83e0689}" # Pinned commit SHA for supply chain security

# AAP Demo repository configuration (contains our playbooks)
AAP_DEMO_REPO="${AAP_DEMO_REPO:-https://github.com/RedHatOfficial/aap-demo.git}"
AAP_DEMO_BRANCH="${AAP_DEMO_BRANCH:-main}"

# AAP API configuration (populated by init_aap_connection)
AAP_ROUTE=""
AAP_PASSWORD=""
AAP_API=""
AAP_USERNAME="admin"
DEFAULT_ORG_ID="1"

# ── Utility Functions ─────────────────────────────────────────────────────────

check_prerequisites() {
  echo "Checking prerequisites..."

  # Check cluster connectivity
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "❌ ERROR: kubectl not connected to cluster"
    exit 1
  fi

  # Check AAP is deployed
  if ! kubectl get aap aap -n "$NAMESPACE" &>/dev/null; then
    echo "❌ ERROR: AAP not deployed in namespace '$NAMESPACE'"
    echo "  Deploy AAP first: aap-demo deploy"
    exit 1
  fi

  # Check AAP is ready
  local aap_status
  aap_status=$(kubectl get aap aap -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || echo "Unknown")
  if [ "$aap_status" != "True" ]; then
    echo "❌ ERROR: AAP is not ready (status: $aap_status)"
    echo "  Wait for AAP to deploy: aap-demo status"
    exit 1
  fi

  # Check required commands
  for cmd in kubectl curl jq base64; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "❌ ERROR: Required command not found: $cmd"
      exit 1
    fi
  done

  echo "✓ Prerequisites satisfied"
}

# Feature flag functions removed - no longer required in AAP 2.7+

deploy_opa_server() {
  echo "Downloading OPA deployment manifest from upstream..."

  local manifest_url="https://raw.githubusercontent.com/ansible/example-opa-policy-for-aap/${OPA_MANIFEST_REF}/openshift/opa-deployment.yaml"
  local manifest

  # Download pinned manifest
  if ! manifest=$(curl -fsSL "$manifest_url" 2>/dev/null); then
    echo "❌ ERROR: Failed to download OPA deployment manifest"
    echo "  URL: $manifest_url"
    echo "  Ref: ${OPA_MANIFEST_REF}"
    exit 1
  fi

  echo "✓ Downloaded manifest from: $manifest_url"
  echo "Deploying OPA server (version $OPA_VERSION)..."

  # Apply manifest with namespace and image version substitution
  echo "$manifest" \
    | sed -e "s|namespace: .*|namespace: $NAMESPACE|g" \
      -e "s|openpolicyagent/opa:.*|openpolicyagent/opa:${OPA_VERSION}|g" \
    | kubectl apply -n "$NAMESPACE" -f - >/dev/null 2>&1

  echo "  Waiting for OPA deployment to be ready..."

  # Wait for deployment to appear (may take a moment)
  for i in $(seq 1 12); do
    if kubectl get deployment opa -n "$NAMESPACE" &>/dev/null; then
      break
    fi
    sleep 5
  done

  # Wait for rollout
  if ! kubectl rollout status deployment/opa -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1; then
    echo "❌ ERROR: OPA deployment failed to become ready"
    echo "  Check pod status: kubectl get pods -n $NAMESPACE -l app=opa"
    echo "  Check logs: kubectl logs -n $NAMESPACE -l app=opa"
    exit 1
  fi

  # Get the OPA route
  local opa_route
  opa_route=$(kubectl get route opa -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

  if [ -n "$opa_route" ]; then
    echo "✓ OPA server deployed successfully"
    echo "  Route: http://${opa_route}"
    echo "  Service: http://opa.${NAMESPACE}.svc.cluster.local:8181"
  else
    echo "✓ OPA deployment created (route pending)"
  fi
}

delete_opa_server() {
  echo "Removing OPA server deployment..."

  # Delete all OPA resources
  kubectl delete deployment opa -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete service opa -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete route opa -n "$NAMESPACE" 2>/dev/null || true

  echo "✓ OPA server removed"
}

init_aap_connection() {
  # Initialize AAP API connection credentials
  AAP_ROUTE=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
  if [ -z "$AAP_ROUTE" ]; then
    echo "❌ ERROR: Could not find AAP route"
    exit 1
  fi

  AAP_PASSWORD=$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  if [ -z "$AAP_PASSWORD" ]; then
    echo "❌ ERROR: Could not retrieve AAP admin password"
    exit 1
  fi

  AAP_API="https://${AAP_ROUTE}/api/controller/v2"

  # Test AAP API connectivity
  local api_test
  api_test=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    --connect-timeout 10 \
    "${AAP_API}/ping/" 2>&1)

  if ! echo "$api_test" | grep -q '"version"'; then
    echo "❌ ERROR: Cannot connect to AAP API at ${AAP_API}"
    echo "  Response: $api_test"
    echo "  Ensure AAP is fully deployed and accessible"
    exit 1
  fi
}

create_opa_organization() {
  local org_name="Policy as Code"
  local org_id

  echo "Creating AAP organization: $org_name..." >&2

  # Check if organization already exists
  org_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/organizations/?name=$(jq -rn --arg n "$org_name" '$n|@uri')" 2>/dev/null \
    | jq -r '.results[0].id // empty' 2>/dev/null || echo "")

  if [ -n "$org_id" ]; then
    echo "  Organization already exists (ID: $org_id)" >&2
    printf '%s\n' "$org_id"
    return 0
  fi

  # Create organization
  local org_payload
  org_payload=$(jq -n --arg name "$org_name" \
    '{name: $name, description: "Policy as Code using Open Policy Agent (OPA) for AAP"}')

  local result
  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$org_payload" \
    "${AAP_API}/organizations/" 2>/dev/null)

  org_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$org_id" ]; then
    # If creation failed, try using default organization
    echo "  WARNING: Could not create organization, using Default (ID: 1)" >&2
    printf '1\n'
    return 0
  fi

  echo "✓ Organization created (ID: $org_id)" >&2
  printf '%s\n' "$org_id"
}

create_opa_project() {
  local org_id="$1"
  local project_name="Policy as Code - Playbooks"
  local project_id

  # Validate org_id
  if [ -z "$org_id" ]; then
    echo "❌ ERROR: Organization ID is required to create project" >&2
    return 1
  fi

  echo "Creating AAP project: $project_name..." >&2

  # Check if project already exists
  local encoded_name
  encoded_name=$(jq -rn --arg n "$project_name" '$n|@uri')
  project_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/projects/?name=${encoded_name}" 2>/dev/null \
    | jq -r '.results[0].id // empty' 2>/dev/null || echo "")

  if [ -n "$project_id" ]; then
    echo "  Project already exists (ID: $project_id)" >&2
    printf '%s\n' "$project_id"
    return 0
  fi

  # Create project pointing to aap-demo repository (contains our playbooks)
  local project_payload
  project_payload=$(jq -n \
    --arg name "$project_name" \
    --arg url "$AAP_DEMO_REPO" \
    --arg branch "$AAP_DEMO_BRANCH" \
    --argjson org_id "$org_id" \
    '{
      name: $name,
      description: "AAP Demo repository containing OPA playbooks in addons/opa/playbooks/",
      scm_type: "git",
      scm_url: $url,
      scm_branch: $branch,
      scm_update_on_launch: false,
      organization: $org_id
    }')

  local result
  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$project_payload" \
    "${AAP_API}/projects/" 2>/dev/null)

  project_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$project_id" ]; then
    echo "❌ ERROR: Failed to create project" >&2
    echo "$result" | jq '.' 2>/dev/null || echo "$result" >&2
    return 1
  fi

  echo "✓ Project created (ID: $project_id)" >&2

  # Trigger initial sync
  echo "  Syncing project from GitHub..." >&2
  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST "${AAP_API}/projects/${project_id}/update/" \
    >/dev/null 2>&1 || true

  # Wait for sync to complete
  echo "  Waiting for project sync to complete..." >&2
  local sync_status=""
  for i in $(seq 1 30); do
    sync_status=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/projects/${project_id}/" 2>/dev/null \
      | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

    if [ "$sync_status" = "successful" ]; then
      echo "  ✓ Project sync completed" >&2
      break
    elif [ "$sync_status" = "failed" ]; then
      echo "  ⚠ WARNING: Project sync failed, job templates may not work" >&2
      break
    fi

    sleep 2
  done

  if [ "$sync_status" != "successful" ] && [ "$sync_status" != "failed" ]; then
    echo "  ⚠ WARNING: Project sync status unclear ($sync_status)" >&2
  fi

  printf '%s\n' "$project_id"
}

create_localhost_inventory() {
  local org_id="$1"
  local inv_name="OPA Localhost"
  local inv_id

  # Validate org_id
  if [ -z "$org_id" ]; then
    echo "❌ ERROR: Organization ID is required to create inventory" >&2
    return 1
  fi

  echo "Creating localhost inventory: $inv_name..." >&2

  # Check if inventory already exists
  local encoded_name
  encoded_name=$(jq -rn --arg n "$inv_name" '$n|@uri')
  inv_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/inventories/?name=${encoded_name}" 2>/dev/null \
    | jq -r ".results[] | select(.summary_fields.organization.id == $org_id) | .id // empty" 2>/dev/null | head -1)

  if [ -n "$inv_id" ]; then
    echo "  Inventory already exists (ID: $inv_id)" >&2
    printf '%s\n' "$inv_id"
    return 0
  fi

  # Create inventory
  local inv_payload
  inv_payload=$(jq -n \
    --arg name "$inv_name" \
    --argjson org_id "$org_id" \
    '{name: $name, organization: $org_id}')

  local result
  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$inv_payload" \
    "${AAP_API}/inventories/" 2>/dev/null)

  inv_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$inv_id" ]; then
    echo "❌ ERROR: Failed to create inventory" >&2
    return 1
  fi

  # Add localhost host
  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{"name": "localhost", "variables": "ansible_connection: local"}' \
    "${AAP_API}/inventories/${inv_id}/hosts/" \
    >/dev/null 2>&1 || true

  echo "✓ Inventory created (ID: $inv_id)" >&2
  printf '%s\n' "$inv_id"
}

create_aap_credential() {
  local org_id="$1"
  local credential_name="$2"
  local aap_host="$3"
  local aap_username="$4"
  local aap_password="$5"
  local credential_id

  # Validate parameters
  if [ -z "$org_id" ] || [ -z "$credential_name" ] || [ -z "$aap_host" ] || [ -z "$aap_username" ] || [ -z "$aap_password" ]; then
    echo "❌ ERROR: Missing required parameters for credential creation" >&2
    return 1
  fi

  echo "Creating AAP credential: $credential_name..." >&2

  # Get the credential type ID for "Red Hat Ansible Automation Platform"
  local credential_type_id
  credential_type_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/credential_types/?name=Red%20Hat%20Ansible%20Automation%20Platform" 2>/dev/null \
    | jq -r '.results[0].id // empty' 2>/dev/null || echo "")

  if [ -z "$credential_type_id" ]; then
    echo "❌ ERROR: Could not find credential type 'Red Hat Ansible Automation Platform'" >&2
    return 1
  fi

  # Check if credential already exists
  local encoded_name
  encoded_name=$(jq -rn --arg n "$credential_name" '$n|@uri')
  credential_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/credentials/?name=${encoded_name}" 2>/dev/null \
    | jq -r ".results[] | select(.summary_fields.organization.id == $org_id) | .id // empty" 2>/dev/null | head -1)

  if [ -n "$credential_id" ]; then
    echo "  Credential already exists (ID: $credential_id)" >&2

    # Update existing credential
    local update_payload
    update_payload=$(jq -n \
      --argjson credential_type_id "$credential_type_id" \
      --arg host "$aap_host" \
      --arg username "$aap_username" \
      --arg password "$aap_password" \
      '{
        credential_type: $credential_type_id,
        inputs: {
          host: $host,
          username: $username,
          password: $password,
          verify_ssl: false
        }
      }')

    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X PATCH \
      -H "Content-Type: application/json" \
      -d "$update_payload" \
      "${AAP_API}/credentials/${credential_id}/" \
      >/dev/null 2>&1 || true

    printf '%s\n' "$credential_id"
    return 0
  fi

  # Create new credential
  local credential_payload
  credential_payload=$(jq -n \
    --arg name "$credential_name" \
    --argjson org_id "$org_id" \
    --argjson credential_type_id "$credential_type_id" \
    --arg host "$aap_host" \
    --arg username "$aap_username" \
    --arg password "$aap_password" \
    '{
      name: $name,
      description: "AAP credential for Policy as Code automation (least privilege)",
      organization: $org_id,
      credential_type: $credential_type_id,
      inputs: {
        host: $host,
        username: $username,
        password: $password,
        verify_ssl: false
      }
    }')

  local result
  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$credential_payload" \
    "${AAP_API}/credentials/" 2>/dev/null)

  credential_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$credential_id" ]; then
    echo "❌ ERROR: Failed to create credential" >&2
    echo "$result" | jq '.' 2>/dev/null || echo "$result" >&2
    return 1
  fi

  echo "✓ Credential created (ID: $credential_id)" >&2
  printf '%s\n' "$credential_id"
}

create_policy_demo_survey() {
  local template_id="$1"

  echo "  Adding survey to demo template..." >&2

  # Query GitHub API for policy files at pinned commit (OPA has no policies yet at survey creation time)
  # This keeps the list in sync with OPA_MANIFEST_REF automatically
  local repo_path="${OPA_REPO#https://github.com/}"
  repo_path="${repo_path%.git}"
  local github_api_url="https://api.github.com/repos/${repo_path}/contents/aap_policy_examples?ref=${OPA_MANIFEST_REF}"
  local policy_list
  policy_list=$(curl -fsSL "$github_api_url" 2>/dev/null \
    | jq -r '.[] | select(.name | endswith(".rego")) | .name | sub("\\.rego$"; "")' 2>/dev/null || echo "")

  # Build choices array from GitHub API
  local choices_json="[]"
  if [ -n "$policy_list" ]; then
    choices_json=$(echo "$policy_list" | jq -R -s 'split("\n") | map(select(length > 0))')
    echo "    Found $(echo "$policy_list" | wc -l | tr -d ' ') policies from ${OPA_REPO} @ ${OPA_MANIFEST_REF:0:7}" >&2
  else
    echo "    ⚠ Could not query GitHub API, survey will have REMOVE option only" >&2
    choices_json='[]'
  fi

  # Add "REMOVE" option to allow users to clear the policy from the organization
  choices_json=$(echo "$choices_json" | jq '. + ["REMOVE"]')

  # Create survey specification with dynamic choices
  local survey_spec
  survey_spec=$(jq -n \
    --argjson choices "$choices_json" \
    '{
      "name": "Policy Demo Survey",
      "description": "Select a policy to demonstrate (dynamically populated from OPA)",
      "spec": [
        {
          "question_name": "Policy to Demonstrate",
          "question_description": "Choose which OPA policy you want to test",
          "required": true,
          "type": "multiplechoice",
          "variable": "policy_name",
          "min": null,
          "max": null,
          "default": "",
          "choices": $choices,
          "new_question": true
        },
    {
      "question_name": "Target Organization",
      "question_description": "Organization to test policy against (restricted to allowlist for safety)",
      "required": false,
      "type": "text",
      "variable": "organization_name",
      "min": null,
      "max": 100,
      "default": "Policy as Code",
      "choices": "",
      "new_question": true
        }
      ]
    }')

  # Enable survey on the template (disable extra vars prompt)
  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    -d '{"survey_enabled": true, "ask_variables_on_launch": false}' \
    "${AAP_API}/job_templates/${template_id}/" \
    >/dev/null 2>&1

  # Add the survey spec
  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$survey_spec" \
    "${AAP_API}/job_templates/${template_id}/survey_spec/" \
    >/dev/null 2>&1

  echo "    ✓ Survey added with policy selection" >&2
}

create_job_template() {
  local name="$1"
  local description="$2"
  local playbook="$3"
  local project_id="$4"
  local inventory_id="$5"
  local org_id="$6"
  local extra_vars="${7:-}"
  local credential_ids="${8:-}"  # Space-separated credential IDs

  # Validate required IDs
  if [ -z "$project_id" ] || [ -z "$inventory_id" ] || [ -z "$org_id" ]; then
    echo "❌ ERROR: Missing required IDs for job template '$name'" >&2
    echo "  project_id=$project_id, inventory_id=$inventory_id, org_id=$org_id" >&2
    return 1
  fi

  local template_id

  # Check if template already exists
  local encoded_name
  encoded_name=$(jq -rn --arg n "$name" '$n|@uri')
  template_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/job_templates/?name=${encoded_name}" 2>/dev/null \
    | jq -r ".results[] | select(.summary_fields.organization.id == $org_id) | .id // empty" 2>/dev/null | head -1)

  if [ -n "$template_id" ]; then
    echo "  Job template already exists: $name (ID: $template_id)" >&2

    # Update existing template
    local update_payload
    update_payload=$(jq -n \
      --arg desc "$description" \
      --arg playbook "$playbook" \
      --argjson project_id "$project_id" \
      --argjson inventory_id "$inventory_id" \
      --arg extra_vars "$extra_vars" \
      '{
        description: $desc,
        playbook: $playbook,
        project: $project_id,
        inventory: $inventory_id,
        extra_vars: $extra_vars
      }')

    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X PATCH \
      -H "Content-Type: application/json" \
      -d "$update_payload" \
      "${AAP_API}/job_templates/${template_id}/" \
      >/dev/null 2>&1 || true

    # Attach credentials if provided
    if [ -n "$credential_ids" ]; then
      echo "  Attaching credentials to template..." >&2
      for credential_id in $credential_ids; do
        curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
          -X POST \
          -H "Content-Type: application/json" \
          -d "{\"id\": $credential_id}" \
          "${AAP_API}/job_templates/${template_id}/credentials/" \
          >/dev/null 2>&1 || true
      done
      echo "  ✓ Credentials attached" >&2
    fi

    printf '%s\n' "$template_id"
    return 0
  fi

  # Create new job template
  local template_payload
  template_payload=$(jq -n \
    --arg name "$name" \
    --arg desc "$description" \
    --arg playbook "$playbook" \
    --argjson project_id "$project_id" \
    --argjson inventory_id "$inventory_id" \
    --argjson org_id "$org_id" \
    --arg extra_vars "$extra_vars" \
    '{
      name: $name,
      description: $desc,
      job_type: "run",
      inventory: $inventory_id,
      project: $project_id,
      playbook: $playbook,
      organization: $org_id,
      extra_vars: $extra_vars,
      ask_variables_on_launch: false
    }')

  local result
  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$template_payload" \
    "${AAP_API}/job_templates/" 2>/dev/null)

  template_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$template_id" ]; then
    echo "❌ ERROR: Failed to create job template: $name" >&2
    echo "$result" | jq '.' 2>/dev/null || echo "$result" >&2
    return 1
  fi

  echo "✓ Job template created: $name (ID: $template_id)" >&2

  # Attach credentials if provided
  if [ -n "$credential_ids" ]; then
    echo "  Attaching credentials to template..." >&2
    for credential_id in $credential_ids; do
      curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"id\": $credential_id}" \
        "${AAP_API}/job_templates/${template_id}/credentials/" \
        >/dev/null 2>&1 || true
    done
    echo "  ✓ Credentials attached" >&2
  fi

  printf '%s\n' "$template_id"
}

create_job_templates() {
  echo "Creating OPA policy management job templates..."

  # Initialize AAP connection
  init_aap_connection

  # Create or get organization
  local org_id
  org_id=$(create_opa_organization)
  if [ -z "$org_id" ]; then
    echo "❌ ERROR: Failed to create or find organization"
    return 1
  fi
  echo "  Organization ID: $org_id"

  # Create project
  local project_id
  project_id=$(create_opa_project "$org_id")
  if [ -z "$project_id" ]; then
    echo "❌ ERROR: Failed to create or find project"
    return 1
  fi
  echo "  Project ID: $project_id"

  # Create inventory
  local inventory_id
  inventory_id=$(create_localhost_inventory "$org_id")
  if [ -z "$inventory_id" ]; then
    echo "❌ ERROR: Failed to create or find inventory"
    return 1
  fi
  echo "  Inventory ID: $inventory_id"

  # Create AAP credential for demo template (least privilege)
  local aap_route
  aap_route=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
  local credential_id
  credential_id=$(create_aap_credential \
    "$org_id" \
    "Policy as Code - AAP Credential" \
    "https://${aap_route}" \
    "${AAP_USERNAME}" \
    "${AAP_PASSWORD}")
  if [ -z "$credential_id" ]; then
    echo "❌ ERROR: Failed to create AAP credential"
    return 1
  fi
  echo "  Credential ID: $credential_id"

  # Define extra vars with OPA server URL and pinned policy reference
  local opa_server_url="http://opa.${NAMESPACE}.svc.cluster.local:8181"
  local extra_vars
  extra_vars=$(jq -n \
    --arg opa_url "$opa_server_url" \
    --arg namespace "$NAMESPACE" \
    --arg opa_ref "$OPA_MANIFEST_REF" \
    '{opa_server: $opa_url, namespace: $namespace, opa_branch: $opa_ref}' | jq -c '.')

  # Template 1: Load Example Policies
  create_job_template \
    "OPA | Load Example Policies" \
    "Load OPA example policies from ${OPA_REPO}" \
    "addons/opa/playbooks/load-policies.yml" \
    "$project_id" \
    "$inventory_id" \
    "$org_id" \
    "$extra_vars"

  # Template 2: Test Policies
  create_job_template \
    "OPA | Test Policies" \
    "List loaded policies in OPA server" \
    "addons/opa/playbooks/test-policies.yml" \
    "$project_id" \
    "$inventory_id" \
    "$org_id" \
    "$extra_vars"

  # Template 3: Clear Policies
  create_job_template \
    "OPA | Clear Policies" \
    "Remove all loaded OPA policies" \
    "addons/opa/playbooks/clear-policies.yml" \
    "$project_id" \
    "$inventory_id" \
    "$org_id" \
    "$extra_vars"

  # Template 4: Demo Policy Enforcement (uses AAP credential for authentication)
  local demo_extra_vars
  demo_extra_vars=$(jq -n \
    --arg opa_url "$opa_server_url" \
    --arg namespace "$NAMESPACE" \
    '{opa_server: $opa_url, namespace: $namespace}' | jq -c '.')

  local demo_template_id
  demo_template_id=$(create_job_template \
    "OPA | Demo Policy" \
    "Demonstrate OPA policy enforcement with interactive examples" \
    "addons/opa/playbooks/demo-policy.yml" \
    "$project_id" \
    "$inventory_id" \
    "$org_id" \
    "$demo_extra_vars" \
    "$credential_id")

  # Add survey to demo template
  if [ -n "$demo_template_id" ]; then
    create_policy_demo_survey "$demo_template_id"
  fi

  echo ""
  echo "✓ Job templates created successfully"
}

delete_aap_resources() {
  echo "Removing Policy as Code organization and all resources from AAP..."

  init_aap_connection

  # Find the organization
  local org_name="Policy as Code"
  local org_id
  org_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/organizations/?name=$(jq -rn --arg n "$org_name" '$n|@uri')" 2>/dev/null \
    | jq -r '.results[0].id // empty' 2>/dev/null || echo "")

  if [ -z "$org_id" ]; then
    echo "  No organization found: $org_name"
    echo "✓ Nothing to clean up in AAP"
    return 0
  fi

  echo "  Found organization: $org_name (ID: $org_id)"

  # Delete job templates first
  echo "  Deleting job templates..."
  local template_ids template_count=0
  template_ids=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/organizations/${org_id}/job_templates/" 2>/dev/null \
    | jq -r '.results[].id' 2>/dev/null || echo "")

  for template_id in $template_ids; do
    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X DELETE "${AAP_API}/job_templates/${template_id}/" \
      >/dev/null 2>&1 && ((template_count++)) || true
  done
  [ "$template_count" -gt 0 ] && echo "    ✓ Deleted $template_count job template(s)"

  # Delete projects
  echo "  Deleting projects..."
  local project_ids project_count=0
  project_ids=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/organizations/${org_id}/projects/" 2>/dev/null \
    | jq -r '.results[].id' 2>/dev/null || echo "")

  for project_id in $project_ids; do
    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X DELETE "${AAP_API}/projects/${project_id}/" \
      >/dev/null 2>&1 && ((project_count++)) || true
  done
  [ "$project_count" -gt 0 ] && echo "    ✓ Deleted $project_count project(s)"

  # Delete inventories
  echo "  Deleting inventories..."
  local inventory_ids inventory_count=0
  inventory_ids=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/organizations/${org_id}/inventories/" 2>/dev/null \
    | jq -r '.results[].id' 2>/dev/null || echo "")

  for inventory_id in $inventory_ids; do
    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X DELETE "${AAP_API}/inventories/${inventory_id}/" \
      >/dev/null 2>&1 && ((inventory_count++)) || true
  done
  [ "$inventory_count" -gt 0 ] && echo "    ✓ Deleted $inventory_count inventor(y|ies)"

  # Delete credentials
  echo "  Deleting credentials..."
  local credential_ids credential_count=0
  credential_ids=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/organizations/${org_id}/credentials/" 2>/dev/null \
    | jq -r '.results[].id' 2>/dev/null || echo "")

  for credential_id in $credential_ids; do
    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X DELETE "${AAP_API}/credentials/${credential_id}/" \
      >/dev/null 2>&1 && ((credential_count++)) || true
  done
  [ "$credential_count" -gt 0 ] && echo "    ✓ Deleted $credential_count credential(s)"

  # Now delete the organization itself
  echo "  Deleting organization..."
  local delete_result
  delete_result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X DELETE \
    -w "%{http_code}" \
    -o /dev/null \
    "${AAP_API}/organizations/${org_id}/" 2>/dev/null)

  if [ "$delete_result" = "204" ] || [ "$delete_result" = "202" ]; then
    echo "    ✓ Deleted organization: $org_name"
  else
    echo "    ⚠ Failed to delete organization (HTTP $delete_result)"
    echo "    Organization may need manual deletion via AAP UI"
  fi

  echo "✓ AAP resources cleanup completed"
}

configure_opa_settings() {
  echo "Configuring OPA server connection in AAP Settings..."

  # Initialize AAP connection
  init_aap_connection

  # OPA server configuration
  local opa_host="opa.${NAMESPACE}.svc.cluster.local"
  local opa_port=8181
  local settings_api="${AAP_API}/settings/policyascode/"

  # Build settings payload
  local settings_payload
  settings_payload=$(jq -n \
    --arg host "$opa_host" \
    --argjson port "$opa_port" \
    '{
      OPA_HOST: $host,
      OPA_PORT: $port,
      OPA_SSL: false,
      OPA_AUTH_TYPE: "None",
      OPA_AUTH_TOKEN: "",
      OPA_AUTH_CLIENT_CERT: "",
      OPA_AUTH_CLIENT_KEY: "",
      OPA_AUTH_CA_CERT: "",
      OPA_AUTH_CUSTOM_HEADERS: {},
      OPA_REQUEST_TIMEOUT: 1.5,
      OPA_REQUEST_RETRIES: 2
    }')

  # Apply settings using PATCH (update only specified fields)
  local result
  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    -d "$settings_payload" \
    "$settings_api" 2>/dev/null)

  # Check if configuration was successful
  local configured_host
  configured_host=$(echo "$result" | jq -r '.OPA_HOST // empty' 2>/dev/null)

  if [ "$configured_host" = "$opa_host" ]; then
    echo "✓ OPA server configured in AAP Settings"
    echo "  Host: ${opa_host}:${opa_port}"
    echo "  SSL: Disabled"
    echo "  Auth: None"
  else
    echo "❌ WARNING: Failed to configure OPA settings via API"
    echo "  You may need to configure manually via AAP UI (Settings → Policy)"
    echo "  Response: $(echo "$result" | jq -c '.' 2>/dev/null || echo "$result")"
  fi
}

clear_opa_settings() {
  echo "Clearing OPA server configuration from AAP Settings..."

  init_aap_connection

  # Clear OPA settings by setting host to empty string
  local settings_payload='{"OPA_HOST": ""}'
  local settings_api="${AAP_API}/settings/policyascode/"

  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    -d "$settings_payload" \
    "$settings_api" >/dev/null 2>&1 || true

  echo "✓ OPA settings cleared"
}

print_post_deploy_instructions() {
  local opa_route
  opa_route=$(kubectl get route opa -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "opa-${NAMESPACE}.apps-crc.testing")
  local opa_service="http://opa.${NAMESPACE}.svc.cluster.local:8181"

  echo ""
  echo "══════════════════════════════════════════════════════════════════════════════"
  echo "✓ OPA addon enabled successfully"
  echo "══════════════════════════════════════════════════════════════════════════════"
  echo ""
  echo "OPA is now configured and ready to use!"
  echo ""
  echo "Getting Started:"
  echo ""
  echo "1. Load example policies:"
  echo "   • AAP UI → Resources → Templates"
  echo "   • Run: 'OPA | Load Example Policies'"
  echo "   • Loads 12 example policies from: ${OPA_REPO}"
  echo ""
  echo "2. Demonstrate policy enforcement:"
  echo "   • Run: 'OPA | Demo Policy'"
  echo "   • Select a policy from the survey (dynamically populated from OPA)"
  echo "   • The selected policy will be attached to the 'Policy as Code' organization"
  echo "   • All resources in that organization will be subject to policy enforcement"
  echo "   • Select 'REMOVE' to clear the policy from the organization"
  echo ""
  echo "3. Test policies:"
  echo "   • Run: 'OPA | Test Policies' to list currently loaded policies"
  echo "   • Run: 'OPA | Clear Policies' to remove all policies and reset OPA"
  echo ""
  echo "OPA Server Endpoints:"
  echo "   • External route: http://${opa_route}"
  echo "   • Internal service: ${opa_service}"
  echo "   • Health check: ${opa_service}/health"
  echo ""
  echo "Job Templates Created:"
  echo "   • OPA | Load Example Policies - Load 12 policies from upstream"
  echo "   • OPA | Demo Policy - Interactive policy demonstration with survey"
  echo "   • OPA | Test Policies - List loaded policies"
  echo "   • OPA | Clear Policies - Remove all policies"
  echo ""
  echo "Policy Examples Documentation:"
  echo "   • ${OPA_REPO}"
  echo "   • Policy examples in: aap_policy_examples/"
  echo "   • Tests in: test_aap_policy_examples/"
  echo ""
  echo "══════════════════════════════════════════════════════════════════════════════"
}

# ── Main Execution ────────────────────────────────────────────────────────────

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Disabling OPA addon..."
  echo ""

  clear_opa_settings
  delete_aap_resources
  delete_opa_server

  echo ""
  echo "✓ OPA addon disabled successfully"
  exit 0
fi

# Deploy action
echo "Enabling OPA addon..."
echo ""

check_prerequisites
deploy_opa_server
create_job_templates
configure_opa_settings
print_post_deploy_instructions

exit 0
