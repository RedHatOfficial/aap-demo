#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export SCRIPT_DIR="$REPO_ROOT"
export NAMESPACE="aap-operator"
export KUBECONFIG="$TEST_DIR/kubeconfig"
export AAP_DEMO_SYSTEM_INFO_FILE="$TEST_DIR/docs/aap-demo-system-info.md"
export AAP_DEMO_DIR="$TEST_DIR/state"
export AO_LLM_PROVIDER=external
export AO_LLM_BASE_URL=https://llm.example.test/v1
export AO_LLM_MODEL=test-model
export CRC_DISK=160
export AAP_DEMO_GIT_DATE=2026-01-01T00:00:00Z
export AAP_DEMO_REPO_ROOT="$REPO_ROOT"
export AAP_DEMO_GIT_BRANCH=test
export AAP_DEMO_GIT_REMOTE=https://example.test/aap-demo.git

mkdir -p "$AAP_DEMO_DIR/ao"
printf 'llm-key-fixture' >"$AAP_DEMO_DIR/ao/llm-api-key"
chmod 600 "$AAP_DEMO_DIR/ao/llm-api-key"

aap_demo_version_short() {
  printf 'test-version'
}

infra_get_name() {
  printf 'test-cluster'
}

infra_get_state() {
  printf 'running'
}

crc() {
  [ "$*" = ip ] || return 1
  printf '192.168.127.2\n'
}

_detect_crc_ssh_key() {
  printf '/fixture/id_ed25519\n'
}

_addons_list() {
  printf 'mcp-server ao'
}

infra_exec_cmd() {
  printf 'Test RHEL\t4.22.1\t8\t4Gi\t16Gi\t12Gi\t0.1 0.2 0.3\t10G/50G (20%% used)\t50\t10\t40\n'
}

aap_demo_resolve_kubeconfig() {
  printf '%s' "$KUBECONFIG"
}

getent() {
  printf '127.0.0.1 STREAM fixture\n'
}

kubectl() {
  case "$*" in
    "cluster-info")
      return 0
      ;;
    "config current-context")
      printf 'aap-demo\n'
      ;;
    "version -o json")
      printf '{"serverVersion":{"gitVersion":"v1.33.1"}}\n'
      ;;
    "get route -A -o json")
      cat <<'EOF'
{"items":[
  {"metadata":{"namespace":"aap-operator","name":"aap"},"spec":{"host":"aap.example.test","to":{"name":"aap"},"port":{"targetPort":"http"},"tls":{"termination":"edge"}}},
  {"metadata":{"namespace":"automation-orchestrator","name":"automation-orchestrator"},"spec":{"host":"ao.example.test","to":{"name":"automation-orchestrator-ui"},"port":{"targetPort":"http"},"tls":{"termination":"edge"}}}
]}
EOF
      ;;
    "get namespace -o json")
      printf '{"items":[{"metadata":{"name":"aap-operator"}},{"metadata":{"name":"automation-orchestrator"}}]}\n'
      ;;
    "get namespace automation-orchestrator")
      return 0
      ;;
    "get service -A -o json")
      printf '{"items":[{"metadata":{"namespace":"aap-operator","name":"aap"},"spec":{"type":"ClusterIP","clusterIP":"10.43.1.2","ports":[{"port":80,"protocol":"TCP","targetPort":8000}]}},{"metadata":{"namespace":"automation-orchestrator","name":"automation-orchestrator-ui"},"spec":{"type":"ClusterIP","clusterIP":"10.43.1.3","ports":[{"port":80,"protocol":"TCP","targetPort":8080}]}}]}\n'
      ;;
    "get pods -A -o json")
      printf '{"items":[{"metadata":{"namespace":"aap-operator","name":"aap-gateway"},"status":{"phase":"Running","podIP":"10.42.0.2","containerStatuses":[{"ready":true,"restartCount":0}]},"spec":{"nodeName":"test-node"}},{"metadata":{"namespace":"automation-orchestrator","name":"automation-orchestrator-ui"},"status":{"phase":"Running","podIP":"10.42.0.3","containerStatuses":[{"ready":true,"restartCount":1}]},"spec":{"nodeName":"test-node"}}]}\n'
      ;;
    "get aap -A -o json")
      printf '{"items":[{"metadata":{"namespace":"aap-operator","name":"aap"},"status":{"adminPasswordSecret":"aap-admin-password"}}]}\n'
      ;;
    "get secret aap-admin-password -n aap-operator -o jsonpath={.data.password}")
      printf 'YWFwLXBhc3N3b3Jk'
      ;;
    "get secret automation-orchestrator-initial-admin-password -n automation-orchestrator -o jsonpath={.data.password}")
      printf 'YW8tcGFzc3dvcmQ='
      ;;
    "get service router-default -n openshift-ingress -o json")
      printf '{"metadata":{"name":"router-default"},"spec":{"clusterIP":"10.43.1.4","externalIPs":["192.168.1.2"],"ports":[{"port":80,"protocol":"TCP","nodePort":30080},{"port":443,"protocol":"TCP","nodePort":30443}]},"status":{"loadBalancer":{"ingress":[{"ip":"10.42.0.2"}]}}}\n'
      ;;
    "get endpoints router-default -n openshift-ingress -o json")
      printf '{"subsets":[{"addresses":[{"ip":"10.42.0.4"}],"ports":[{"port":80,"protocol":"TCP"},{"port":443,"protocol":"TCP"}]}]}\n'
      ;;
    *)
      echo "Unexpected kubectl invocation: $*" >&2
      return 1
      ;;
  esac
}

