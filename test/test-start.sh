#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export START_LOG="${TEST_DIR}/start.log"
SCRIPT_DIR="$TEST_DIR"
NAMESPACE=custom-aap
KUBECONFIG="${TEST_DIR}/kubeconfig"
AAP_START_TIMEOUT=1
SCENARIO=ready
ADDONS="mcp-server ollama ao fleet"
export HOME="${TEST_DIR}/home"
mkdir -p "$HOME/.aap-demo/fleet" "$TEST_DIR/includes" "$TEST_DIR/addons/fleet"

cat >"$TEST_DIR/includes/crc-create.sh" <<'EOF'
configure_coredns() {
  test "${AAP_DEMO_CONFIGURE_COREDNS_ONLY:-}" = 1 || return 1
  echo coredns >>"$START_LOG"
}
EOF
cat >"$TEST_DIR/addons/fleet/fleet.sh" <<'EOF'
fleet_start_all() {
  echo fleet >>"$START_LOG"
  test "${SCENARIO:-}" != fleet-failure
}
EOF

source "$REPO_ROOT/includes/aap-readiness.sh"
source "$REPO_ROOT/includes/kubernetes-readiness.sh"
source "$REPO_ROOT/includes/demo-start.sh"
eval "$(sed -n '/^cmd_start()/,/^}$/p' "$REPO_ROOT/aap-demo.sh")"

_err() { echo "ERROR: $*" >&2; }
_addons_list() { echo "$ADDONS"; }
_start_crc_cluster() { echo cluster >>"$START_LOG"; }
setup_kubeconfig() { echo kubeconfig >>"$START_LOG"; }
aap_demo_start_storage() { echo storage >>"$START_LOG"; }
_recover_aap_catalog_after_start() { echo catalog >>"$START_LOG"; }
install_ingress_ca_trust() { echo trust >>"$START_LOG"; }
cmd_status() { echo status >>"$START_LOG"; }
_aap_demo_run_addon_wire() {
  echo "wire $1" >>"$START_LOG"
  test "$SCENARIO" != wire-failure
}
sleep() { SECONDS=$((SECONDS + 1)); }
curl() {
  echo "curl $*" >>"$START_LOG"
  test "$SCENARIO" != route-failure
}
kubectl() {
  echo "$*" >>"$START_LOG"
  case "$*" in
    'get --raw='*) test "$SCENARIO" != api-failure ;;
    'wait '*) test "$SCENARIO" != node-failure ;;
    'get namespaces '*) echo 'openshift-dns openshift-ingress nfs-storage olm' ;;
    'get aap '*)
      test "$SCENARIO" != no-aap || return 1
      jq -n --arg scenario "$SCENARIO" '{
        items: [{
          metadata: {name: "demo"},
          spec: {idle_aap: ($scenario == "idle")},
          status: {conditions: [
            {type:"Successful", status:"False", reason:"Successful"},
            {type:"Running", status:"True"},
            {type:"Failure", status:(if $scenario == "aap-failure" then "True" else "False" end)}
          ]}
        }]
      }'
      ;;
    'patch aap '*) test "$SCENARIO" != patch-failure ;;
    'get deployment,statefulset,daemonset '*)
      if [ "$SCENARIO" = missing-namespace ]; then
        return 1
      elif [ "$SCENARIO" = empty-workloads ]; then
        echo '{"items":[]}'
      elif [ "$SCENARIO" = malformed-json ]; then
        echo '{invalid'
      else
        jq -n --arg scenario "$SCENARIO" '{
          items: [{
            kind: (if $scenario == "stateful-not-ready" then "StatefulSet"
                   elif $scenario == "daemon-not-ready" then "DaemonSet" else "Deployment" end),
            metadata: {generation: 2},
            spec: {replicas: (if $scenario == "scaled-zero" then 0 else 1 end)},
            status: {
              observedGeneration: (if $scenario == "stale-generation" then 1 else 2 end),
              readyReplicas: (if $scenario == "stateful-not-ready" then 0 else 1 end),
              updatedReplicas: (if $scenario == "old-rollout" then 0 else 1 end),
              availableReplicas: 1, desiredNumberScheduled: 1,
              numberReady: (if $scenario == "daemon-not-ready" then 0 else 1 end),
              updatedNumberScheduled: 1
            }
          }]
        }'
      fi
      ;;
    'get deployment '*)
      test "$SCENARIO" != missing-mcp
      ;;
    'get pods '*)
      jq -n --arg scenario "$SCENARIO" '{
        items: [{
          metadata: {name:"demo"},
          status: {
            phase: "Running",
            conditions:[{type:"Ready",status:(if $scenario == "unready-pod" then "False" else "True" end)}]
          }
        }]
      }'
      ;;
    'get route '*) echo demo.example.test ;;
    'get events '*) echo 'Insufficient memory' ;;
    *) return 1 ;;
  esac
}

