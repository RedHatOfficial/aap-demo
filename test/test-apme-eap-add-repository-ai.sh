#!/usr/bin/env bash
# Static checks for Add repository + AI defaults in apme-eap addon.
# GitHub catalog org wizard behavior (one prompt, PAT/App, creds YAML): manual TC-013 in addons/apme-eap/TEST_PLAN.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORTAL_OVERLAY="${ROOT}/addons/apme-eap/playbooks/roles/apme_helm_values/files/portal-apme-overlay.yaml.template"
PORTAL_CHART_TASK="${ROOT}/addons/apme-eap/playbooks/roles/apme_helm_values/tasks/fetch_portal_chart_values.yml"
PORTAL_INJECT="${ROOT}/addons/apme-eap/playbooks/roles/apme_helm_values/tasks/inject_dynamic_plugins.yml"
SCAFFOLD_TMPL="${ROOT}/addons/apme-eap/playbooks/roles/openshift_apme_setup/files/apme-register-git-repository/template.yaml"
APME_VALUES="${ROOT}/addons/apme-eap/playbooks/roles/apme_gateway_helm/files/apme-values.yaml"
APME_GATEWAY_TASKS="${ROOT}/addons/apme-eap/playbooks/roles/apme_gateway_helm/tasks/main.yml"
ABBENAY_CONFIG_J2="${ROOT}/addons/apme-eap/playbooks/roles/apme_gateway_helm/templates/abbenay-config.yaml.j2"

test -f "$PORTAL_OVERLAY"
test -f "$PORTAL_CHART_TASK"
test -f "$PORTAL_INJECT"
if test -f "${ROOT}/addons/apme-eap/playbooks/roles/apme_helm_values/files/portal-apme-values.yaml.template"; then
  echo "FAIL: vendored portal-apme-values.yaml.template should be removed" >&2
  exit 1
fi
grep -q 'show' "$PORTAL_CHART_TASK" && grep -q 'values' "$PORTAL_CHART_TASK"
grep -q 'ansible-plugin-backstage-apme' "$PORTAL_INJECT"
grep -q 'values_files:' "${ROOT}/addons/apme-eap/playbooks/roles/portal_helm_install/tasks/main.yml"
grep -q 'apme_portal_chart_values_path' "${ROOT}/addons/apme-eap/playbooks/roles/portal_helm_install/tasks/main.yml"

grep -q 'addRepositoryButton:' "$PORTAL_OVERLAY"
grep -q 'enabled: true' "$PORTAL_OVERLAY"
grep -q 'enableAi: true' "$PORTAL_OVERLAY"
grep -q 'feedbackFormUrl: https://red.ht/amce-preview-feedback' "$PORTAL_OVERLAY"
if grep -q 'forms.gle/VUvfyTjnVax83GPt6' "$PORTAL_OVERLAY"; then
  echo "FAIL: portal overlay still references default Google feedback form" >&2
  exit 1
fi
test "$(grep -c 'GitHubRepoUrlFieldExtension' "$PORTAL_OVERLAY")" -ge 1
grep -q '<github-catalog-org>' "$PORTAL_OVERLAY"
grep -q 'github-catalog-scm' "$PORTAL_OVERLAY"
if grep -q 'name: acme-scm' "$PORTAL_OVERLAY"; then
  echo "FAIL: portal overlay still hardcodes acme-scm org" >&2
  exit 1
fi

DEPLOY="${ROOT}/addons/apme-eap/deploy.sh"

_deploy_sh_fn() {
  sed -n "/^$1()/,/^}/p" "$DEPLOY"
}

_deploy_sh_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_deploy_sh_fn_must_grep() {
  local fn="$1" pattern="$2" msg="$3"
  if ! _deploy_sh_fn "$fn" | grep -q "$pattern"; then
    _deploy_sh_fail "$msg"
  fi
}

_deploy_sh_fn_must_not_grep() {
  local fn="$1" pattern="$2" msg="$3"
  if _deploy_sh_fn "$fn" | grep -q "$pattern"; then
    _deploy_sh_fail "$msg"
  fi
}

