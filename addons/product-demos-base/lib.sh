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

apd_default_org_id() {
  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/organizations/?name=Default" 2>&1 \
    | jq -r '.results[0].id // empty'
}

apd_default_bootstrap_project_id() {
  local org_id="${DEFAULT_ORG_ID:-$(apd_default_org_id)}"
  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/projects/?name=$(jq -rn --arg n "${APD_BOOTSTRAP_PROJECT_NAME:-APD Bootstrap Project}" '$n|@uri')" 2>&1 \
    | jq -r --argjson org "$org_id" \
      '[.results[] | select(.summary_fields.organization.id == $org)] | .[0].id // empty'
}

apd_cleanup_default_org_apd_projects() {
  local org_id="${DEFAULT_ORG_ID:-$(apd_default_org_id)}"
  local project_ids

  project_ids=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/projects/?name=Ansible+Product+Demos" 2>&1 \
    | jq -r --argjson org "$org_id" \
      '[.results[] | select(.summary_fields.organization.id == $org) | .id] | join(" ")')

  for project_id in $project_ids; do
    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X DELETE \
      "${AAP_API}/projects/${project_id}/" >/dev/null 2>&1 || true
    echo "  ✓ Removed duplicate Default org project (ID: ${project_id})" >&2
  done
}

apd_cleanup_legacy_install_templates() {
  local org_id="${DEFAULT_ORG_ID:-$(apd_default_org_id)}"
  local template_ids

  template_ids=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/job_templates/?name=APD+%7C+Install+Domain+Demo" 2>&1 \
    | jq -r --argjson org "$org_id" \
      '[.results[] | select(.summary_fields.organization.id == $org) | .id] | join(" ")')

  for template_id in $template_ids; do
    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X DELETE \
      "${AAP_API}/job_templates/${template_id}/" >/dev/null 2>&1 || true
    echo "  ✓ Removed legacy template APD | Install Domain Demo (ID: ${template_id})" >&2
  done
}

apd_dedupe_job_templates() {
  local template_name="$1"
  local keep_id="$2"
  local org_id="${DEFAULT_ORG_ID:-$(apd_default_org_id)}"
  local encoded_name duplicate_ids

  encoded_name=$(jq -rn --arg n "$template_name" '$n|@uri')
  duplicate_ids=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/job_templates/?name=${encoded_name}" 2>&1 \
    | jq -r --argjson org "$org_id" --argjson keep "$keep_id" \
      '[.results[] | select(.summary_fields.organization.id == $org and .id != $keep) | .id] | join(" ")')

  for template_id in $duplicate_ids; do
    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X DELETE \
      "${AAP_API}/job_templates/${template_id}/" >/dev/null 2>&1 || true
    echo "  ✓ Removed duplicate template ${template_name} (ID: ${template_id})" >&2
  done
}

apd_dedupe_domain_job_templates() {
  apd_dedupe_job_templates "$(apd_domain_template_name "$1")" "$2"
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
    --argjson org_id "${DEFAULT_ORG_ID}" \
    '{
      name: $name,
      description: $desc,
      job_type: "run",
      inventory: 1,
      project: $project_id,
      playbook: "setup_demo.yml",
      ask_variables_on_launch: false,
      organization: $org_id,
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
      "${AAP_API}/job_templates/?name=${encoded_name}" 2>&1 \
      | jq -r --argjson org "${DEFAULT_ORG_ID}" \
        '[.results[] | select(.summary_fields.organization.id == $org)] | .[0].id // empty' 2>/dev/null)

    if [ -z "$template_id" ]; then
      echo "❌ ERROR: Failed to create job template for ${demo}" >&2
      echo "$template_result" | jq '.' 2>/dev/null || echo "$template_result" >&2
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
    echo "✓ Job template already exists: ${template_name} (ID: ${template_id})" >&2
  else
    echo "✓ Job template created: ${template_name} (ID: ${template_id})" >&2
  fi

  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"id\": $cred_id}" \
    "${AAP_API}/job_templates/${template_id}/credentials/" >/dev/null 2>&1 || true

  apd_dedupe_domain_job_templates "$demo" "$template_id"

  printf '%s\n' "$template_id"
}

