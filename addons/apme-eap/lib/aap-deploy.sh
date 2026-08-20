#!/usr/bin/env bash
# AAP REST API helpers — run APME playbooks as Controller jobs (no local Python/ansible).

APME_PROJECT_NAME="${APME_PROJECT_NAME:-APME EAP (aap-demo)}"
APME_TEMPLATE_NAME="${APME_TEMPLATE_NAME:-APME | Deploy Portal}"
APME_PLAYBOOK="${APME_PLAYBOOK:-addons/apme-eap/playbooks/deploy_apme_portal.yml}"
APME_EE_NAME="${APME_EE_NAME:-APME Portal EE}"
APME_EE_IMAGE="${APME_EE_IMAGE:-quay.io/ansible-product-demos/apd-ee-26:latest}"

_apme_info() { info "$@" >&2; }
_apme_warn() { warn "$@" >&2; }

apme_init_aap_api() {
  local ns="${AAP_NAMESPACE:-aap-operator}"
  local route

  route=$(kubectl get route aap -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [ -z "$route" ]; then
    route=$(kubectl get route -n "$ns" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  fi
  if [ -z "$route" ]; then
    die "AAP route not found in namespace ${ns}"
  fi

  AAP_UI_URL="https://${route}"
  AAP_API="${AAP_UI_URL}/api/controller/v2"
  AAP_USERNAME="${AAP_USERNAME:-admin}"
  export AAP_UI_URL AAP_API AAP_USERNAME
}

apme_default_org_id() {
  curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/organizations/?name=Default" 2>&1 \
    | jq -r '.results[0].id // empty'
}

apme_discover_scm() {
  local repo_root="${1:-}"

  if [ -n "${APME_PROJECT_SCM_URL:-}" ]; then
    APME_SCM_URL="$APME_PROJECT_SCM_URL"
    APME_SCM_BRANCH="${APME_PROJECT_SCM_BRANCH:-main}"
    return 0
  fi

  if [ -z "$repo_root" ]; then
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  fi

  if ! git -C "$repo_root" rev-parse --is-inside-work-tree &>/dev/null; then
    return 1
  fi

  APME_SCM_URL=$(git -C "$repo_root" config --get remote.origin.url 2>/dev/null || echo "")
  APME_SCM_BRANCH=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

  case "$APME_SCM_URL" in
    git@github.com:*)
      APME_SCM_URL="https://github.com/${APME_SCM_URL#git@github.com:}"
      APME_SCM_URL="${APME_SCM_URL%.git}"
      ;;
    ssh://git@github.com/*)
      APME_SCM_URL="${APME_SCM_URL#ssh://git@github.com/}"
      APME_SCM_URL="https://github.com/${APME_SCM_URL%.git}"
      ;;
  esac

  [ -n "$APME_SCM_URL" ]
}

apme_create_cluster_token() {
  local ns="${AAP_NAMESPACE:-aap-operator}"
  local sa="apme-deployer"
  local binding="apme-deployer-admin"

  kubectl get serviceaccount "$sa" -n "$ns" &>/dev/null \
    || kubectl create serviceaccount "$sa" -n "$ns" &>/dev/null

  kubectl get clusterrolebinding "$binding" &>/dev/null \
    || kubectl create clusterrolebinding "$binding" \
      --clusterrole=cluster-admin \
      --serviceaccount="${ns}:${sa}" &>/dev/null

  kubectl create token "$sa" -n "$ns" --duration=8760h
}

apme_internal_aap_host() {
  local ns="${AAP_NAMESPACE:-aap-operator}"
  if kubectl get svc aap -n "$ns" &>/dev/null; then
    echo "http://aap.${ns}.svc.cluster.local"
    return 0
  fi
  echo "${AAP_HOST}"
}

apme_build_extra_vars() {
  local vars_file="$1"
  local defaults_file="$2"
  local cluster_token internal_aap

  cluster_token=$(apme_create_cluster_token)
  internal_aap=$(apme_internal_aap_host)

  # Single YAML document (AWX extra_vars); later keys override earlier ones.
  {
    sed '/^---[[:space:]]*$/d' "$defaults_file"
    sed '/^---[[:space:]]*$/d' "$vars_file"
    cat <<EOF
openshift_api_url: "https://kubernetes.default.svc:443"
openshift_validate_certs: false
openshift_token: "${cluster_token}"
aap_host: "${internal_aap}"
aap_validate_certs: false
EOF
  }
}

# Strip non-ASCII bytes so Controller API JSON stays valid UTF-8 on Windows/Git Bash.
apme_sanitize_extra_vars_file() {
  local file="$1"
  local tmp="${file}.san"

  sed -e 's/—/-/g' -e 's/–/-/g' "$file" | tr -cd '\11\12\15\40-\176' >"$tmp"
  mv "$tmp" "$file"
}

apme_ensure_project() {
  local org_id="$1"
  local project_id payload result

  payload=$(jq -n \
    --arg name "$APME_PROJECT_NAME" \
    --arg url "$APME_SCM_URL" \
    --arg branch "$APME_SCM_BRANCH" \
    --argjson org "$org_id" \
    '{
      name: $name,
      description: "aap-demo apme-eap playbooks (Git SCM)",
      scm_type: "git",
      scm_url: $url,
      scm_branch: $branch,
      scm_update_on_launch: true,
      organization: $org
    }')

  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST -H "Content-Type: application/json" \
    -d "$payload" "${AAP_API}/projects/" 2>&1)

  project_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$project_id" ]; then
    project_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/projects/?name=$(jq -rn --arg n "$APME_PROJECT_NAME" '$n|@uri')" 2>&1 \
      | jq -r --argjson org "$org_id" \
        '[.results[] | select(.summary_fields.organization.id == $org)] | .[0].id // empty')
    if [ -n "$project_id" ]; then
      curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
        -X PATCH -H "Content-Type: application/json" \
        -d "$(jq -n \
          --arg url "$APME_SCM_URL" \
          --arg branch "$APME_SCM_BRANCH" \
          '{scm_url: $url, scm_branch: $branch, scm_update_on_launch: true}')" \
        "${AAP_API}/projects/${project_id}/" >/dev/null 2>&1
      _apme_info "Project already exists (ID: ${project_id})"
    else
      die "Failed to create AAP project: $result"
    fi
  else
    _apme_info "Project created (ID: ${project_id})"
  fi

  printf '%s\n' "$project_id"
}