# shellcheck source=../includes/ao-llm.sh
source "$REPO_ROOT/includes/ao-llm.sh"
# shellcheck source=../includes/system-inventory.sh
source "$REPO_ROOT/includes/system-inventory.sh"
# shellcheck source=../includes/system-info-document.sh
source "$REPO_ROOT/includes/system-info-document.sh"

include_inventory=$(aap_demo_collect_system_inventory include)
redacted_inventory=$(aap_demo_collect_system_inventory redact)
omitted_inventory=$(aap_demo_collect_system_inventory omit)

[ "$(jq -r '.credentials[] | select(.component == "AAP") | .password' <<<"$include_inventory")" = "aap-password" ]
[ "$(jq -r '.credentials[] | select(.component == "AAP") | .password' <<<"$redacted_inventory")" = "******" ]
[ "$(jq -r '.credentials[] | select(.component == "AAP") | .password' <<<"$omitted_inventory")" = "null" ]
[ "$(jq -r '.cluster.crc_ip' <<<"$include_inventory")" = "192.168.127.2" ]
[ "$(jq -r '.cluster.ssh.ssh_key' <<<"$include_inventory")" = /fixture/id_ed25519 ]
[ "$(jq -r '.cluster.ssh.ssh_port' <<<"$include_inventory")" = 2222 ]
[ "$(jq -r '.addons | join(",")' <<<"$include_inventory")" = "mcp-server,ao" ]
[ "$(jq -r '.namespaces[] | select(.name == "aap-operator") | .ready' <<<"$include_inventory")" = "true" ]
[ "$(jq -r '.storage.capacity_planning.actual_vm_disk_gib' <<<"$include_inventory")" = 50 ]
[ "$(jq -r '.storage.capacity_planning.actual_vm_used_gib' <<<"$include_inventory")" = 10 ]
[ "$(jq -r '.storage.capacity_planning.actual_vm_free_gib' <<<"$include_inventory")" = 40 ]
[ "$(jq -r '.storage.capacity_planning.configured_crc_disk_gib' <<<"$include_inventory")" = 160 ]
[ "$(jq -r '.storage.capacity_planning.recommended_vm_disk_gib' <<<"$include_inventory")" = 210 ]
[ "$(jq -r '.storage.capacity_planning.needs_rebuild' <<<"$include_inventory")" = true ]
[ "$(jq -r '.storage.capacity_planning.configured_not_applied' <<<"$include_inventory")" = true ]
[ "$(jq -r '.storage.capacity_planning.projected_vm_disk_gib.ollama' <<<"$include_inventory")" = 220 ]

