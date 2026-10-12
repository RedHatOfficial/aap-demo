#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deploy="${repo_root}/addons/fleet/deploy.sh"

grep -Fq 'FLEET_IMAGE' "$deploy"
grep -Fq 'FLEET_NODE_COUNT' "$deploy"
grep -Fq 'fleet_install_prereqs' "$deploy"
grep -Fq 'fleet_create_all' "$deploy"
grep -Fq 'fleet_register_aap' "$deploy"
grep -Fq 'fleet_destroy_all' "$deploy"
grep -Fq 'fleet_list' "$deploy"

echo "PASS: Fleet enable is configured as a guided create/register workflow"