apme_sync_project() {
  local project_id="$1"
  local update_id status i

  update_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST "${AAP_API}/projects/${project_id}/update/" 2>&1 \
    | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$update_id" ]; then
    _apme_warn "Could not trigger project sync — using cached project content"
    return 0
  fi

  _apme_info "Syncing project (update ID: ${update_id})..."
  for i in $(seq 1 60); do
    status=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/project_updates/${update_id}/" 2>&1 \
      | jq -r '.status // "unknown"' 2>/dev/null)
    case "$status" in
      successful)
        _apme_info "Project sync complete"
        return 0
        ;;
      failed | error | canceled)
        die "Project sync failed (status: ${status})"
        ;;
    esac
    sleep 3
  done
  die "Project sync timed out"
}

apme_ensure_execution_environment() {
  local org_id="$1"
  local ee_id payload result

  ee_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/execution_environments/?name=$(jq -rn --arg n "$APME_EE_NAME" '$n|@uri')" 2>&1 \
    | jq -r --argjson org "$org_id" \
      '[.results[] | select(.summary_fields.organization.id == $org)] | .[0].id // empty')

  if [ -n "$ee_id" ]; then
    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X PATCH -H "Content-Type: application/json" \
      -d "$(jq -n --arg image "$APME_EE_IMAGE" '{image: $image, pull: "missing"}')" \
      "${AAP_API}/execution_environments/${ee_id}/" >/dev/null 2>&1
    _apme_info "Execution environment exists (ID: ${ee_id})"
    printf '%s\n' "$ee_id"
    return 0
  fi

  payload=$(jq -n \
    --arg name "$APME_EE_NAME" \
    --arg image "$APME_EE_IMAGE" \
    --argjson org "$org_id" \
    '{name: $name, description: "APME deployment EE (helm/oc/ansible)", image: $image, organization: $org, pull: "missing"}')

  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST -H "Content-Type: application/json" \
    -d "$payload" "${AAP_API}/execution_environments/" 2>&1)

  ee_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)
  [ -n "$ee_id" ] || die "Failed to create execution environment: $result"
  _apme_info "Execution environment created (ID: ${ee_id})"
  printf '%s\n' "$ee_id"
}

apme_ensure_job_template() {
  local org_id="$1" project_id="$2" ee_id="$3" extra_vars_file="$4"
  local template_id payload result

  payload=$(jq -n \
    --arg name "$APME_TEMPLATE_NAME" \
    --arg desc "Deploy APME portal via aap-demo apme-eap addon" \
    --rawfile extra_vars "$extra_vars_file" \
    --arg playbook "$APME_PLAYBOOK" \
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
    }')

  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST -H "Content-Type: application/json" \
    -d "$payload" "${AAP_API}/job_templates/" 2>&1)

  template_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$template_id" ]; then
    template_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/job_templates/?name=$(jq -rn --arg n "$APME_TEMPLATE_NAME" '$n|@uri')" 2>&1 \
      | jq -r --argjson org "$org_id" \
        '[.results[] | select(.summary_fields.organization.id == $org)] | .[0].id // empty')
    if [ -n "$template_id" ]; then
      curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
        -X PATCH -H "Content-Type: application/json" \
        -d "$(jq -n \
          --argjson ee_id "$ee_id" \
          --argjson project_id "$project_id" \
          --arg playbook "$APME_PLAYBOOK" \
          --rawfile extra_vars "$extra_vars_file" \
          '{execution_environment: $ee_id, project: $project_id, playbook: $playbook, extra_vars: $extra_vars}')" \
        "${AAP_API}/job_templates/${template_id}/" >/dev/null 2>&1
      _apme_info "Job template already exists (ID: ${template_id})"
    else
      die "Failed to create job template: $result"
    fi
  else
    _apme_info "Job template created (ID: ${template_id})"
  fi

  printf '%s\n' "$template_id"
}

