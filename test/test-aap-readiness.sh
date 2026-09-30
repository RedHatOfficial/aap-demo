#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../includes/aap-readiness.sh
source "${REPO_ROOT}/includes/aap-readiness.sh"

if aap_condition_is_complete "True" "True" "Successful"; then
  echo "PASS: Successful=True remains terminal"
else
  echo "FAIL: Successful=True must remain terminal" >&2
  exit 1
fi

if aap_condition_is_complete "False" "True" "Successful"; then
  echo "PASS: AAP 2.7 Running=True terminal state is accepted"
else
  echo "FAIL: AAP 2.7 terminal Running=True state was rejected" >&2
  exit 1
fi

if aap_condition_is_complete "" "True" "Running"; then
  echo "FAIL: Running=True during reconciliation was accepted too early" >&2
  exit 1
else
  echo "PASS: Running=True during reconciliation is not terminal"
fi

if aap_condition_is_complete "False" "True" "Successful" "True"; then
  echo "FAIL: Failure=True must prevent completion" >&2
  exit 1
else
  echo "PASS: Failure=True prevents completion"
fi

if grep -q "aap_condition_is_complete" scripts/watch-aap.sh \
  && grep -q "successfulReason" powershell/native/Private/Helpers.ps1 \
  && grep -q "runningStatus" powershell/native/Private/Helpers.ps1 \
  && grep -q "aap_condition_is_complete" addons/opa/deploy.sh; then
  echo "PASS: shell and PowerShell watchers share terminal-state semantics"
else
  echo "FAIL: cross-platform readiness implementations are incomplete" >&2
  exit 1
fi

mock_bin=$(mktemp -d "${TMPDIR:-/tmp}/aap-watch-test.XXXXXX")
trap 'rm -rf "$mock_bin"' EXIT
cat >"$mock_bin/kubectl" <<'EOF'
#!/usr/bin/env bash

case "$*" in
  *creationTimestamp*) printf '%s\n' '2026-09-30T00:00:00Z' ;;
  *'config current-context'*) printf '%s\n' 'test-context' ;;
  *'config view'*) printf '%s\n' 'https://test.example.test:6443' ;;
  *'--no-headers'*) printf '%s\n' 'aap-pod 1/1 Running 0 1m' ;;
  *status.conditions\}*) printf '%s\n' '[]' ;;
  *Successful*status*) printf '%s\n' 'False' ;;
  *Running*status*) printf '%s\n' 'True' ;;
  *Successful*reason*) printf '%s\n' 'Successful' ;;
  *Failure*status*) printf '%s\n' 'False' ;;
  *'spec.host'*) printf '%s\n' 'aap.example.test' ;;
  *'metadata.name'*) printf '%s\n' 'aap-operator.v2.7.0' ;;
  *) : ;;
esac
EOF
chmod +x "$mock_bin/kubectl"

watch_output=$(PATH="$mock_bin:$PATH" TERM=xterm ./scripts/watch-aap.sh test-namespace 2>&1) || true
if printf '%s\n' "$watch_output" | grep -q "AAP on OpenShift Deployment Complete"; then
  echo "PASS: standalone watcher accepts AAP 2.7 terminal state"
else
  printf '%s\n' "$watch_output" >&2
  echo "FAIL: standalone watcher rejected AAP 2.7 terminal state" >&2
  exit 1
fi
