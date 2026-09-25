#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDON_DIR="${SCRIPT_DIR}/addons/ansible-project"

for file in \
  README.md \
  deploy.sh \
  project.yml.example \
  vault.yml.example \
  templates/aap_credential_cr.yml.j2 \
  templates/credential_cr.yml.j2 \
  templates/inventory_cr.yml.j2 \
  templates/job_template_cr.yml.j2 \
  templates/project_cr.yml.j2; do
  test -f "${ADDON_DIR}/${file}"
done

grep -q 'ansible-project' "${SCRIPT_DIR}/aap-demo.sh"
grep -q 'Only HTTPS Git URLs are supported' "${ADDON_DIR}/deploy.sh"
grep -q 'ansible-vault encrypt' "${ADDON_DIR}/README.md"

help_output=$("${SCRIPT_DIR}/aap-demo.sh" enable 2>&1)
echo "${help_output}" | grep -q 'ansible-project'

echo "✓ ansible-project addon is present, documented, and registered"
