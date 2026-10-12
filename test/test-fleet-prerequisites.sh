#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fleet="${repo_root}/addons/fleet/fleet.sh"
deploy="${repo_root}/addons/fleet/deploy.sh"
readme="${repo_root}/addons/fleet/README.md"

grep -Fq 'fleet_install_prereqs' "$fleet"
grep -Fq 'brew install qemu cdrtools' "$fleet" "$deploy" "$readme"
grep -Fq 'sudo dnf install -y qemu-kvm qemu-img genisoimage' "$fleet" "$deploy" "$readme"
grep -Fq 'QUIET' "$deploy"
grep -Fq 'non-interactive' "$readme"

echo "PASS: Fleet prerequisite installation is explicit and non-interactive-safe"
