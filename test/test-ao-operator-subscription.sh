#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${SCRIPT_DIR}/addons/ao/manifests/operator-subscription.yaml"
DEPLOY="${SCRIPT_DIR}/addons/ao/deploy.sh"
README="${SCRIPT_DIR}/addons/ao/README.md"

grep -q 'installPlanApproval: __INSTALL_PLAN_APPROVAL__' "$MANIFEST"
grep -q 'AO_INSTALL_PLAN_APPROVAL="${AO_INSTALL_PLAN_APPROVAL:-Automatic}"' "$DEPLOY"
grep -q '__INSTALL_PLAN_APPROVAL__' "$DEPLOY"
grep -q 'AO_INSTALLPLAN_NAME' "$DEPLOY"
grep -q 'automation-orchestrator-operator' "$DEPLOY"
grep -q 'AO_INSTALL_PLAN_APPROVAL' "$README"
grep -q 'early-access' "$README"

echo "✓ AO operator subscription defaults to automatic approval and documents manual override"
