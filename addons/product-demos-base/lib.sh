#!/usr/bin/env bash
# Shared helpers for product-demos addons.

APD_AAP_VERSION="${APD_AAP_VERSION:-2.7}"

apd_common_extra_vars_yaml() {
  local ee_image="${1:-quay.io/ansible-product-demos/apd-ee-26:latest}"
  jq -r -n \
    --arg version "$APD_AAP_VERSION" \
    --arg ee_image "$ee_image" \
    '{
      _aap_version: $version,
      apd_ee_image: $ee_image,
      aap_validate_certs: false,
      aap_configuration_async_retries: 0,
      gateway_configuration_async_retries: 0,
      controller_configuration_async_retries: 0
    } | to_entries | map("\(.key): \(.value)") | join("\n")'
}

apd_domain_template_name() {
  local demo="$1"
  case "$demo" in
    openshift) printf '%s\n' "APD | Install OpenShift Demos" ;;
    *)
      local label="${demo:0:1}"
      label="$(tr '[:lower:]' '[:upper:]' <<<"$label")${demo:1}"
      printf 'APD | Install %s Demos\n' "$label"
      ;;
  esac
}

apd_domain_extra_vars_yaml() {
  local demo="$1"
  local ee_image="${2:-quay.io/ansible-product-demos/apd-ee-26:latest}"
  jq -r -n \
    --arg demo "$demo" \
    --arg version "$APD_AAP_VERSION" \
    --arg ee_image "$ee_image" \
    '{
      demo: $demo,
      _aap_version: $version,
      apd_ee_image: $ee_image,
      aap_validate_certs: false,
      aap_configuration_async_retries: 0,
      gateway_configuration_async_retries: 0,
      controller_configuration_async_retries: 0
    } | to_entries | map("\(.key): \(.value)") | join("\n")'
}

apd_ensure_domain_job_template() {
  local demo="$1"
  local project_id="$2"
  local ee_id="$3"
  local cred_id="$4"

  local template_name extra_vars template_id encoded_name
  template_name=$(apd_domain_template_name "$demo")
  extra_vars=$(apd_domain_extra_vars_yaml "$demo")

  local template_payload template_result
  template_payload=$(jq -n \
    --arg name "$template_name" \
    --arg desc "Install Ansible Product Demos ${demo} domain via setup_demo.yml" \
    --arg extra_vars "$extra_vars" \
    --argjson project_id "$project_id" \
    --argjson ee_id "$ee_id" \
    '{
      name: $name,
      description: $desc,
      job_type: "run",
      inventory: 1,
      project: $project_id,
      playbook: "setup_demo.yml",
      ask_variables_on_launch: false,
      organization: 1,
      execution_environment: $ee_id,
      extra_vars: $extra_vars
    }')

  template_result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$template_payload" \
    "${AAP_API}/job_templates/" 2>&1)

  template_id=$(echo "$template_result" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$template_id" ]; then
    encoded_name=$(jq -rn --arg n "$template_name" '$n|@uri')
    template_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/job_templates/?name=${encoded_name}" 2>&1 | jq -r '.results[0].id // empty' 2>/dev/null)

    if [ -z "$template_id" ]; then
      echo "❌ ERROR: Failed to create job template for ${demo}"
      echo "$template_result" | jq '.' 2>/dev/null || echo "$template_result"
      return 1
    fi

    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X PATCH \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --argjson ee_id "$ee_id" \
        --argjson project_id "$project_id" \
        --arg extra_vars "$extra_vars" \
        '{execution_environment: $ee_id, project: $project_id, extra_vars: $extra_vars, ask_variables_on_launch: false}')" \
      "${AAP_API}/job_templates/${template_id}/" >/dev/null 2>&1
    echo "✓ Job template already exists: ${template_name} (ID: ${template_id})"
  else
    echo "✓ Job template created: ${template_name} (ID: ${template_id})"
  fi

  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"id\": $cred_id}" \
    "${AAP_API}/job_templates/${template_id}/credentials/" >/dev/null 2>&1 || true

  printf '%s\n' "$template_id"
}

apd_launch_extra_vars_json() {
  local demo="${1:-}"
  if [ -n "$demo" ]; then
    jq -n \
      --arg demo "$demo" \
      '{
        demo: $demo,
        aap_validate_certs: false,
        aap_configuration_async_retries: 0,
        gateway_configuration_async_retries: 0,
        controller_configuration_async_retries: 0
      }'
  else
    jq -n '{
      aap_validate_certs: false,
      aap_configuration_async_retries: 0,
      gateway_configuration_async_retries: 0,
      controller_configuration_async_retries: 0
    }'
  fi
}

apd_monitor_job() {
  local job_id="$1"
  local label="${2:-Job}"
  local max_wait="${3:-60}"

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
      if kubectl get deployment aap-controller-web -n "$NAMESPACE" &>/dev/null; then
        echo ""
        echo "Last failed task(s):"
        kubectl exec -n "$NAMESPACE" deploy/aap-controller-web -- bash -c "awx-manage shell -c \"
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

    printf "\r  Status: %-12s | Elapsed: %3ss | Waiting... %2d/%s" "$status" "$elapsed" "$i" "$max_wait"
    sleep 3
  done

  echo ""
  echo "⚠ ${label} is still running after $((max_wait * 3)) seconds"
  echo "View progress: ${AAP_UI_URL}/#/jobs/playbook/${job_id}/output"
  return 2
}

apd_overlay_install_playbook() {
  local project_id="$1"
  local patched_install_src="$2"

  if [ ! -f "$patched_install_src" ]; then
    echo "  ⚠ Patched install playbook not found: ${patched_install_src}"
    return 1
  fi

  echo "Patching synced project install-apd.yml (skip version ping when _aap_version is set)..."

  local project_dir task_pod
  project_dir=$(kubectl exec -n "$NAMESPACE" deploy/aap-controller-web -- awx-manage shell -c "
from awx.main.models import Project
p = Project.objects.get(pk=${project_id})
print(p.project_base_dir)
" 2>/dev/null | tail -1 | tr -d '\r')

  if [ -z "$project_dir" ]; then
    echo "  ⚠ Could not resolve project directory; skipping playbook overlay"
    return 1
  fi

  task_pod=$(kubectl get pods -n "$NAMESPACE" \
    -l app.kubernetes.io/name=aap-controller-task \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -z "$task_pod" ]; then
    echo "  ⚠ Could not find controller task pod; skipping playbook overlay"
    return 1
  fi

  if ! kubectl cp "$patched_install_src" \
    "${NAMESPACE}/${task_pod}:${project_dir}/install-apd.yml" >/dev/null 2>&1; then
    echo "  ⚠ Failed to copy patched install-apd.yml into project directory"
    return 1
  fi

  echo "  ✓ Patched install-apd.yml applied: ${project_dir}/install-apd.yml"
}