apme_monitor_job() {
  local job_id="$1"
  local max_wait="${2:-120}"

  for i in $(seq 1 "$max_wait"); do
    local job_status status elapsed
    job_status=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/jobs/${job_id}/" 2>&1)
    status=$(echo "$job_status" | jq -r '.status // "unknown"' 2>/dev/null)
    elapsed=$(echo "$job_status" | jq -r '.elapsed // 0' 2>/dev/null)

    case "$status" in
      successful)
        echo ""
        _apme_info "APME deployment job completed (ID: ${job_id})"
        return 0
        ;;
      failed | error | canceled)
        echo ""
        _apme_warn "Last failed task(s):"
        kubectl exec -n "${AAP_NAMESPACE:-aap-operator}" deploy/aap-controller-web -- bash -c "awx-manage shell -c \"
from awx.main.models import Job
j = Job.objects.get(id=${job_id})
for ev in j.job_events.filter(event='runner_on_failed').order_by('-id')[:3]:
    out = (ev.stdout or ev.msg or '').strip()
    if out:
        print(ev.task)
        for line in out.splitlines()[-8:]:
            print('  ', line)
\"" 2>/dev/null || true
        die "APME deployment job failed (ID: ${job_id}). View: ${AAP_UI_URL}/#/jobs/playbook/${job_id}/output"
        ;;
    esac
    printf "\r  Job status: %-12s | Elapsed: %3ss | Waiting... %2d/%s" "$status" "$elapsed" "$i" "$max_wait"
    sleep 5
  done

  echo ""
  _apme_warn "Job still running after $((max_wait * 5))s — check AAP UI: ${AAP_UI_URL}/#/jobs/playbook/${job_id}/output"
  return 2
}

apme_launch_job() {
  local template_id="$1"
  local job_id result

  result=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST -H "Content-Type: application/json" \
    -d '{}' "${AAP_API}/job_templates/${template_id}/launch/" 2>&1)

  job_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)
  [ -n "$job_id" ] || die "Failed to launch job: $result"

  _apme_info "Job launched (ID: ${job_id})"
  _apme_info "View in AAP: ${AAP_UI_URL}/#/jobs/playbook/${job_id}/output"
  printf '%s\n' "$job_id"
}

apme_deploy_via_aap() {
  local vars_file="$1"
  local defaults_file="$2"
  local repo_root org_id project_id ee_id extra_vars_file template_id job_id

  repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"

  if ! command -v jq &>/dev/null; then
    die "jq is required for AAP-based deployment. Install: winget install jqlang.jq"
  fi

  apme_init_aap_api
  org_id=$(apme_default_org_id)
  [ -n "$org_id" ] || die "Default organization not found in AAP"

  if ! apme_discover_scm "$repo_root"; then
    die "Cannot determine Git SCM URL. Set APME_PROJECT_SCM_URL and APME_PROJECT_SCM_BRANCH, or run from a git clone with origin."
  fi
  _apme_info "Project SCM: ${APME_SCM_URL} (branch: ${APME_SCM_BRANCH})"
  if git -C "$repo_root" rev-parse --is-inside-work-tree &>/dev/null; then
    if ! git -C "$repo_root" diff --quiet HEAD -- addons/apme-eap 2>/dev/null \
      || [ -n "$(git -C "$repo_root" status --porcelain -- addons/apme-eap 2>/dev/null)" ]; then
      _apme_warn "Local apme-eap changes are not in Git. Commit and push, or AAP will run playbooks from the remote branch."
    fi
  fi

  extra_vars_file=$(mktemp)
  apme_build_extra_vars "$vars_file" "$defaults_file" >"$extra_vars_file"
  apme_sanitize_extra_vars_file "$extra_vars_file"

  project_id=$(apme_ensure_project "$org_id")
  apme_sync_project "$project_id"

  ee_id=$(apme_ensure_execution_environment "$org_id")
  template_id=$(apme_ensure_job_template "$org_id" "$project_id" "$ee_id" "$extra_vars_file")

  _apme_info "Launching APME deployment job in AAP (no local Python required)..."
  job_id=$(apme_launch_job "$template_id")
  apme_monitor_job "$job_id" 120
  rm -f "$extra_vars_file"
}
