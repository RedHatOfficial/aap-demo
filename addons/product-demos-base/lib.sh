#!/usr/bin/env bash
# Shared helpers for product-demos addons.

apd_common_extra_vars_yaml() {
  jq -r -n '{
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
