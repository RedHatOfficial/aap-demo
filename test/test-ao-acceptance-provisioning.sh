#!/usr/bin/env bash
# Contract checks for repository-owned, immutable acceptance representatives.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AO_PROVISION="${ROOT_DIR}/addons/ao/scripts/provision-aap-demos.py"
AO_DEPLOY="${ROOT_DIR}/addons/ao/deploy.sh"
AO_SYNC="${ROOT_DIR}/addons/ao/playbooks/sync-ao-demos.yml"
PD_DEPLOY="${ROOT_DIR}/addons/product-demos-base/deploy.sh"
PD_LIB="${ROOT_DIR}/addons/product-demos-base/lib.sh"

grep -Fq 'AAP_DEMO_ACCEPTANCE_AO_READ_ONLY_OK' \
  "${ROOT_DIR}/addons/ao/playbooks/acceptance-read-only.yml"
grep -Fq 'AAP_DEMO_ACCEPTANCE_PRODUCT_DEMOS_READ_ONLY_OK' \
  "${ROOT_DIR}/addons/product-demos-base/playbooks/acceptance-read-only.yml"
grep -Fq 'acceptance_probe_pause_seconds' \
  "${ROOT_DIR}/addons/ao/playbooks/acceptance-read-only.yml"
grep -Fq 'acceptance_probe_pause_seconds' \
  "${ROOT_DIR}/addons/product-demos-base/playbooks/acceptance-read-only.yml"

grep -Fq 'AAP-Demo Acceptance | AO Read-Only Diagnostic' "$AO_PROVISION"
grep -Fq 'AAP-Demo Acceptance | Product Demos Read-Only Diagnostic' "$PD_LIB"
grep -Fq 'acceptance-read-only.yml' "$PD_LIB"
grep -Fq 'ao_acceptance_template_id' "$AO_SYNC"
grep -Fq 'product_demos_acceptance_template_id' "$AO_SYNC"
grep -Fq 'AAP-Demo Acceptance | MCP Read-Only' "$AO_SYNC"
grep -Fq 'node_type: agentic' "$AO_SYNC"
grep -Fq 'ao_mcp_integration_id' "$AO_SYNC"
grep -Fq 'integration_connections' \
  "${ROOT_DIR}/addons/ao/playbooks/tasks/sync_acceptance_workflow.yml"
grep -Fq 'sync_acceptance_workflow.yml' "$AO_SYNC"

if grep -Fq 'validate_certs: false' \
  "${ROOT_DIR}/addons/ao/playbooks/tasks/sync_acceptance_workflow.yml"; then
  echo "FAIL: acceptance workflow synchronization disables TLS verification" >&2
  exit 1
fi
grep -Fq 'Validate acceptance workflow bindings' \
  "${ROOT_DIR}/addons/ao/playbooks/tasks/sync_acceptance_workflow.yml"
grep -Fq 'mcp_tool_name' \
  "${ROOT_DIR}/addons/ao/playbooks/tasks/sync_acceptance_workflow.yml"
grep -Fq "__acceptance_workflow.job_template_id | default('', true) | string | trim | length > 0" \
  "${ROOT_DIR}/addons/ao/playbooks/tasks/sync_acceptance_workflow.yml"
grep -Fq "__acceptance_workflow.mcp_tool_name | default('') == 'controller.job_templates_list'" \
  "${ROOT_DIR}/addons/ao/playbooks/tasks/sync_acceptance_workflow.yml"
if sed -n '/^  pre_tasks:/,/^  tasks:/p' "$AO_SYNC" | grep -Fq '__acceptance_workflow'; then
  echo "FAIL: acceptance binding validation runs before the workflow loop" >&2
  exit 1
fi

grep -Fq 'git -C "$REPO_ROOT" rev-parse HEAD' "$AO_DEPLOY"
grep -Fq 'scm_branch: $revision' "$PD_DEPLOY"
grep -Fq 'scm_revision' "$PD_DEPLOY"
grep -Fq 'apd_pin_installed_project_revision' "$PD_DEPLOY"
grep -Fq 'apd_pin_installed_project_revision()' "$PD_LIB"
grep -Fq 'Ansible Product Demos' "$PD_LIB"
grep -Fq 'scm_update_on_launch: false' "$PD_LIB"

echo "PASS: immutable read-only AO and Product Demos representatives are provisioned"
