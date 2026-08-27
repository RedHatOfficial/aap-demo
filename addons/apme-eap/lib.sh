#!/usr/bin/env bash
# Shared helpers for apme-eap AAP-native deployment.

apme_default_org_id() {
  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/organizations/?name=Default" 2>&1 \
    | jq -r '.results[0].id // empty'
}

apme_configure_microshift_job_networking() {
  if [ "${IS_MICROSHIFT:-false}" != true ]; then
    return 0
  fi

  echo "Configuring MicroShift job pod networking..."

  local aap_ip ig_id pod_spec_override
  aap_ip=$(kubectl get svc aap -n "$AAP_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
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

  local patch_http patch_body
  patch_body=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg spec "$pod_spec_override" '{pod_spec_override: $spec}')" \
    -w "\n%{http_code}" \
    "${AAP_API}/instance_groups/${ig_id}/" 2>/dev/null || echo "000")

  patch_http=$(echo "$patch_body" | tail -1)
  if [ "$patch_http" != "200" ]; then
    echo "  ⚠ Failed to configure job pod hostAlias (HTTP ${patch_http})"
    return 1
  fi

  echo "  ✓ Job pod hostAlias configured: ${AAP_ROUTE} → ${aap_ip}"
  return 0
}

apme_init_aap_connection() {
  AAP_NAMESPACE="${AAP_NAMESPACE:-aap-operator}"
  local aap_route

  aap_route=$(kubectl get route aap -n "$AAP_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [ -z "$aap_route" ]; then
    aap_route=$(kubectl get route -n "$AAP_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  fi
  if [ -z "$aap_route" ]; then
    echo "❌ ERROR: Cannot find AAP route"
    return 1
  fi

  AAP_ROUTE="$aap_route"
  AAP_UI_URL="https://${aap_route}"
  AAP_API="${AAP_UI_URL}/api/controller/v2"
  AAP_USERNAME="${AAP_USERNAME:-admin}"
  AAP_PASSWORD=$(kubectl get secret aap-admin-password -n "$AAP_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
  if [ -z "$AAP_PASSWORD" ]; then
    echo "❌ ERROR: Cannot retrieve AAP admin password"
    return 1
  fi

  if [ -z "$(kubectl get ingresses.config/cluster -o jsonpath='{.spec.domain}' --request-timeout=5s 2>/dev/null || true)" ]; then
    IS_MICROSHIFT=true
    AAP_JOB_HOSTNAME="http://${aap_route}"
  else
    IS_MICROSHIFT=false
    AAP_JOB_HOSTNAME="${AAP_UI_URL}"
  fi

  export AAP_ROUTE AAP_UI_URL AAP_API AAP_USERNAME AAP_PASSWORD AAP_NAMESPACE IS_MICROSHIFT AAP_JOB_HOSTNAME
}

apme_create_openshift_deploy_token() {
  local ns="${AAP_NAMESPACE:-aap-operator}"
  local sa="apme-deployer"
  local binding="apme-deployer-admin"

  kubectl get serviceaccount "$sa" -n "$ns" &>/dev/null \
    || kubectl create serviceaccount "$sa" -n "$ns" &>/dev/null

  kubectl get clusterrolebinding "$binding" &>/dev/null \
    || kubectl create clusterrolebinding "$binding" \
      --clusterrole=cluster-admin \
      --serviceaccount="${ns}:${sa}" &>/dev/null

  kubectl create token "$sa" -n "$ns" --duration=87600h
}

apme_find_controller_task_pod() {
  local pod selector
  for selector in \
    'app.kubernetes.io/name=aap-controller-task' \
    'app.kubernetes.io/component=task' \
    'app.kubernetes.io/name=controller-task'; do
    pod=$(kubectl get pods -n "$AAP_NAMESPACE" -l "$selector" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$pod" ]; then
      printf '%s\n' "$pod"
      return 0
    fi
  done

  pod=$(kubectl get pods -n "$AAP_NAMESPACE" --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E 'controller.*task|aap-controller-task' | head -1 || true)
  if [ -n "$pod" ]; then
    printf '%s\n' "$pod"
    return 0
  fi

  return 1
}

apme_overlay_project_playbooks() {
  local project_id="$1"
  local playbooks_src="$2"

  if [ ! -d "$playbooks_src" ]; then
    echo "  ⚠ Playbooks overlay source not found: ${playbooks_src}" >&2
    return 1
  fi

  echo "Overlaying local apme-eap addon into AAP project (uncommitted dev changes)..." >&2

  local project_dir task_pod
  task_pod=$(apme_find_controller_task_pod || true)
  if [ -z "$task_pod" ]; then
    echo "  ⚠ Could not find controller task pod; skipping playbook overlay" >&2
    return 1
  fi

  project_dir=$(kubectl exec -n "$AAP_NAMESPACE" "$task_pod" -- awx-manage shell -c "
from awx.main.models import Project
print(Project.objects.get(id=${project_id}).get_project_path())
" 2>/dev/null | tail -1)

  if [ -z "$project_dir" ]; then
    echo "  ⚠ Could not resolve project path on controller" >&2
    return 1
  fi

  local dest="${project_dir}/addons/apme-eap"
  kubectl exec -n "$AAP_NAMESPACE" "$task_pod" -- mkdir -p "$dest" 2>/dev/null || true

  if tar cf - -C "${playbooks_src}" . | kubectl exec -i -n "$AAP_NAMESPACE" "$task_pod" -- \
    env DEST="$dest" python3 -c '
import os, sys, tarfile, io
dest = os.environ["DEST"]
os.makedirs(dest, exist_ok=True)
with tarfile.open(fileobj=io.BufferedReader(sys.stdin.buffer), mode="r|") as archive:
    archive.extractall(path=dest)
'; then
    echo "  ✓ Addon content overlaid to ${dest}" >&2
    return 0
  fi

  echo "  ⚠ kubectl cp overlay failed" >&2
  return 1
}

apme_register_project_playbooks() {
  local project_id="$1"
  shift

  if [ $# -eq 0 ]; then
    return 0
  fi

  local task_pod names_json register_result
  task_pod=$(apme_find_controller_task_pod || true)
  if [ -z "$task_pod" ]; then
    echo "  ⚠ Could not find controller task pod; cannot register overlay playbooks in AAP" >&2
    return 1
  fi

  names_json=$(printf '%s\n' "$@" | jq -R . | jq -sc .)

  register_result=$(kubectl exec -n "$AAP_NAMESPACE" "$task_pod" -- awx-manage shell -c "
import json
from awx.main.models import Project

names = json.loads('${names_json}')
p = Project.objects.get(pk=${project_id})
files = list(p.playbook_files or [])
added = [name for name in names if name not in files]
if added:
    p.playbook_files = files + added
    p.save(update_fields=['playbook_files'])
print(','.join(added) if added else '')
" 2>/dev/null | tail -1 | tr -d '\r')

  if [ -z "$register_result" ]; then
    echo "  ✓ Overlay playbooks already registered in project catalog" >&2
  else
    echo "  ✓ Registered overlay playbooks in project catalog: ${register_result}" >&2
  fi
}

apme_set_project_update_on_launch() {
  local project_id="$1"
  local enabled="$2"

  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    -d "$(jq -n --argjson enabled "$enabled" '{scm_update_on_launch: $enabled}')" \
    "${AAP_API}/projects/${project_id}/" >/dev/null 2>&1
}

apme_ensure_project() {
  local repo_url="$1"
  local repo_branch="$2"
  local org_id="$3"
  local project_id payload result existing

  payload=$(jq -n \
    --arg name "${APME_PROJECT_NAME}" \
    --arg desc "APME portal deployment playbooks (aap-demo)" \
    --arg url "$repo_url" \
    --arg branch "$repo_branch" \
    --argjson org "$org_id" \
    '{
      name: $name,
      description: $desc,
      scm_type: "git",
      scm_url: $url,
      scm_branch: $branch,
      scm_update_on_launch: true,
      organization: $org
    }')

  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${AAP_API}/projects/" 2>&1)

  project_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$project_id" ]; then
    existing=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/projects/?name=$(jq -rn --arg n "$APME_PROJECT_NAME" '$n|@uri')" 2>&1)
    project_id=$(echo "$existing" | jq -r --argjson org "$org_id" \
      '[.results[] | select(.summary_fields.organization.id == $org)] | .[0].id // empty' 2>/dev/null)

    if [ -z "$project_id" ]; then
      echo "❌ ERROR: Failed to create AAP project" >&2
      echo "$result" | jq '.' 2>/dev/null || echo "$result" >&2
      return 1
    fi

    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X PATCH \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg url "$repo_url" \
        --arg branch "$repo_branch" \
        '{scm_url: $url, scm_branch: $branch, scm_update_on_launch: true}')" \
      "${AAP_API}/projects/${project_id}/" >/dev/null 2>&1
    echo "✓ AAP project already exists (ID: ${project_id})" >&2
  else
    echo "✓ AAP project created (ID: ${project_id})" >&2
  fi

  local task_pod project_dir
  task_pod=$(apme_find_controller_task_pod || true)
  if [ -n "$task_pod" ]; then
    project_dir=$(kubectl exec -n "$AAP_NAMESPACE" "$task_pod" -- awx-manage shell -c "
from awx.main.models import Project
print(Project.objects.get(id=${project_id}).get_project_path())
" 2>/dev/null | tail -1)
    if [ -n "$project_dir" ]; then
      kubectl exec -n "$AAP_NAMESPACE" "$task_pod" -- sh -c \
        "cd '${project_dir}' && git checkout -- addons/apme-eap 2>/dev/null; git clean -fd addons/apme-eap 2>/dev/null" \
        >/dev/null 2>&1 || true
    fi
  fi

  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    "${AAP_API}/projects/${project_id}/update/" >/dev/null 2>&1 || true

  echo "Waiting for project sync..." >&2
  local i status synced=false
  for i in $(seq 1 30); do
    status=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/projects/${project_id}/" 2>&1 | jq -r '.status // "unknown"' 2>/dev/null)
    if [ "$status" = "successful" ]; then
      synced=true
      echo "✓ Project synced successfully" >&2
      break
    elif [ "$status" = "failed" ]; then
      echo "  ⚠ Project sync failed — continuing with local playbook overlay (dev branch may be unpushed)" >&2
      synced=true
      break
    fi
    echo "  Status: ${status} (waiting... ${i}/30)" >&2
    sleep 2
  done

  if [ "$synced" != true ]; then
    echo "❌ ERROR: Project sync did not complete" >&2
    return 1
  fi

  printf '%s\n' "$project_id"
}

apme_ensure_execution_environment() {
  local org_id="$1"
  local ee_id result existing

  existing=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/execution_environments/?name=$(jq -rn --arg n "$APME_EE_NAME" '$n|@uri')" 2>&1)
  ee_id=$(echo "$existing" | jq -r '.results[0].id // empty' 2>/dev/null)

  if [ -n "$ee_id" ]; then
    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X PATCH \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg image "${APME_EE_IMAGE}" '{image: $image, pull: "missing"}')" \
      "${AAP_API}/execution_environments/${ee_id}/" >/dev/null 2>&1
    echo "✓ Execution environment already exists (ID: ${ee_id})" >&2
    printf '%s\n' "$ee_id"
    return 0
  fi

  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg name "${APME_EE_NAME}" \
      --arg image "${APME_EE_IMAGE}" \
      --argjson org "$org_id" \
      '{
        name: $name,
        description: "Official Ansible Product Demos execution environment",
        image: $image,
        pull: "missing",
        organization: $org
      }')" \
    "${AAP_API}/execution_environments/" 2>&1)

  ee_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$ee_id" ]; then
    echo "❌ ERROR: Failed to register execution environment" >&2
    echo "$result" | jq '.' 2>/dev/null || echo "$result" >&2
    return 1
  fi

  echo "✓ Execution environment registered (ID: ${ee_id})" >&2
  printf '%s\n' "$ee_id"
}

apme_build_extra_vars_json() {
  local defaults_file="$1"
  local vars_file="$2"
  local openshift_token="$3"
  python3 - "$defaults_file" "$vars_file" "$openshift_token" <<'PY'
import json
import sys

import yaml

def load_yaml(path):
    with open(path) as handle:
        return yaml.safe_load(handle) or {}

defaults = load_yaml(sys.argv[1])
vars_data = load_yaml(sys.argv[2])
token = sys.argv[3]

merged = {**defaults, **vars_data}
merged.update({
    "openshift_api_url": "https://kubernetes.default.svc:443",
    "openshift_token": token,
    "openshift_validate_certs": False,
    "apme_pah_run_setup_pah": False,
    "ansible_kubernetes_context": None,
})
# Drop host-only private key path when content is provided
if merged.get("github_app_private_key_content"):
    merged.pop("github_app_private_key_path", None)

print(json.dumps(merged))
PY
}

apme_extra_vars_yaml() {
  local extra_vars_json="$1"
  python3 -c 'import json,sys,yaml; print(yaml.dump(json.loads(sys.argv[1]), default_flow_style=False))' "$extra_vars_json"
}

apme_ensure_job_template() {
  local org_id="$1"
  local project_id="$2"
  local ee_id="$3"
  local extra_vars_json="$4"
  local extra_vars_yaml template_id result existing encoded_name patch_result

  extra_vars_yaml=$(apme_extra_vars_yaml "$extra_vars_json")

  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg name "${APME_JOB_TEMPLATE_NAME}" \
      --arg desc "Deploy Ansible Portal with APME (pre-built hub image)" \
      --arg playbook "${APME_DEPLOY_PLAYBOOK}" \
      --arg extra_vars "$extra_vars_yaml" \
      --argjson project_id "$project_id" \
      --argjson ee_id "$ee_id" \
      --argjson org_id "$org_id" \
      '{
        name: $name,
        description: $desc,
        job_type: "run",
        inventory: 1,
        project: $project_id,
        playbook: $playbook,
        ask_variables_on_launch: false,
        organization: $org_id,
        execution_environment: $ee_id,
        extra_vars: $extra_vars
      }')" \
    "${AAP_API}/job_templates/" 2>&1)

  template_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$template_id" ]; then
    encoded_name=$(jq -rn --arg n "$APME_JOB_TEMPLATE_NAME" '$n|@uri')
    existing=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/job_templates/?name=${encoded_name}" 2>&1)
    template_id=$(echo "$existing" | jq -r --argjson org "$org_id" \
      '[.results[] | select(.summary_fields.organization.id == $org)] | .[0].id // empty' 2>/dev/null)

    if [ -z "$template_id" ]; then
      echo "❌ ERROR: Failed to create job template" >&2
      echo "$result" | jq '.' 2>/dev/null || echo "$result" >&2
      return 1
    fi

    patch_result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X PATCH \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --argjson ee_id "$ee_id" \
        --argjson project_id "$project_id" \
        --arg extra_vars "$extra_vars_yaml" \
        '{execution_environment: $ee_id, project: $project_id, extra_vars: $extra_vars, ask_variables_on_launch: false}')" \
      "${AAP_API}/job_templates/${template_id}/" 2>&1)
    if ! echo "$patch_result" | jq -e '.id' >/dev/null 2>&1; then
      echo "❌ ERROR: Failed to update job template extra_vars" >&2
      echo "$patch_result" | jq '.' 2>/dev/null || echo "$patch_result" >&2
      return 1
    fi
    echo "✓ Job template already exists (ID: ${template_id})" >&2
  else
    echo "✓ Job template created (ID: ${template_id})" >&2
  fi

  apme_register_project_playbooks "$project_id" "${APME_DEPLOY_PLAYBOOK}"

  printf '%s\n' "$template_id"
}

apme_launch_job_template() {
  local template_id="$1"
  local launch_result job_id

  launch_result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{}' \
    "${AAP_API}/job_templates/${template_id}/launch/" 2>&1)

  job_id=$(echo "$launch_result" | jq -r '.id // .job // empty' 2>/dev/null)
  if [ -z "$job_id" ]; then
    echo "❌ ERROR: Failed to launch APME deploy job" >&2
    echo "$launch_result" | jq '.' 2>/dev/null || echo "$launch_result" >&2
    return 1
  fi

  echo "✓ APME deploy job launched (ID: ${job_id})" >&2
  echo "View in UI: ${AAP_UI_URL}/#/jobs/playbook/${job_id}/output" >&2
  printf '%s\n' "$job_id"
}

apme_wait_for_portal_route() {
  local route_host="$1"
  local max_wait="${2:-180}"
  local i code

  if [ -z "$route_host" ]; then
    return 1
  fi

  echo "Waiting for portal route to respond (init + Backstage startup may take 2-3 minutes)..." >&2
  for i in $(seq 1 "$max_wait"); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${route_host}/" 2>/dev/null || echo "000")
    if [ "$code" = "200" ]; then
      echo "✓ Portal route is responding (HTTP ${code})" >&2
      return 0
    fi
    if [ "$((i % 15))" -eq 0 ]; then
      echo "  Portal not ready yet (HTTP ${code}) — waiting... (${i}/${max_wait}s)" >&2
    fi
    sleep 1
  done

  echo "⚠ Portal route did not return HTTP 200 within ${max_wait}s" >&2
  echo "  Check: kubectl get pods -n ${NAMESPACE:-apme}" >&2
  return 1
}

apme_ensure_aap_resources() {
  local repo_root repo_url repo_branch org_id project_id ee_id extra_vars_json template_id

  repo_root="$(cd "${SCRIPT_DIR}/../../" && pwd)"
  repo_url=$(git -C "$repo_root" remote get-url origin 2>/dev/null || echo "https://github.com/RedHatOfficial/aap-demo.git")
  repo_branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

  # Normalize git@ URLs to https for AAP SCM
  if [[ "$repo_url" == git@* ]]; then
    repo_url=$(echo "$repo_url" | sed -E 's/^git@([^:]+):(.+)$/https:\/\/\1\/\2/')
  fi

  org_id=$(apme_default_org_id)
  if [ -z "$org_id" ]; then
    echo "❌ ERROR: Cannot resolve Default organization ID"
    return 1
  fi

  echo "Ensuring AAP project (${APME_PROJECT_NAME}) from ${repo_url} (${repo_branch})..." >&2
  project_id=$(apme_ensure_project "$repo_url" "$repo_branch" "$org_id") || return 1

  if apme_overlay_project_playbooks "$project_id" "${SCRIPT_DIR}"; then
    apme_set_project_update_on_launch "$project_id" false
    echo "  ✓ Project scm_update_on_launch disabled (local playbook overlay active)" >&2
  else
    apme_set_project_update_on_launch "$project_id" true
  fi
  apme_register_project_playbooks "$project_id" "${APME_DEPLOY_PLAYBOOK}" || true

  echo "" >&2
  echo "Registering execution environment (${APME_EE_IMAGE})..." >&2
  ee_id=$(apme_ensure_execution_environment "$org_id") || return 1

  extra_vars_json=$(apme_build_extra_vars_json \
    "${SCRIPT_DIR}/defaults.yml" \
    "$VARS_FILE" \
    "$OPENSHIFT_DEPLOY_TOKEN")

  echo "" >&2
  echo "Creating job template (${APME_JOB_TEMPLATE_NAME})..." >&2
  template_id=$(apme_ensure_job_template "$org_id" "$project_id" "$ee_id" "$extra_vars_json") || return 1

  export APME_JOB_TEMPLATE_ID="$template_id"
  return 0
}

apme_monitor_job() {
  local job_id="$1"
  local label="${2:-APME deploy}"
  local max_wait="${3:-120}"

  for i in $(seq 1 "$max_wait"); do
    local job_status status elapsed
    job_status=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/jobs/${job_id}/" 2>&1)

    status=$(echo "$job_status" | jq -r '.status // "unknown"' 2>/dev/null)
    elapsed=$(echo "$job_status" | jq -r '.elapsed // 0' 2>/dev/null)

    if [ "$status" = "successful" ]; then
      echo ""
      echo "✓ ${label} completed successfully (ID: ${job_id})"
      return 0
    elif [ "$status" = "failed" ] || [ "$status" = "error" ]; then
      echo ""
      echo "❌ ERROR: ${label} failed (ID: ${job_id})"
      echo "View job output: ${AAP_UI_URL}/#/jobs/playbook/${job_id}/output"
      if kubectl get deployment aap-controller-web -n "$AAP_NAMESPACE" &>/dev/null; then
        echo ""
        echo "Last failed task(s):"
        kubectl exec -n "$AAP_NAMESPACE" deploy/aap-controller-web -- bash -c "awx-manage shell -c \"
from awx.main.models import Job
j = Job.objects.get(id=${job_id})
for ev in j.job_events.filter(event='runner_on_failed').order_by('-id')[:3]:
    out = (ev.stdout or ev.msg or '').strip()
    if out:
        print(ev.task)
        for line in out.splitlines()[-6:]:
            print('  ', line)
\"" 2>/dev/null || true
      fi
      return 1
    fi

    printf '\r  Status: %s (elapsed: %ss) [%d/%d]' "$status" "$elapsed" "$i" "$max_wait"
    sleep 5
  done

  echo ""
  echo "❌ ERROR: ${label} timed out (ID: ${job_id})"
  return 1
}
