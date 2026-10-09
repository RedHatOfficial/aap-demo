#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../addons/ao/lib/operator-controller.sh
source "${REPO_ROOT}/addons/ao/lib/operator-controller.sh"

assert_eq() {
  local expected="$1" actual="$2" description="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: ${description}: expected '${expected}', got '${actual}'" >&2
    exit 1
  fi
  echo "PASS: ${description}"
}

kubectl() {
  case "$*" in
    "get deployment automation-orchestrator-operator-controller-manager -n automation-orchestrator")
      return 1
      ;;
    "get deployment automation-orchestrator-operator-controller-manager -n openshift-operators")
      return 1
      ;;
    "get deployment -n automation-orchestrator -l olm.owner.kind=ClusterServiceVersion -o jsonpath={range .items[*]}{.metadata.name}{\"|\"}{.metadata.labels.olm\\.owner}{\"\\n\"}{end}")
      return 0
      ;;
    "get deployment -n openshift-operators -l olm.owner.kind=ClusterServiceVersion -o jsonpath={range .items[*]}{.metadata.name}{\"|\"}{.metadata.labels.olm\\.owner}{\"\\n\"}{end}")
      printf '%s\n' 'ao-controller-manager|automation-orchestrator-operator.v1.2.3'
      return 0
      ;;
    *)
      echo "unexpected kubectl call: $*" >&2
      return 1
      ;;
  esac
}

assert_eq "openshift-operators" \
  "$(ao_operator_controller_namespace automation-orchestrator automation-orchestrator)" \
  "controller namespace is discovered from OLM-owned deployment labels"
assert_eq "ao-controller-manager" \
  "$(ao_operator_controller_deployment automation-orchestrator automation-orchestrator)" \
  "controller deployment name is discovered from OLM owner labels"

echo "AO operator controller discovery tests passed"