if ! cmd_start >"$TEST_DIR/output" 2>&1; then
  cat "$TEST_DIR/output" >&2
  exit 1
fi
grep -q 'Demo ready' "$TEST_DIR/output"
grep -q 'export KUBECONFIG=' "$TEST_DIR/output"
grep -q 'get aap -n custom-aap' "$START_LOG"
grep -q 'get deployment aap-mcp-server -n custom-aap' "$START_LOG"
grep -q 'curl .*https://demo.example.test/api/gateway/v1/ping/' "$START_LOG"
for namespace in openshift-dns openshift-ingress nfs-storage olm custom-aap \
  cnpg-system aap-demo-ollama automation-orchestrator; do
  grep -q "get deployment,statefulset,daemonset -n $namespace " "$START_LOG"
done
if grep -q 'patch aap' "$START_LOG"; then
  echo "FAIL: healthy AAP was patched" >&2
  exit 1
fi
actual=$(grep -E '^(cluster|kubeconfig|storage|coredns|catalog|trust|fleet|wire true|status)$' "$START_LOG")
expected=$(printf '%s\n' cluster kubeconfig storage coredns catalog trust fleet 'wire true' status)
[ "$actual" = "$expected" ] || { echo "FAIL: incorrect startup order: $actual" >&2; exit 1; }
echo "PASS: start restores the configured demo in dependency order and prints kubeconfig guidance"

: >"$START_LOG"
SCENARIO=idle cmd_start >"$TEST_DIR/output" 2>&1
grep -q 'patch aap demo -n custom-aap --type=merge -p {"spec":{"idle_aap":false}}' "$START_LOG"
echo "PASS: idle AAP is resumed through the operator CR"

: >"$START_LOG"
ADDONS="" cmd_start >"$TEST_DIR/output" 2>&1
if grep -qE 'fleet|cnpg-system|aap-demo-ollama|automation-orchestrator' "$START_LOG"; then
  echo "FAIL: disabled addon was started or checked" >&2
  exit 1
fi
echo "PASS: disabled addons are not started or checked"

for addon in portal portal-operator apme-eap; do
  : >"$START_LOG"
  ADDONS="$addon" cmd_start >"$TEST_DIR/output" 2>&1
  case "$addon" in
    portal) namespace=redhat-rhaap-portal ;;
    portal-operator) namespace=automation-portal ;;
    apme-eap) namespace=apme ;;
  esac
  grep -q "get deployment,statefulset,daemonset -n $namespace " "$START_LOG"
done
echo "PASS: enabled portal and APME workloads are checked"

for scenario in api-failure node-failure no-aap missing-mcp missing-namespace \
  empty-workloads malformed-json stale-generation old-rollout stateful-not-ready \
  daemon-not-ready scaled-zero unready-pod aap-failure route-failure fleet-failure wire-failure; do
  : >"$START_LOG"
  if SCENARIO="$scenario" cmd_start >"$TEST_DIR/output" 2>&1; then
    echo "FAIL: $scenario reported successful startup" >&2
    exit 1
  fi
  if grep -q 'Demo ready' "$TEST_DIR/output" || grep -q '^status$' "$START_LOG"; then
    echo "FAIL: $scenario printed a success summary" >&2
    exit 1
  fi
done
echo "PASS: API, node, deployment, addon, reconciliation, route, Fleet and wiring failures propagate"

for timeout in 0 -1 abc 1m; do
  : >"$START_LOG"
  if AAP_START_TIMEOUT="$timeout" cmd_start >"$TEST_DIR/output" 2>&1; then
    echo "FAIL: invalid timeout accepted: $timeout" >&2
    exit 1
  fi
  grep -q 'positive number of seconds' "$TEST_DIR/output"
  test ! -s "$START_LOG"
done
echo "PASS: invalid timeout fails before cluster mutations"
