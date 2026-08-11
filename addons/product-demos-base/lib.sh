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
  local playbook_src="$2"
  local playbook_name
  playbook_name=$(basename "$playbook_src")
  local patched_install_src="${3:-}"

  echo "Overlaying aap-demo playbook into synced project (${playbook_name})..."

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

  kubectl cp "$playbook_src" "${NAMESPACE}/${task_pod}:${project_dir}/${playbook_name}" >/dev/null 2>&1

  if [ -n "$patched_install_src" ] && [ -f "$patched_install_src" ]; then
    kubectl cp "$patched_install_src" \
      "${NAMESPACE}/${task_pod}:${project_dir}/install-apd.yml" >/dev/null 2>&1 || true
  fi

  echo "  ✓ Playbook overlay applied: ${project_dir}/${playbook_name}"
}
