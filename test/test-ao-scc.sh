#!/usr/bin/env bash
# Regression tests for AO CatalogSource SCC admission diagnostics.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export PATH="$TMP_DIR:$PATH"
export AO_CATALOG_TIMEOUT=5

cat >"$TMP_DIR/kubectl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"get pods"*"metadata.name"*) echo "redhat-operators-1" ;;
  *"get pods"*"status.phase"*) echo "Pending" ;;
  *"get pods"*"PodScheduled"*) if [ "${MOCK_MODE:-}" = "image-pull" ]; then echo ""; else echo "Failed: pods redhat-operators-1 is forbidden: unable to validate against any security context constraint"; fi ;;
  *"get pod redhat-operators-1"*"serviceAccountName"*) echo "redhat-operators" ;;
  *"get events"*) if [ "${MOCK_MODE:-}" = "image-pull" ]; then echo "BackOff: Back-off pulling image"; else echo "FailedCreate: unable to validate against any security context constraint"; fi ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$TMP_DIR/kubectl"

# Load only the shared functions; the include has no deploy-time side effects.
# shellcheck source=../includes/olm-catalog-signature.sh
source "${REPO_ROOT}/includes/olm-catalog-signature.sh"

if catalog_pod_has_scc_admission_failure automation-orchestrator; then
  echo "✓ detects SCC admission failure"
else
  echo "✗ failed to detect SCC admission failure"
  exit 1
fi

if output=$(wait_for_catalog_ready automation-orchestrator 2>&1); then
  echo "✗ wait_for_catalog_ready unexpectedly succeeded"
  exit 1
elif echo "$output" | grep -q "CatalogSource pod was rejected by SCC admission"; then
  echo "✓ wait loop reports SCC admission immediately"
else
  echo "✗ wait loop did not report SCC admission failure"
  echo "$output"
  exit 1
fi

output=$(report_catalog_scc_failure automation-orchestrator 2>&1)
if echo "$output" | grep -q "ServiceAccount: redhat-operators" \
  && echo "$output" | grep -q "oc adm policy add-scc-to-user anyuid -z redhat-operators"; then
  echo "✓ reports ServiceAccount and remediation"
else
  echo "✗ missing ServiceAccount or remediation in SCC failure report"
  echo "$output"
  exit 1
fi
export MOCK_MODE=image-pull
if catalog_pod_has_scc_admission_failure automation-orchestrator; then
  echo "✗ misclassified image-pull failure as SCC admission failure"
  exit 1
else
  echo "✓ does not misclassify image-pull failure"
fi
