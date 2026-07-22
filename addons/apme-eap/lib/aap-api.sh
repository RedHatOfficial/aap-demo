#!/usr/bin/env bash
# AAP REST API helper functions for APME deployment
# Replaces venv-based ansible-playbook execution with AAP controller API calls

set -euo pipefail

# ---------------------------------------------------------------------------
# AAP API Configuration
# ---------------------------------------------------------------------------

get_aap_config() {
  local route_host
  # Try specific route names first, then fall back to any route in namespace
  route_host=$(kubectl get route -n aap-operator -o jsonpath='{.items[?(@.metadata.name=="aap-controller")].spec.host}' 2>/dev/null || echo "")

  if [ -z "$route_host" ]; then
    route_host=$(kubectl get route -n aap-operator -o jsonpath='{.items[?(@.metadata.name=="aap")].spec.host}' 2>/dev/null || echo "")
  fi

  if [ -z "$route_host" ]; then
    route_host=$(kubectl get route -n aap-operator -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  fi

  if [ -z "$route_host" ]; then
    error "AAP controller route not found. Is AAP deployed?"
    return 1
  fi

  # Try to get API token from secret (created manually via Web UI)
  local api_token
  api_token=$(kubectl get secret aap-api-token -n aap-operator -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")

  if [ -z "$api_token" ]; then
    error "AAP API token not found."
    error ""
    error "The APME addon requires an OAuth2 token to access AAP's REST API."
    error "Please create a token using the AAP Web UI:"
    error ""
    error "  1. Open AAP: https://$route_host"
    error "  2. Log in as admin"
    error "  3. Go to: Settings → Users → admin → Tokens"
    error "  4. Create token with 'Write' scope"
    error "  5. Run: kubectl create secret generic aap-api-token -n aap-operator --from-literal=token='YOUR_TOKEN'"
    error ""
    error "For detailed instructions, see:"
    error "  ${SCRIPT_DIR}/docs/aap-api-token-setup.md"
    return 1
  fi

  AAP_URL="https://$route_host"
  AAP_TOKEN="$api_token"

  export AAP_URL AAP_TOKEN

  info "AAP controller: $AAP_URL"
  info "Using OAuth2 token for authentication"
}

# ---------------------------------------------------------------------------
# API Request Wrapper
# ---------------------------------------------------------------------------

aap_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  # Use gateway-based API path: /api/controller/v2/
  local url="${AAP_URL}/api/controller/v2/${endpoint}"
  local args=(
    -X "$method"
    -H "Authorization: Bearer ${AAP_TOKEN}"
    -H "Content-Type: application/json"
    --insecure
    --silent
    --show-error
  )

  if [ -n "$data" ]; then
    args+=(-d "$data")
  fi

  local response
  response=$(curl "${args[@]}" "$url" 2>&1)
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    echo "$response" >&2
    return $exit_code
  fi

  # Check for authentication errors
  if echo "$response" | grep -q "Authentication credentials were not provided"; then
    error "Authentication failed. Token may be invalid or expired."
    error "Recreate token and update secret: kubectl create secret generic aap-api-token -n aap-operator --from-literal=token='YOUR_TOKEN' --dry-run=client -o yaml | kubectl apply -f -"
    return 1
  fi

  echo "$response"
}

# ---------------------------------------------------------------------------
# Resource Creation/Update
# ---------------------------------------------------------------------------

ensure_organization() {
  info "Ensuring organization exists..."

  local org_name="Default"
  local existing
  existing=$(aap_api GET "organizations/?name=${org_name}" | jq -r '.results[0].id // empty')

  if [ -n "$existing" ]; then
    info "Organization '$org_name' exists (ID: $existing)"
    echo "$existing"
    return 0
  fi

  error "Default organization not found"
  return 1
}

ensure_project() {
  local org_id="$1"
  local project_name="aap-demo-apme"

  info "Ensuring project '$project_name' exists..."

  # Check if project exists
  local existing
  existing=$(aap_api GET "projects/?name=${project_name}" | jq -r '.results[0].id // empty')

  if [ -n "$existing" ]; then
    info "Project '$project_name' exists (ID: $existing)"
    echo "$existing"
    return 0
  fi

  # For AAP to find the playbooks, we need to copy them into AAP's project path
  # AAP expects projects in /var/lib/awx/projects/ on the controller pod
  info "Creating project '$project_name' (manual type)..."

  # First, copy playbooks to AAP controller
  local controller_pod
  controller_pod=$(kubectl get pods -n aap-operator -l app.kubernetes.io/name=controller -o jsonpath='{.items[0].metadata.name}')

  if [ -z "$controller_pod" ]; then
    error "AAP controller pod not found"
    return 1
  fi

  info "Copying playbooks to AAP controller pod..."
  kubectl exec -n aap-operator "$controller_pod" -- mkdir -p /var/lib/awx/projects/aap-demo-apme 2>/dev/null || true
  kubectl cp "${SCRIPT_DIR}" "aap-operator/${controller_pod}:/var/lib/awx/projects/aap-demo-apme" 2>/dev/null

  # Create project pointing to the copied files
  local project_data
  project_data=$(cat <<EOF
{
  "name": "${project_name}",
  "description": "APME deployment playbooks from aap-demo repository",
  "organization": ${org_id},
  "scm_type": "",
  "local_path": "aap-demo-apme"
}
EOF
)

  local result
  result=$(aap_api POST "projects/" "$project_data")
  local project_id
  project_id=$(echo "$result" | jq -r '.id')

  info "Project created (ID: $project_id)"
  echo "$project_id"
}

ensure_inventory() {
  local org_id="$1"
  local inventory_name="localhost"

  info "Ensuring inventory '$inventory_name' exists..."

  # Check if inventory exists
  local existing
  existing=$(aap_api GET "inventories/?name=${inventory_name}" | jq -r '.results[0].id // empty')

  if [ -n "$existing" ]; then
    info "Inventory '$inventory_name' exists (ID: $existing)"
    echo "$existing"
    return 0
  fi

  # Create inventory
  info "Creating inventory '$inventory_name'..."
  local inventory_data
  inventory_data=$(cat <<EOF
{
  "name": "${inventory_name}",
  "description": "Localhost inventory for APME deployment",
  "organization": ${org_id}
}
EOF
)

  local result
  result=$(aap_api POST "inventories/" "$inventory_data")
  local inventory_id
  inventory_id=$(echo "$result" | jq -r '.id')

  # Add localhost host
  info "Adding localhost to inventory..."
  local host_data
  host_data=$(cat <<EOF
{
  "name": "localhost",
  "inventory": ${inventory_id},
  "variables": "ansible_connection: local"
}
EOF
)

  aap_api POST "hosts/" "$host_data" >/dev/null

  info "Inventory created (ID: $inventory_id)"
  echo "$inventory_id"
}

ensure_credential() {
  local org_id="$1"
  local credential_name="kubeconfig-credential"

  info "Ensuring kubeconfig credential exists..."

  # Check if credential exists
  local existing
  existing=$(aap_api GET "credentials/?name=${credential_name}" | jq -r '.results[0].id // empty')

  if [ -n "$existing" ]; then
    info "Credential '$credential_name' exists (ID: $existing)"
    echo "$existing"
    return 0
  fi

  # Get kubeconfig content
  local kubeconfig_path="${HOME}/.crc/machines/crc/kubeconfig"
  if [ ! -f "$kubeconfig_path" ]; then
    warn "KUBECONFIG not found at $kubeconfig_path, credential creation skipped"
    echo ""
    return 0
  fi

  local kubeconfig_content
  kubeconfig_content=$(cat "$kubeconfig_path" | jq -Rs .)

  # Create credential
  info "Creating kubeconfig credential..."
  local credential_data
  credential_data=$(cat <<EOF
{
  "name": "${credential_name}",
  "description": "Kubeconfig for CRC/MicroShift cluster",
  "organization": ${org_id},
  "credential_type": 1,
  "inputs": {
    "kubeconfig": ${kubeconfig_content}
  }
}
EOF
)

  local result
  result=$(aap_api POST "credentials/" "$credential_data")
  local credential_id
  credential_id=$(echo "$result" | jq -r '.id')

  info "Credential created (ID: $credential_id)"
  echo "$credential_id"
}

ensure_job_template() {
  local org_id="$1"
  local project_id="$2"
  local inventory_id="$3"
  local template_name="Deploy APME"

  info "Ensuring job template '$template_name' exists..."

  # Check if template exists
  local existing
  existing=$(aap_api GET "job_templates/?name=${template_name}" | jq -r '.results[0].id // empty')

  if [ -n "$existing" ]; then
    info "Job template '$template_name' exists (ID: $existing), updating..."

    # Update template
    local update_data
    update_data=$(cat <<EOF
{
  "name": "${template_name}",
  "description": "Deploy APME portal using official playbooks",
  "job_type": "run",
  "inventory": ${inventory_id},
  "project": ${project_id},
  "playbook": "playbooks/deploy_apme_portal.yml",
  "ask_variables_on_launch": true
}
EOF
)

    aap_api PATCH "job_templates/${existing}/" "$update_data" >/dev/null
    echo "$existing"
    return 0
  fi

  # Create template
  info "Creating job template '$template_name'..."
  local template_data
  template_data=$(cat <<EOF
{
  "name": "${template_name}",
  "description": "Deploy APME portal using official playbooks",
  "job_type": "run",
  "inventory": ${inventory_id},
  "project": ${project_id},
  "playbook": "playbooks/deploy_apme_portal.yml",
  "ask_variables_on_launch": true,
  "verbosity": 1
}
EOF
)

  local result
  result=$(aap_api POST "job_templates/" "$template_data")
  local template_id
  template_id=$(echo "$result" | jq -r '.id')

  info "Job template created (ID: $template_id)"
  echo "$template_id"
}

# ---------------------------------------------------------------------------
# Job Execution
# ---------------------------------------------------------------------------

launch_job() {
  local template_id="$1"
  local vars_file="$2"

  info "Launching job template (ID: $template_id)..."

  # Read vars file and convert to JSON
  local extra_vars
  extra_vars=$(python3 -c "import yaml, json, sys; print(json.dumps(yaml.safe_load(open('$vars_file'))))")

  local launch_data
  launch_data=$(cat <<EOF
{
  "extra_vars": $extra_vars
}
EOF
)

  local result
  result=$(aap_api POST "job_templates/${template_id}/launch/" "$launch_data")
  local job_id
  job_id=$(echo "$result" | jq -r '.id')

  info "Job launched (ID: $job_id)"
  echo "$job_id"
}

wait_for_job() {
  local job_id="$1"

  info "Waiting for job $job_id to complete..."

  local status=""
  local count=0
  local max_wait=600  # 10 minutes

  while [ "$status" != "successful" ] && [ "$status" != "failed" ] && [ $count -lt $max_wait ]; do
    sleep 5
    count=$((count + 5))

    local job_data
    job_data=$(aap_api GET "jobs/${job_id}/")
    status=$(echo "$job_data" | jq -r '.status')

    if [ "$status" = "pending" ] || [ "$status" = "waiting" ] || [ "$status" = "running" ]; then
      echo -n "."
    fi
  done

  echo ""

  if [ "$status" = "successful" ]; then
    info "Job completed successfully!"
    return 0
  elif [ "$status" = "failed" ]; then
    error "Job failed!"
    return 1
  else
    error "Job timed out after ${max_wait}s (status: $status)"
    return 1
  fi
}

stream_job_output() {
  local job_id="$1"

  info "Streaming job output..."
  info "View in AAP UI: ${AAP_URL}/#/jobs/playbook/${job_id}/output"

  # Get job events
  local events
  events=$(aap_api GET "jobs/${job_id}/job_events/?order_by=counter")

  echo "$events" | jq -r '.results[] | select(.stdout != "") | .stdout' || true
}