_deploy_sh_fn_line_after() {
  local fn="$1" before="$2" after="$3" msg="$4"
  local body line_before line_after
  body="$(_deploy_sh_fn "$fn")"
  line_before="$(printf '%s\n' "$body" | grep -n "$before" | head -1 | cut -d: -f1)"
  line_after="$(printf '%s\n' "$body" | grep -n "$after" | head -1 | cut -d: -f1)"
  if [ -z "$line_before" ] || [ -z "$line_after" ] || [ "$line_after" -le "$line_before" ]; then
    _deploy_sh_fail "$msg"
  fi
}

_deploy_sh_deploy_case() {
  sed -n '/^[[:space:]]*deploy | --deploy)/,/^[[:space:]]*;;/p' "$DEPLOY"
}

grep -q 'resolve_github_catalog_org' "$DEPLOY"
grep -q 'apme_github_catalog_org' "${ROOT}/addons/apme-eap/defaults.yml"
grep -q 'Automation-Portal-ACME' "${ROOT}/addons/apme-eap/defaults.yml"
grep -q 'prompt_github_catalog_org_interactive' "$DEPLOY"
grep -q 'GITHUB_SAVED_CATALOG_ORG' "$DEPLOY"
if grep -q '_GITHUB_CATALOG_ORG_PRESET' "$DEPLOY"; then
  _deploy_sh_fail "deploy.sh still uses _GITHUB_CATALOG_ORG_PRESET"
fi
grep -q '_github_integration_active' "$DEPLOY"
_deploy_sh_fn_must_grep resolve_github_catalog_org '_github_integration_active' \
  'resolve_github_catalog_org must gate on _github_integration_active'
_deploy_sh_fn_must_grep resolve_github_catalog_org 'no sync org is set' \
  'resolve_github_catalog_org must die when GitHub active without org (non-interactive)'
_deploy_sh_fn_must_grep resolve_github_catalog_org 'APME_GITHUB_CATALOG_ORG=YourOrg' \
  'resolve_github_catalog_org die must mention APME_GITHUB_CATALOG_ORG=YourOrg'
# shellcheck disable=SC2016 # The pattern intentionally matches literal shell syntax.
_deploy_sh_fn_must_grep resolve_github_catalog_org 'APME_GITHUB_CATALOG_ORG:-}" ] && \[ "${_GITHUB_CATALOG_ORG_CONFIRMED' \
  'resolve_github_catalog_org must early-return when org already confirmed'
_deploy_sh_fn_line_after resolve_github_catalog_org 'GITHUB_SAVED_CATALOG_ORG' 'prompt_github_catalog_org_interactive' \
  'resolve_github_catalog_org must use saved creds org before interactive prompt'
_deploy_sh_fn_must_not_grep resolve_github_catalog_org 'VARS_FILE' \
  'resolve_github_catalog_org still reads VARS_FILE for org'
_deploy_sh_fn_must_grep prompt_github_catalog_org_interactive 'sync into automation portal' \
  'prompt_github_catalog_org_interactive must use automation portal sync wording'
_deploy_sh_fn_line_after prompt_github_token 'Use GitHub App \[A\] or Personal access token' 'prompt_github_catalog_org_interactive' \
  'catalog org prompt must come after GitHub App vs PAT choice in prompt_github_token'
_deploy_sh_fn_must_grep prompt_github_token 'automation portal catalog' \
  'prompt_github_token must explain portal catalog sync before org prompt'
_deploy_sh_fn_must_grep prompt_github_token 'Portal sync org:' \
  'prompt_github_token must report Portal sync org after save'
_deploy_sh_fn_must_not_grep _save_github_creds_to_file '_persist_github_catalog_org_in_creds_file' \
  '_save_github_creds_to_file must not call _persist_github_catalog_org_in_creds_file'
_deploy_sh_fn_must_grep generate_vars_file '_github_integration_active' \
  'generate_vars_file must gate apme_github_catalog_org on _github_integration_active'
_deploy_sh_fn_must_grep generate_vars_file 'apme_github_catalog_org:' \
  'generate_vars_file must emit apme_github_catalog_org when integration active'
