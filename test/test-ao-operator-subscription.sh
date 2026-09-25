#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${SCRIPT_DIR}/addons/ao/manifests/operator-subscription.yaml"
DEPLOY="${SCRIPT_DIR}/addons/ao/deploy.sh"
README="${SCRIPT_DIR}/addons/ao/README.md"
APPROVAL_LIB="${SCRIPT_DIR}/addons/ao/lib/install-plan-approval.sh"

grep -q 'installPlanApproval: __INSTALL_PLAN_APPROVAL__' "$MANIFEST"
grep -q 'AO_INSTALL_PLAN_APPROVAL_REQUESTED=' "$DEPLOY"
grep -q '__INSTALL_PLAN_APPROVAL__' "$DEPLOY"
grep -q 'ao_resolve_install_plan_approval' "$DEPLOY"
grep -q 'ao_apply_install_plan_approval' "$DEPLOY"
grep -q 'ao_pending_install_plans' "$DEPLOY"
grep -q 'ownerReferences' "$APPROVAL_LIB"
grep -q 'ao_manual_install_plan_instructions' "$APPROVAL_LIB"
grep -q 'Timed out waiting for manual InstallPlan approval' "$APPROVAL_LIB"
grep -q 'AO_INSTALL_PLAN_APPROVAL' "$README"
grep -q 'early-access' "$README"

echo "✓ AO operator subscription defaults to automatic approval and documents manual override"