apd_init_aap_connection() {
  NAMESPACE="${NAMESPACE:-aap-operator}"
  local aap_route

  aap_route=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [ -z "$aap_route" ]; then
    aap_route=$(kubectl get route -n "$NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  fi
  if [ -z "$aap_route" ]; then
    echo "❌ ERROR: Cannot find AAP route" >&2
    return 1
  fi

  AAP_UI_URL="https://${aap_route}"
  AAP_API="${AAP_UI_URL}/api/controller/v2"
  AAP_USERNAME="${AAP_USERNAME:-admin}"
  AAP_PASSWORD=$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
  if [ -z "$AAP_PASSWORD" ]; then
    echo "❌ ERROR: Cannot retrieve AAP admin password" >&2
    return 1
  fi

  export AAP_UI_URL AAP_API AAP_USERNAME AAP_PASSWORD NAMESPACE
}

apd_resolve_domain_install_ids() {
  local ee_name="${1:-Product Demos EE}"

  DEFAULT_ORG_ID=$(apd_default_org_id)
  if [ -z "$DEFAULT_ORG_ID" ]; then
    echo "❌ ERROR: Cannot resolve Default organization ID" >&2
    return 1
  fi
  export DEFAULT_ORG_ID

  APD_PROJECT_ID=$(apd_default_bootstrap_project_id)
  if [ -z "$APD_PROJECT_ID" ]; then
    APD_PROJECT_ID=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/projects/?name=Ansible+Product+Demos" 2>&1 \
      | jq -r --argjson org "$DEFAULT_ORG_ID" \
        '[.results[] | select(.summary_fields.organization.id == $org)] | .[0].id // empty')
  fi

  APD_EE_ID=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/execution_environments/?name=$(jq -rn --arg n "$ee_name" '$n|@uri')" 2>&1 \
    | jq -r '.results[0].id // empty')
  APD_CRED_ID=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/credentials/?name=$(jq -rn --arg n "APD Installer - AAP Admin" '$n|@uri')" 2>&1 \
    | jq -r '.results[0].id // empty')

  if [ -z "$APD_PROJECT_ID" ] || [ -z "$APD_EE_ID" ] || [ -z "$APD_CRED_ID" ]; then
    echo "❌ ERROR: Missing bootstrap project, execution environment, or installer credential" >&2
    echo "  project=${APD_PROJECT_ID:-missing} ee=${APD_EE_ID:-missing} credential=${APD_CRED_ID:-missing}" >&2
    return 1
  fi

  export APD_PROJECT_ID APD_EE_ID APD_CRED_ID
}

apd_install_domain_demo() {
  local demo="$1"
  local template_name template_id launch_result job_id monitor_rc

  template_name=$(apd_domain_template_name "$demo")
  echo "Installing ${demo} demos (${template_name})..."

  apd_cleanup_legacy_install_templates
  apd_cleanup_default_org_apd_projects

  template_id=$(apd_ensure_domain_job_template "$demo" "$APD_PROJECT_ID" "$APD_EE_ID" "$APD_CRED_ID") || return 1

  launch_result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    "${AAP_API}/job_templates/${template_id}/launch/" 2>&1)

  job_id=$(echo "$launch_result" | jq -r '.id // empty' 2>/dev/null)
  if [ -z "$job_id" ]; then
    echo "❌ ERROR: Failed to launch ${demo} install job"
    echo "$launch_result" | jq '.' 2>/dev/null || echo "$launch_result"
    return 1
  fi

  echo "✓ Job launched for ${demo} (ID: ${job_id})"
  echo "View in UI: ${AAP_UI_URL}/#/jobs/playbook/${job_id}/output"

  apd_monitor_job "$job_id" "${demo} demo install" 80
  monitor_rc=$?
  apd_cleanup_default_org_apd_projects
  return "$monitor_rc"
}

apd_launch_extra_vars_json() {
  local demo="${1:-}"
  if [ -n "$demo" ]; then
    jq -n \
      --arg demo "$demo" \
      --arg version "$APD_AAP_VERSION" \
      '{
        demo: $demo,
        _aap_version: $version,
        aap_validate_certs: false,
        aap_configuration_async_retries: 0,
        gateway_configuration_async_retries: 0,
        controller_configuration_async_retries: 0
      }'
  else
    jq -n \
      --arg version "$APD_AAP_VERSION" \
      '{
        _aap_version: $version,
        aap_validate_certs: false,
        aap_configuration_async_retries: 0,
        gateway_configuration_async_retries: 0,
        controller_configuration_async_retries: 0
      }'
  fi
}

