#!/usr/bin/env bash
# Static checks for Add repository + AI defaults in apme-eap addon.
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
grep -q 'apme-prototype-plugins' "$PORTAL_INJECT"
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
grep -q 'resolve_github_catalog_org' "$DEPLOY"
grep -q 'apme_github_catalog_org' "${ROOT}/addons/apme-eap/defaults.yml"
grep -q 'Automation-Portal-ACME' "${ROOT}/addons/apme-eap/defaults.yml"
grep -q 'prompt_github_catalog_org_interactive' "$DEPLOY"
grep -q 'GITHUB_SAVED_CATALOG_ORG' "$DEPLOY"
if grep -q '_GITHUB_CATALOG_ORG_PRESET' "$DEPLOY"; then
  echo "FAIL: deploy.sh still uses _GITHUB_CATALOG_ORG_PRESET" >&2
  exit 1
fi
grep -q '_github_integration_active' "$DEPLOY"
if ! sed -n '/^resolve_github_catalog_org()/,/^}/p' "$DEPLOY" | grep -q '_github_integration_active'; then
  echo "FAIL: resolve_github_catalog_org must gate on _github_integration_active" >&2
  exit 1
fi
if ! sed -n '/^resolve_github_catalog_org()/,/^}/p' "$DEPLOY" | grep -q 'catalog org is unset'; then
  echo "FAIL: resolve_github_catalog_org must die when GitHub active without org (non-interactive)" >&2
  exit 1
fi
grep -q '_github_app_config_complete' "$DEPLOY"
grep -q 'Use GitHub App \[A\] or Personal access token \[P\]' "$DEPLOY"
if sed -n '/^resolve_github_catalog_org()/,/^}/p' "$DEPLOY" | grep -q 'VARS_FILE'; then
  echo "FAIL: resolve_github_catalog_org still reads VARS_FILE for org" >&2
  exit 1
fi
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
test -f "$GALAXY_SEED"
grep -q 'apme_pah_gateway_exec_target:' "$GALAXY_SEED"
grep -q 'deploy/{{ apme_helm_release_name' "$GALAXY_SEED"
grep -q 'apme_pah_gateway_exec_target' "$GALAXY_SEED"
if grep -qE 'apme-engine-[0-9a-f]{5,}' "$GALAXY_SEED"; then
  echo "FAIL: galaxy seed still references ephemeral pod name" >&2
  exit 1
fi

helm template apme apme/apme --version 0.1.10 -f "$APME_VALUES" >/dev/null

echo "OK: apme-eap Add repository + AI static checks passed"
