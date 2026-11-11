#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  AAP_DEMO_LIVE_IDEMPOTENCY=1 ./test/test-live-idempotency.sh -- <command> [args...]

Example:
  AAP_DEMO_LIVE_IDEMPOTENCY=1 ./test/test-live-idempotency.sh -- aap-demo wire

Runs the command once to converge the environment, snapshots normalized Kubernetes
desired state, runs the same command again, and fails if the second run changes specs.
This is a live-cluster test and may invoke mutating commands.
EOF
}

if [ "${AAP_DEMO_LIVE_IDEMPOTENCY:-0}" != "1" ]; then
  echo "ERROR: Set AAP_DEMO_LIVE_IDEMPOTENCY=1 to acknowledge live-cluster mutation." >&2
  usage
  exit 2
fi

if [ "${1:-}" != "--" ] || [ "$#" -lt 2 ]; then
  usage
  exit 2
fi
shift
COMMAND=("$@")

for tool in kubectl jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: Required tool not found: $tool" >&2
    exit 1
  }
done
kubectl cluster-info --request-timeout=10s >/dev/null 2>&1 || {
  echo "ERROR: Kubernetes API is not reachable." >&2
  exit 1
}

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

snapshot_desired_state() {
  local destination="$1"
  local resource
  : >"$destination.raw"

  for resource in \
    deployments.apps \
    statefulsets.apps \
    daemonsets.apps \
    services \
    persistentvolumeclaims \
    routes.route.openshift.io \
    catalogsources.operators.coreos.com \
    subscriptions.operators.coreos.com \
    ansibleautomationplatforms.aap.ansible.com \
    automationorchestrators.aap.ansible.com; do
    if kubectl get "$resource" -A -o json --request-timeout=30s \
      >"$TEST_DIR/resource.json" 2>/dev/null; then
      jq -c --arg resource "$resource" '
        .items[]? |
        {
          resource: $resource,
          namespace: (.metadata.namespace // ""),
          name: .metadata.name,
          spec: .spec
        }
      ' "$TEST_DIR/resource.json" >>"$destination.raw"
    fi
  done

  jq -s 'sort_by(.resource, .namespace, .name)' "$destination.raw" >"$destination"
}

printf 'Convergence run:'
printf ' %q' "${COMMAND[@]}"
echo
"${COMMAND[@]}"

snapshot_desired_state "$TEST_DIR/first.json"

printf 'Idempotency run:'
printf ' %q' "${COMMAND[@]}"
echo
"${COMMAND[@]}"

snapshot_desired_state "$TEST_DIR/second.json"

if cmp -s "$TEST_DIR/first.json" "$TEST_DIR/second.json"; then
  echo "✓ Second run preserved normalized Kubernetes desired state"
  exit 0
fi

echo "ERROR: Second run changed normalized Kubernetes desired state." >&2
diff -u "$TEST_DIR/first.json" "$TEST_DIR/second.json" 2>/dev/null \
  | sed -n '1,200p' >&2 || true
echo "Diff output is limited to 200 lines." >&2
exit 1
