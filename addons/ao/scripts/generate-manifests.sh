#!/usr/bin/env bash
# Regenerate Automation Orchestrator manifest templates from aapctl --dry-run.
#
# Maintainer-only: end users do NOT need aapctl to run `aap-demo enable ao`.
#
# Docs:
#   https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-generate_aapctl_manifests_for_gitops
#   https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-understand_aapctl_manifest_application_order
#
# After running, manually update files under ../manifests/ (never commit Secrets).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"

if ! command -v aapctl >/dev/null 2>&1; then
  echo "ERROR: aapctl is required to regenerate manifests." >&2
  echo "  Install: https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-download_aapctl" >&2
  exit 1
fi

echo "Rendering aapctl install ao --dry-run (secrets will be stripped before commit)..."
_tmp="$(mktemp)"
aapctl install ao --dry-run -o yaml \
  --set cloudnative-pg-operator.enabled=true \
  --set cluster-cr.enabled=true \
  --set cluster-cr.storageClass=__STORAGE_CLASS__ \
  --set automation-orchestrator-operator.channel=__OPERATOR_CHANNEL__ \
  --set automation-orchestrator-cr.ingress.host=__INGRESS_HOST__ \
  --set automation-orchestrator-cr.ingress.type=Route \
  --set automation-orchestrator-cr.postgres.host=orchestrator-postgres-rw \
  --set automation-orchestrator-cr.postgres.sslMode=verify-ca \
  >"$_tmp"

echo ""
echo "Dry-run written to: ${_tmp}"
echo ""
echo "Update checked-in templates in ${MANIFESTS_DIR}:"
echo "  operator-subscription.yaml  — OperatorGroup + Subscription (patch sourceNamespace for MicroShift)"
echo "  postgres-cluster.yaml       — Cluster + Database CRs (no Secrets)"
echo "  automationorchestrator-cr.yaml — AutomationOrchestrator CR (+ imagePullSecrets placeholder)"
echo ""
echo "Do NOT commit Secret documents from this output."
echo "Inspect: grep -n '^kind:' ${_tmp}"
