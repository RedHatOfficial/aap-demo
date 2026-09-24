#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../addons/ao/lib/replica-profile.sh
source "${REPO_ROOT}/addons/ao/lib/replica-profile.sh"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local description="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: ${description}: expected '${expected}', got '${actual}'" >&2
    exit 1
  fi
  echo "PASS: ${description}"
}

assert_resolves() {
  local value="$1"
  local expected="$2"
  local description="$3"
  local actual
  actual=$(AO_LOW_RESOURCE="$value" ao_resolve_replica_count)
  assert_eq "$expected" "$actual" "$description"
}

assert_resolves "" 1 "unset profile defaults to one replica"
assert_resolves 1 1 "explicit low-resource profile uses one replica"
assert_resolves true 1 "true low-resource profile uses one replica"
assert_resolves 0 2 "zero selects the two-replica opt-out"
assert_resolves false 2 "false selects the two-replica opt-out"

if output=$(AO_LOW_RESOURCE=unexpected ao_resolve_replica_count 2>&1); then
  echo "FAIL: invalid AO_LOW_RESOURCE value was accepted" >&2
  exit 1
elif ! echo "$output" | grep -q "AO_LOW_RESOURCE must be unset, 0, false, 1, or true"; then
  echo "FAIL: invalid AO_LOW_RESOURCE error was not actionable" >&2
  echo "$output" >&2
  exit 1
fi
echo "PASS: invalid profile is rejected"

render_cr() {
  local replica_count="$1"
  sed -e "s|__NAMESPACE__|automation-orchestrator|g" \
    -e 's|__INGRESS_HOST__|ao.example.test|g' \
    -e 's|__PULL_SECRET_NAME__|pull-secret|g' \
    -e "s|__AO_REPLICA_COUNT__|${replica_count}|g" \
    "${REPO_ROOT}/addons/ao/manifests/automationorchestrator-cr.yaml"
}

default_cr=$(render_cr "$(AO_LOW_RESOURCE='' ao_resolve_replica_count)")
assert_eq 3 "$(echo "$default_cr" | grep -c '^    replicas: 1$')" \
  "default CR has one replica for backend, UI, and worker"
low_cr=$(render_cr "$(AO_LOW_RESOURCE=0 ao_resolve_replica_count)")
assert_eq 3 "$(echo "$low_cr" | grep -c '^    replicas: 2$')" \
  "two-replica opt-out CR has two replicas for backend, UI, and worker"

for required_field in \
  'kind: AutomationOrchestrator' \
  '  backend:' \
  '  ui:' \
  '  worker:'; do
  if ! echo "$default_cr" | grep -q "$required_field"; then
    echo "FAIL: rendered CR is missing '${required_field}'" >&2
    exit 1
  fi
done
echo "PASS: replica values are rendered in the AutomationOrchestrator CR"

if grep -q 'kubectl scale' "${REPO_ROOT}/addons/ao/deploy.sh"; then
  echo "FAIL: AO deploy script contains direct replica scaling" >&2
  exit 1
fi
echo "PASS: AO replica source of truth remains the custom resource"

fast_path_apply_line=$(awk '/^[[:space:]]+deploy_ao_instance$/ { print NR; exit }' \
  "${REPO_ROOT}/addons/ao/deploy.sh")
ingress_init_line=$(awk '/^INGRESS_HOST=/ { print NR; exit }' \
  "${REPO_ROOT}/addons/ao/deploy.sh")
if [ -z "$fast_path_apply_line" ] || [ -z "$ingress_init_line" ] \
  || [ "$ingress_init_line" -gt "$fast_path_apply_line" ]; then
  echo "FAIL: existing-install CR apply can run before INGRESS_HOST is initialized" >&2
  exit 1
fi
echo "PASS: existing-install CR apply has an initialized ingress host"

echo "AO replica profile tests passed"