deploy_case="$(_deploy_sh_deploy_case)"
if ! printf '%s' "$deploy_case" | grep -q 'resolve_github_catalog_org'; then
  _deploy_sh_fail 'deploy case must call resolve_github_catalog_org'
fi
persist_calls="$(printf '%s' "$deploy_case" | grep -c '_persist_github_catalog_org_in_creds_file' || true)"
if [ "$persist_calls" -ne 1 ]; then
  _deploy_sh_fail "deploy case must call _persist_github_catalog_org_in_creds_file exactly once (got ${persist_calls})"
fi
if ! _deploy_sh_deploy_case | grep -A20 'resolve_github_catalog_org' | grep -q '_persist_github_catalog_org_in_creds_file'; then
  _deploy_sh_fail 'deploy case must persist catalog org after resolve_github_catalog_org'
fi
grep -q '_github_app_config_complete' "$DEPLOY"
grep -q 'Use GitHub App \[A\] or Personal access token \[P\]' "$DEPLOY"
grep -q 'if _github_app_config_complete; then' "$DEPLOY"
bash -n "$DEPLOY"

grep -q 'rhdh_image_tag: "1.10"' "${ROOT}/addons/apme-eap/defaults.yml"
grep -q '<rhdh-hub-tag>' "$PORTAL_OVERLAY"
if grep -q 'rhdh_image_tag: "1.9"' "${ROOT}/addons/apme-eap/playbooks/roles/apme_helm_values/tasks/main.yml"; then
  echo "FAIL: main.yml still hardcodes rhdh_image_tag 1.9" >&2
  exit 1
fi
if grep -q '1\\.9' "${ROOT}/addons/apme-eap/playbooks/roles/apme_helm_values/tasks/main.yml"; then
  echo "FAIL: main.yml still references hub tag regexp 1.9" >&2
  exit 1
fi
grep -q 'apme-eap/defaults.yml' "${ROOT}/addons/portal/deploy.sh"

grep -q 'ui:field: GitHubRepoUrlField' "$SCAFFOLD_TMPL"
grep -q 'ansible:register:git-repository' "$SCAFFOLD_TMPL"
if grep -q 'RepoUrlPicker' "$SCAFFOLD_TMPL"; then
  echo "FAIL: scaffolder template still uses RepoUrlPicker" >&2
  exit 1
fi

grep -q 'abbenay:' "$APME_VALUES"
grep -q 'bootstrap-placeholder:' "$APME_VALUES"
grep -q 'abbenay:' "$APME_VALUES" && awk '/^persistence:/{p=1} p&&/abbenay:/{found=1; exit} END{exit !found}' "$APME_VALUES"

test -f "$ABBENAY_CONFIG_J2"
grep -q 'chat: true' "$ABBENAY_CONFIG_J2"
grep -q "abbenay-config.yaml.j2" "$APME_GATEWAY_TASKS"
grep -q 'Apply bundled Abbenay config' "$APME_GATEWAY_TASKS"
grep -q 'portal are cleared' "$DEPLOY"
grep -q 'configured in the automation' "$DEPLOY"

GALAXY_SEED="${ROOT}/addons/apme-eap/playbooks/roles/apme_pah_integration/tasks/seed_apme_galaxy_servers.yml"
PAH_DEFAULTS="${ROOT}/addons/apme-eap/playbooks/roles/apme_pah_integration/defaults/main.yml"
test -f "$GALAXY_SEED"
grep -q 'apme_pah_gateway_exec_target:' "$GALAXY_SEED"
grep -q 'apme_engine_deploy' "$GALAXY_SEED"
grep -q "apme_helm_release_name | default('apme')" "$PAH_DEFAULTS"
grep -q 'apme_pah_gateway_exec_target' "$GALAXY_SEED"
if grep -qE 'apme-engine-[0-9a-f]{5,}' "$GALAXY_SEED"; then
  echo "FAIL: galaxy seed still references ephemeral pod name" >&2
  exit 1
fi

echo "OK: apme-eap Add repository + AI static checks passed"
