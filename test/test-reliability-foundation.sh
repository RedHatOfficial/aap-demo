#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

PASSED=0
FAILED=0

pass() {
  echo "✓ $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo "✗ $1" >&2
  FAILED=$((FAILED + 1))
}

export AAP_DEMO_DIR="${TEST_DIR}/home"
export AAP_DEMO_LOCK_DIR="${AAP_DEMO_DIR}/operation.lock"
mkdir -p "$AAP_DEMO_DIR"

# shellcheck source=includes/operation-lock.sh
source "${REPO_ROOT}/includes/operation-lock.sh"

if aap_demo_acquire_operation_lock deploy; then
  pass "operation_lock_acquires"
else
  fail "operation_lock_acquires"
fi

if env -u AAP_DEMO_LOCK_TOKEN \
  AAP_DEMO_DIR="$AAP_DEMO_DIR" \
  AAP_DEMO_LOCK_DIR="$AAP_DEMO_LOCK_DIR" \
  bash -c "source '${REPO_ROOT}/includes/operation-lock.sh'; aap_demo_acquire_operation_lock start" \
  >"${TEST_DIR}/contended.out" 2>&1; then
  fail "operation_lock_rejects_concurrent_mutation"
else
  if grep -q 'Another aap-demo operation is already running' "${TEST_DIR}/contended.out"; then
    pass "operation_lock_rejects_concurrent_mutation"
  else
    fail "operation_lock_rejects_concurrent_mutation"
  fi
fi

_aap_demo_release_operation_lock
mkdir -p "$AAP_DEMO_LOCK_DIR"
cat >"${AAP_DEMO_LOCK_DIR}/owner" <<'EOF'
pid=999999
token=stale
command=deploy
started=2000-01-01T00:00:00Z
EOF
unset AAP_DEMO_LOCK_TOKEN
if aap_demo_acquire_operation_lock start; then
  pass "operation_lock_recovers_stale_owner"
else
  fail "operation_lock_recovers_stale_owner"
fi
_aap_demo_release_operation_lock

MOCK_BIN="${TEST_DIR}/bin"
mkdir -p "$MOCK_BIN"
cat >"${TEST_DIR}/nodes.json" <<'EOF'
{"items":[{"status":{"allocatable":{"cpu":"4","memory":"8Gi"}}}]}
EOF
cat >"${TEST_DIR}/pods.json" <<'EOF'
{"items":[
  {
    "spec":{
      "nodeName":"node-1",
      "containers":[
        {"resources":{"requests":{"cpu":"500m","memory":"1Gi"}}},
        {"resources":{"requests":{"cpu":"1","memory":"512Mi"}}}
      ],
      "initContainers":[
        {"resources":{"requests":{"cpu":"2","memory":"256Mi"}}}
      ]
    },
    "status":{"phase":"Running"}
  },
  {
    "spec":{
      "containers":[{"resources":{"requests":{"cpu":"3","memory":"4Gi"}}}]
    },
    "status":{"phase":"Pending"}
  }
]}
EOF
cat >"${MOCK_BIN}/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "get nodes -o json") cat "$TEST_NODES_JSON" ;;
  "get pods -A -o json") cat "$TEST_PODS_JSON" ;;
  rollout\ status\ deployment/*)
    exit "${ROLLOUT_RC:-0}"
    ;;
  get\ deployment*) printf '%s\n' 'mock deployment diagnostics' ;;
  get\ pods*) printf '%s\n' 'mock pod diagnostics' ;;
  get\ events*) printf '%s\n' 'mock event diagnostics' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${MOCK_BIN}/kubectl"

export TEST_NODES_JSON="${TEST_DIR}/nodes.json"
export TEST_PODS_JSON="${TEST_DIR}/pods.json"
export PATH="${MOCK_BIN}:$PATH"

# shellcheck source=includes/resource-preflight.sh
source "${REPO_ROOT}/includes/resource-preflight.sh"

snapshot=$(aap_demo_cluster_resource_snapshot)
if [ "$snapshot" = $'4000\t8192\t2000\t1536' ]; then
  pass "resource_snapshot_uses_scheduler_semantics"
else
  fail "resource_snapshot_uses_scheduler_semantics"
  echo "  got: $snapshot" >&2
fi

if output=$(aap_demo_resource_preflight "test workload" 2500 7000 2>&1) \
  && echo "$output" | grep -q 'WARNING: test workload recommends'; then
  pass "resource_preflight_warns_by_default"
else
  fail "resource_preflight_warns_by_default"
fi

if AAP_RESOURCE_PREFLIGHT_STRICT=true \
  aap_demo_resource_preflight "test workload" 2500 7000 >/dev/null 2>&1; then
  fail "resource_preflight_strict_mode_fails"
else
  pass "resource_preflight_strict_mode_fails"
fi

printf '%s\n' 'not-json' >"$TEST_PODS_JSON"
if aap_demo_cluster_resource_snapshot >/dev/null 2>&1; then
  fail "resource_snapshot_rejects_malformed_json"
else
  pass "resource_snapshot_rejects_malformed_json"
fi
cat >"$TEST_PODS_JSON" <<'EOF'
{"items":[]}
EOF

cat >"$TEST_NODES_JSON" <<'EOF'
{"items":[{"status":{"allocatable":{"cpu":"invalid","memory":"8Gi"}}}]}
EOF
if aap_demo_cluster_resource_snapshot >/dev/null 2>&1; then
  fail "resource_snapshot_rejects_malformed_quantity"
else
  pass "resource_snapshot_rejects_malformed_quantity"
fi
cat >"$TEST_NODES_JSON" <<'EOF'
{"items":[{"status":{"allocatable":{"cpu":"4","memory":"8Gi"}}}]}
EOF

# shellcheck source=includes/kubernetes-readiness.sh
source "${REPO_ROOT}/includes/kubernetes-readiness.sh"
if ROLLOUT_RC=0 aap_demo_wait_deployment test-ns test-deployment 30s >/dev/null 2>&1; then
  pass "deployment_readiness_succeeds"
else
  fail "deployment_readiness_succeeds"
fi

if ROLLOUT_RC=1 aap_demo_wait_deployment test-ns test-deployment 30s \
  >"${TEST_DIR}/readiness-failure.out" 2>&1; then
  fail "deployment_readiness_reports_failure"
else
  if grep -q 'did not become ready' "${TEST_DIR}/readiness-failure.out" \
    && grep -q 'mock deployment diagnostics' "${TEST_DIR}/readiness-failure.out"; then
    pass "deployment_readiness_reports_failure"
  else
    fail "deployment_readiness_reports_failure"
  fi
fi

# shellcheck disable=SC2016
if grep -q 'aap_demo_acquire_operation_lock "\$COMMAND"' "${REPO_ROOT}/aap-demo.sh"; then
  pass "cli_dispatch_acquires_mutation_lock"
else
  fail "cli_dispatch_acquires_mutation_lock"
fi

if aap_demo_command_requires_lock preflight; then
  fail "preflight_remains_read_only"
else
  pass "preflight_remains_read_only"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
