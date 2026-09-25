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
grep -q "python3 <<'PYEOF'" "${ADDON_DIR}/deploy.sh"
grep -q "ANSIBLE_PROJECT_ADMIN_PASSWORD" "${ADDON_DIR}/deploy.sh"

if "${ADDON_DIR}/deploy.sh" "http://github.com/org/repo.git" demo >/dev/null 2>&1; then
  echo "HTTP Git URLs must be rejected" >&2
  exit 1
fi

if "${ADDON_DIR}/deploy.sh" "https://github.com/org/repo.git" Invalid_Name >/dev/null 2>&1; then
  echo "Invalid project names must be rejected" >&2
  exit 1
fi

fake_bin=$(mktemp -d)
trap 'rm -rf "${fake_bin}"' EXIT
cat >"${fake_bin}/kubectl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${fake_bin}/kubectl"
delete_output=$(PATH="${fake_bin}:${PATH}" "${ADDON_DIR}/deploy.sh" --delete demo 2>&1)
echo "${delete_output}" | grep -q 'Project resources removed'

help_output=$("${SCRIPT_DIR}/aap-demo.sh" enable 2>&1)
echo "${help_output}" | grep -q 'ansible-project'

echo "✓ ansible-project addon is present, documented, and registered"
