#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill_file="${repo_root}/SKILL.md"

grep -Fq 'Local demo:' "$skill_file"
grep -Fq 'Shared environments:' "$skill_file"
grep -Fq 'CI/CD:' "$skill_file"
grep -Fq 'Production:' "$skill_file"
grep -Fq 'infra.aap_configuration' "$skill_file"
grep -Fq 'ansible-galaxy collection list' "$skill_file"
grep -Fq 'collections/requirements.yml' "$skill_file"
grep -Fq 'dispatch' "$skill_file"

echo "PASS: MCP credential scoping and AAP collection guidance is present"