unset CRC_DISK VM_DISK_SIZE
export INFRA_TYPE=crc
crc() {
  [ "$*" = "config get disk-size" ] || return 1
  printf 'disk-size : 120\n'
}
crc_storage=$(_aap_demo_inventory_storage "" '{"disk_gib":{}}')
[ "$(jq -r '.configured_crc_disk_gib' <<<"$crc_storage")" = 120 ]

crc() {
  printf 'disk-size : 120\n'
  return 1
}
crc_error_storage=$(_aap_demo_inventory_storage "" '{"disk_gib":{}}')
[ "$(jq -r '.configured_crc_disk_gib' <<<"$crc_error_storage")" = null ]
unavailable_access=$(_aap_demo_inventory_crc_access 2>"$TEST_DIR/crc-warning")
[ "$(jq -r '.crc_ip' <<<"$unavailable_access")" = null ]
grep -q 'CRC IP unavailable' "$TEST_DIR/crc-warning"

crc() {
  case "$*" in
    ip) printf '192.168.127.2\n' ;;
    "config get disk-size") printf 'disk-size : 120\n' ;;
    *) return 1 ;;
  esac
}

aap_demo_generate_system_info include markdown "$AAP_DEMO_SYSTEM_INFO_FILE" >/dev/null

report="$AAP_DEMO_SYSTEM_INFO_FILE"
[ -f "$report" ]
[ "$(stat -c '%a' "$report")" = "600" ]
grep -q 'aap.example.test' "$report"
grep -q 'ao.example.test' "$report"
grep -q 'aap-password' "$report"
grep -q 'ao-password' "$report"
grep -q 'llm-key-fixture' "$report"
grep -q 'crc_ip: `192.168.127.2`' "$report"
grep -q 'aap-demo ssh' "$report"
grep -q '/fixture/id_ed25519' "$report"
grep -q '10.43.1.2' "$report"
grep -q '10.42.0.3' "$report"
grep -q '80/TCP -> 8000' "$report"
grep -q 'AAP MCP OAuth token: Generated for client configuration but not persisted' "$report"

redacted_report=$(aap_demo_generate_system_info redact markdown -)
grep -q '\*\*\*\*\*\*' <<<"$redacted_report"
if grep -q 'aap-password\|ao-password\|llm-key-fixture' <<<"$redacted_report"; then
  echo "Redacted report exposed a secret" >&2
  exit 1
fi

json_report="$TEST_DIR/docs/aap-demo-system-info.json"
aap_demo_generate_system_info redact json "$json_report" >/dev/null
jq -e '.schema_version == 1 and .secret_mode == "redact"' "$json_report" >/dev/null
[ "$(stat -c '%a' "$json_report")" = "600" ]

deploy_function=$(sed -n '/^cmd_deploy()/,/^}$/p' "$REPO_ROOT/aap-demo.sh")
redeploy_function=$(sed -n '/^cmd_redeploy()/,/^}$/p' "$REPO_ROOT/aap-demo.sh")
redeploy_all_function=$(sed -n '/^cmd_redeploy-all()/,/^}$/p' "$REPO_ROOT/aap-demo.sh")
grep -q 'aap_demo_generate_system_info' <<<"$deploy_function"
grep -q 'aap_demo_generate_system_info' <<<"$redeploy_function"
grep -q 'aap_demo_generate_system_info' <<<"$redeploy_all_function"
grep -q '^/docs/aap-demo-system-info\.md$' "$REPO_ROOT/.gitignore"
grep -q '^/docs/aap-demo-system-info\.json$' "$REPO_ROOT/.gitignore"

echo "✓ system_info_document_contains_expected_details"