apd_find_controller_task_pod() {
  local pod selector
  for selector in \
    'app.kubernetes.io/name=aap-controller-task' \
    'app.kubernetes.io/component=task' \
    'app.kubernetes.io/name=controller-task'; do
    pod=$(kubectl get pods -n "$NAMESPACE" -l "$selector" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$pod" ]; then
      printf '%s\n' "$pod"
      return 0
    fi
  done

  pod=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E 'controller.*task|aap-controller-task' | head -1 || true)
  if [ -n "$pod" ]; then
    printf '%s\n' "$pod"
    return 0
  fi

  return 1
}

apd_overlay_project_playbook() {
  local project_id="$1"
  local src="$2"
  local dest_name="$3"
  local verify_pattern="${4:-}"

  if [ ! -f "$src" ]; then
    echo "  ⚠ Playbook overlay source not found: ${src}" >&2
    return 1
  fi

  echo "Overlaying ${dest_name} into bootstrap project (skip version ping)..."

  local project_dir task_pod
  task_pod=$(apd_find_controller_task_pod || true)

  if [ -z "$task_pod" ]; then
    echo "  ⚠ Could not find controller task pod; skipping playbook overlay" >&2
    return 1
  fi

  project_dir=$(kubectl exec -n "$NAMESPACE" "$task_pod" -- awx-manage shell -c "
from awx.main.models import Project
p = Project.objects.get(pk=${project_id})
print(p.get_project_path() or '')
" 2>/dev/null | grep '^/' | tail -1 | tr -d '\r')

  if [ -z "$project_dir" ]; then
    echo "  ⚠ Could not resolve project directory on task pod ${task_pod}" >&2
    return 1
  fi

  if ! kubectl exec -i -n "$NAMESPACE" "$task_pod" -- \
    tee "${project_dir}/${dest_name}" <"$src" >/dev/null 2>&1; then
    echo "  ⚠ Failed to copy ${dest_name} into ${project_dir}" >&2
    return 1
  fi

  if [ -n "$verify_pattern" ] && ! kubectl exec -n "$NAMESPACE" "$task_pod" -- \
    grep -q "$verify_pattern" "${project_dir}/${dest_name}" 2>/dev/null; then
    echo "  ⚠ Overlay verification failed for ${dest_name} (missing: ${verify_pattern})" >&2
    return 1
  fi

  echo "  ✓ Applied ${dest_name} on task pod: ${project_dir}/${dest_name}"
}

apd_apply_bootstrap_playbook_overlays() {
  local project_id="$1"
  local addons_base_dir="$2"
  local install_playbook="${3:-install-apd-aap-demo.yml}"
  local rc=0

  if [ "$install_playbook" = "install-apd-aap-demo.yml" ]; then
    if ! apd_overlay_project_playbook "$project_id" \
      "${addons_base_dir}/playbooks/install-apd-aap-demo.yml" \
      "install-apd-aap-demo.yml" \
      'pinned for aap-demo'; then
      rc=1
    fi
  elif [ "$install_playbook" = "install-apd.yml" ]; then
    if ! apd_overlay_project_playbook "$project_id" \
      "${addons_base_dir}/patches/install-apd.yml" \
      "install-apd.yml" \
      'when: _aap_version is not defined'; then
      rc=1
    fi
  else
    if ! apd_overlay_project_playbook "$project_id" \
      "${addons_base_dir}/playbooks/${install_playbook}" \
      "$install_playbook"; then
      rc=1
    fi
  fi

  # Keep patched install-apd.yml for manual runs even when the job template uses install-apd-aap-demo.yml.
  if [ "$install_playbook" != "install-apd.yml" ]; then
    apd_overlay_project_playbook "$project_id" \
      "${addons_base_dir}/patches/install-apd.yml" \
      "install-apd.yml" \
      'when: _aap_version is not defined' >/dev/null 2>&1 || true
  fi

  return "$rc"
}

apd_overlay_install_playbook() {
  apd_overlay_project_playbook "$1" "$2" "install-apd.yml" 'when: _aap_version is not defined'
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
