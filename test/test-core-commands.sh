#!/usr/bin/env bash
# Test core aap-demo commands: create, destroy, start, stop, status
# Tests command logic without requiring actual CRC cluster

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_DEMO_SH="${SCRIPT_DIR}/../aap-demo.sh"

# Test counters
PASSED=0
FAILED=0
SKIPPED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

_pass() {
  echo -e "${GREEN}✓${NC} $1"
  ((PASSED++))
}

_fail() {
  echo -e "${RED}✗${NC} $1"
  ((FAILED++))
}

_skip() {
  echo -e "${YELLOW}⊘${NC} $1"
  ((SKIPPED++))
}

echo "======================================"
echo "aap-demo Core Commands Test Suite"
echo "======================================"
echo ""

# Test 1: status command execution
echo "Test 1: status command runs successfully"
if output=$("$AAP_DEMO_SH" status 2>&1); then
  if echo "$output" | grep -q "AAP Demo Status"; then
    _pass "status_executes"
  else
    _fail "status_executes - missing status header"
  fi
else
  _fail "status_executes - command failed"
fi

# Test 2: status command format
echo "Test 2: status output includes required sections"
if output=$("$AAP_DEMO_SH" status 2>&1); then
  if echo "$output" | grep -q "Infra:" \
    && echo "$output" | grep -q "Cluster:"; then
    _pass "status_format"
  else
    _fail "status_format - missing required sections"
  fi
else
  _fail "status_format - command failed"
fi

# Test 2a: obsolete ATF command is no longer exposed
echo "Test 2a: obsolete ATF test command is removed"
help_output=$("$AAP_DEMO_SH" help 2>&1)
test_output=$("$AAP_DEMO_SH" test 2>&1 || true)
if ! echo "$help_output" | grep -qE '^    test |aap-demo test' \
  && echo "$test_output" | grep -qi "unknown argument"; then
  _pass "obsolete_atf_command_removed"
else
  _fail "obsolete_atf_command_removed - test command is still available"
fi

# Test 2a2: help is one grouped index and still documents the command surface
echo "Test 2a2: help groups commands without dropping the command surface"
welcome_output=$("$AAP_DEMO_SH" 2>&1 || true)
dash_help=$("$AAP_DEMO_SH" --help 2>&1 || true)
help_ok=true
for section in Cluster AAP Health Addons Other Options Environment Notes Examples Requirements "Available addons"; do
  if ! printf '%s\n' "$help_output" | grep -qx "$section"; then
    echo "  missing section: $section"
    help_ok=false
  fi
done
enable_count=$(printf '%s\n' "$help_output" | grep -c '^  enable ') || true
disable_count=$(printf '%s\n' "$help_output" | grep -c '^  disable ') || true
if [ "$enable_count" -ne 1 ] || [ "$disable_count" -ne 1 ]; then
  echo "  enable/disable should each appear once (enable=$enable_count disable=$disable_count)"
  help_ok=false
fi
if printf '%s\n' "$help_output" | grep -q 'COMMANDS (all infrastructure types)'; then
  echo "  old split COMMANDS heading is still present"
  help_ok=false
fi
for command_line in \
  '^  wire ' '^  trust-ca ' '^  redeploy-all ' '^  keycloak ' '^  v2 ' \
  '^  redhat-status ' '^  must-gather '; do
  if ! printf '%s\n' "$help_output" | grep -q "$command_line"; then
    echo "  missing command: $command_line"
    help_ok=false
  fi
done
for detail in \
  rh-status deploy-all \
  --kubeconfig --context --backend --reset --skip-cache --ai kube-native \
  --no-import local-cache portal-operator ao-pr-testing apme-eap \
  product-demo-satellite AAP_DEMO_ALLOW_REMOTE_KUBECONFIG \
  AAP_PERSISTENT_IMAGE_STORE AAP_IMAGE_STORE_DISK must-gather.local \
  'pull-secret.txt'; do
  if ! printf '%s\n' "$help_output" | grep -q -- "$detail"; then
    echo "  missing detail: $detail"
    help_ok=false
  fi
done
addon_list=$(sed -n 's/^AVAILABLE_ADDONS="\(.*\)"/\1/p' "$AAP_DEMO_SH")
read -r -a addons_expected <<<"$addon_list"
for addon in "${addons_expected[@]}"; do
  if ! printf '%s\n' "$help_output" | grep -Eq "^  ${addon}( |$)"; then
    echo "  addon missing from help: $addon"
    help_ok=false
  fi
done
welcome_addon_sections=$(printf '%s\n' "$welcome_output" | grep -c '^Addons$' || true)
if [ "$welcome_addon_sections" -ne 1 ] \
  || ! printf '%s\n' "$welcome_output" | grep -q "aap-demo help"; then
  echo "  welcome should be one short index that points at aap-demo help"
  help_ok=false
fi
if [ "$dash_help" != "$help_output" ]; then
  echo "  --help and help differ"
  help_ok=false
fi
if [ "$help_ok" = true ]; then
  _pass "help_grouped_by_task"
else
  _fail "help_grouped_by_task"
fi

# Test 2b: persistent storage is shown under the VM section
echo "Test 2b: status places persistent storage under VM"
# cmd_status lives in includes/cmd-status.sh after the includes/ refactor.
STATUS_SH="${SCRIPT_DIR}/../includes/cmd-status.sh"
vm_section_line=$(grep -n '^  echo "VM:"' "$STATUS_SH" | cut -d: -f1)
persistent_status_line=$(grep -n '^  persistent_crio_store_status$' "$STATUS_SH" | cut -d: -f1)
if [ -n "$vm_section_line" ] && [ -n "$persistent_status_line" ] \
  && [ "$persistent_status_line" -gt "$vm_section_line" ] \
  && grep -q '_persistent_crio_store_disk_size' "${SCRIPT_DIR}/../includes/persistent-crio-store.sh"; then
  _pass "status_persistent_storage_under_vm"
else
  _fail "status_persistent_storage_under_vm - persistent storage must be reported in VM section"
fi

# Test 3: stop command - verify it calls crc stop
echo "Test 3: stop command logic"
# Mock crc command to avoid actual stop
export PATH="$SCRIPT_DIR/mocks:$PATH"
mkdir -p "$SCRIPT_DIR/mocks"
cat >"$SCRIPT_DIR/mocks/crc" <<'EOF'
#!/bin/bash
echo "MOCK: crc $*" >&2
case "${1:-}" in
  start) exit "${CRC_START_RC:-0}" ;;
  stop) exit "${CRC_STOP_RC:-0}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SCRIPT_DIR/mocks/crc"

_test_stop() (
  eval "$(sed -n '/^cmd_stop()/,/^}$/p' "$AAP_DEMO_SH")"
  HOME="${SCRIPT_DIR}/mocks/home"
  _err() { echo "ERROR: $*" >&2; }
  cmd_stop
)

if output=$(_test_stop 2>&1); then
  if echo "$output" | grep -q "MOCK: crc stop"; then
    _pass "stop_calls_crc"
  else
    _fail "stop_calls_crc - did not call crc stop"
  fi
else
  _fail "stop_calls_crc - command failed"
fi

# Test 4: start command - verify it calls crc start
# Isolate the start orchestration so lifecycle tests cannot resume the real demo.
_test_start() (
  eval "$(sed -n '/^cmd_start()/,/^}$/p' "$AAP_DEMO_SH")"
  SCRIPT_DIR="${SCRIPT_DIR}/.."
  KUBECONFIG="${SCRIPT_DIR}/test/mocks/kubeconfig"
  AAP_DEMO_CRC_CREATE_SCRIPT="${AAP_DEMO_CRC_CREATE_SCRIPT:-${SCRIPT_DIR}/test/mocks/start-coredns.sh}"
  _addons_list() { :; }
  _start_crc_cluster() {
    crc start || { _err "Failed to start the CRC cluster"; return 1; }
  }
  _err() { echo "ERROR: $*" >&2; }
  setup_kubeconfig() { :; }
  aap_demo_start_storage() { :; }
  aap_demo_start_wait() { :; }
  kubectl() { :; }
  _recover_aap_catalog_after_start() { :; }
  aap_demo_resume_demo() { :; }
  cmd_status() { :; }
  cmd_start
)
printf 'configure_coredns() { :; }\n' >"$SCRIPT_DIR/mocks/start-coredns.sh"

echo "Test 4: start command logic"
if output=$(_test_start 2>&1); then
  if echo "$output" | grep -q "MOCK: crc start" \
    && ! echo "$output" | grep -q "WARNING: No cluster exists"; then
    _pass "start_calls_crc"
  else
    _fail "start_calls_crc - did not call crc start or emitted false missing-cluster warning"
  fi
else
  _fail "start_calls_crc - command failed"
fi

echo "Test 4c: CRC start failure returns nonzero"
if output=$(CRC_START_RC=42 _test_start 2>&1); then
  _fail "crc_start_failure_returns_nonzero"
elif echo "$output" | grep -q 'Failed to start the CRC cluster'; then
  _pass "crc_start_failure_returns_nonzero"
else
  _fail "crc_start_failure_returns_nonzero - missing actionable error"
fi

echo "Test 4d: CRC stop failure returns nonzero"
if output=$(CRC_STOP_RC=42 _test_stop 2>&1); then
  _fail "crc_stop_failure_returns_nonzero"
elif echo "$output" | grep -q 'Failed to stop the CRC cluster'; then
  _pass "crc_stop_failure_returns_nonzero"
else
  _fail "crc_stop_failure_returns_nonzero - missing actionable error"
fi

cat >"$SCRIPT_DIR/mocks/failing-crc-create.sh" <<'EOF'
#!/usr/bin/env bash
configure_coredns() {
  return 1
}
EOF
chmod +x "$SCRIPT_DIR/mocks/failing-crc-create.sh"

echo "Test 4e: CoreDNS recovery failure returns nonzero"
if output=$(AAP_DEMO_CRC_CREATE_SCRIPT="$SCRIPT_DIR/mocks/failing-crc-create.sh" \
  _test_start 2>&1); then
  _fail "coredns_recovery_failure_returns_nonzero"
elif echo "$output" | grep -q 'Failed to restore CoreDNS after cluster start'; then
  _pass "coredns_recovery_failure_returns_nonzero"
else
  _fail "coredns_recovery_failure_returns_nonzero - missing actionable error"
fi

echo "Test 4b: required CRC lifecycle failures propagate"
start_cluster_function=$(sed -n '/^_start_crc_cluster()/,/^}$/p' "$AAP_DEMO_SH")
stop_function=$(sed -n '/^cmd_stop()/,/^}$/p' "$AAP_DEMO_SH")
if echo "$start_cluster_function" | grep -q 'if ! crc start' \
  && echo "$stop_function" | grep -q 'if ! crc stop'; then
  _pass "crc_lifecycle_failures_propagate"
else
  _fail "crc_lifecycle_failures_propagate - start or stop still suppresses CRC failure"
fi

echo "Test 4a: start waits for the AAP catalog"
start_function=$(sed -n '/^cmd_start()/,/^}$/p' "$AAP_DEMO_SH")
catalog_recovery_function=$(sed -n '/^_recover_aap_catalog_after_start()/,/^}$/p' "$AAP_DEMO_SH")
if echo "$start_function" | grep -q '_recover_aap_catalog_after_start' \
  && echo "$catalog_recovery_function" | grep -q 'wait_for_catalog_ready' \
  && echo "$catalog_recovery_function" | grep -q 'deployment/catalog-operator -n olm'; then
  _pass "start_waits_for_aap_catalog"
else
  _fail "start_waits_for_aap_catalog - catalog recovery is not wired into start"
fi

# Test 5: destroy command - verify confirmation prompt in interactive mode
echo "Test 5: destroy shows warning without QUIET"
# Don't actually run destroy - just verify the warning message exists in the function
if grep -q "WARNING.*DELETE" "$AAP_DEMO_SH"; then
  _pass "destroy_warning"
else
  _fail "destroy_warning - warning message not found in script"
fi

# Test 6: destroy command - verify it would call crc delete
echo "Test 6: destroy calls crc delete"
# Verify the function contains crc delete command
if grep -q "crc delete" "$AAP_DEMO_SH"; then
  _pass "destroy_calls_crc_delete"
else
  _fail "destroy_calls_crc_delete - crc delete not found in destroy function"
fi

# Test 7: destroy asks about caching before showing the destructive message
echo "Test 7: destroy asks about caching before the destructive message"
cache_prompt_line=$(grep -n '^  _maybe_save_local_cache_before_destroy$' "$AAP_DEMO_SH" | cut -d: -f1)
destroy_message_line=$(grep -n 'aap-demo destroy.*Deleting CRC cluster' "$AAP_DEMO_SH" | cut -d: -f1)
if [ -n "$cache_prompt_line" ] && [ -n "$destroy_message_line" ] \
  && [ "$cache_prompt_line" -lt "$destroy_message_line" ]; then
  _pass "destroy_cache_prompt_order"
else
  _fail "destroy_cache_prompt_order - cache prompt must precede destroy message"
fi

# Test 7c: a cache save failure must not block destroy
echo "Test 7c: destroy continues when optional cache save fails"
cache_function_start=$(grep -n '^_maybe_save_local_cache_before_destroy()' "$AAP_DEMO_SH" | cut -d: -f1)
cache_function_end=$(grep -n '^cmd_destroy()' "$AAP_DEMO_SH" | cut -d: -f1)
cache_function=$(sed -n "${cache_function_start},$((cache_function_end - 1))p" "$AAP_DEMO_SH")
if echo "$cache_function" | grep -q 'refusing to delete the cluster'; then
  _fail "destroy_cache_failure_nonblocking - cache failure must not refuse deletion"
else
  _pass "destroy_cache_failure_nonblocking"
fi

# Test 7d: rewrite after Subscription exists, before waiting for CSV
echo "Test 7d: cache references are rewritten as OLM creates workloads"
subscription_line=$(grep -n 'config/olm/subscription.yaml' "$AAP_DEMO_SH" | cut -d: -f1 | head -1)
csv_wait_line=$(grep -n '^  # Wait for CSV$' "$AAP_DEMO_SH" | cut -d: -f1 | head -1)
rewrite_after_subscription=$(awk -v start="$subscription_line" -v end="$csv_wait_line" \
  'NR > start && NR < end && /_rewrite_local_cache_refs/ {print NR; exit}' "$AAP_DEMO_SH")
if [ -n "$rewrite_after_subscription" ]; then
  _pass "rewrite_cache_refs_during_olm_creation"
else
  _fail "rewrite_cache_refs_during_olm_creation - rewrite must run after subscription and before CSV wait"
fi

# Test 7b: destroy supports an explicit cache bypass
echo "Test 7b: destroy supports --skip-cache"
if grep -q -- '--skip-cache' "$AAP_DEMO_SH"; then
  _pass "destroy_skip_cache"
else
  _fail "destroy_skip_cache - flag not found in script"
fi

# Test 8: create command - verify it calls crc-create.sh
echo "Test 8: create command delegates to crc-create.sh"
# Verify create function sources crc-create.sh
if grep -q 'includes/crc-create.sh' "$AAP_DEMO_SH"; then
  _pass "create_calls_script"
else
  _fail "create_calls_script - crc-create.sh not referenced in create function"
fi

# Test 10: addon purge options are accepted and forwarded
echo "Test 10: disable forwards addon purge options"
if grep -q -- '--purge-data' "$AAP_DEMO_SH" \
  && grep -q 'if ! bash "\$addon_dir/deploy.sh" --delete "\$@"' "$AAP_DEMO_SH" \
  && grep -q '_err "Failed to disable addon: \$addon"' "$AAP_DEMO_SH"; then
  _pass "disable_forwards_purge_data"
else
  _fail "disable_forwards_purge_data - purge forwarding or failure propagation is missing"
fi

# Test 9: create command - verify OLM addon is enabled after cluster creation
echo "Test 9: create enables OLM addon"
# Verify create function calls OLM deploy
if grep -q 'addons/olm/deploy.sh' "$AAP_DEMO_SH"; then
  _pass "create_enables_olm"
else
  _fail "create_enables_olm - OLM deploy not referenced in create function"
fi

# Test 10a: standard deploy enables Automation Orchestrator
echo "Test 10a: deploy enables Automation Orchestrator"
deploy_function=$(sed -n '/^cmd_deploy()/,/^# -----------------------------------------------------------------------------$/p' "$AAP_DEMO_SH")
standard_ao_function=$(sed -n '/^_enable_standard_ao()/,/^}$/p' "$AAP_DEMO_SH")
if [ "$(echo "$deploy_function" | grep -c '_enable_standard_ao')" -eq 2 ] \
  && echo "$standard_ao_function" | grep -q 'cmd_enable ao'; then
  _pass "deploy_enables_standard_ao"
else
  _fail "deploy_enables_standard_ao - fresh and existing AAP paths must enable AO"
fi

# Test 10b: gateway security reconciliation includes supplemental group 0
echo "Test 10b: deploy reconciles gateway security context"
gateway_patch_function=$(sed -n '/^_patch_gateway_capability()/,/^}$/p' "$AAP_DEMO_SH")
if echo "$gateway_patch_function" | grep -q '"supplementalGroups":\[0\]' \
  && echo "$gateway_patch_function" | grep -q '"NET_BIND_SERVICE"' \
  && echo "$gateway_patch_function" | grep -q '"type":"Recreate"' \
  && [ "$(echo "$deploy_function" | grep -c '_patch_gateway_capability')" -eq 1 ]; then
  _pass "deploy_reconciles_gateway_security_context"
else
  _fail "deploy_reconciles_gateway_security_context - existing and fresh deployments must receive both settings"
fi

# Test 11: persistent CRI-O storage is opt-in and has a safe OCI fallback
echo "Test 11: persistent CRI-O storage hooks"
if grep -q 'source "${SCRIPT_DIR}/includes/persistent-crio-store.sh"' "$AAP_DEMO_SH" \
  && grep -q 'persistent_crio_store_prepare_or_fallback' "$AAP_DEMO_SH" \
  && grep -q 'persistent_crio_store_detach' "$AAP_DEMO_SH" \
  && grep -q -- '--subdriver qcow2' "${SCRIPT_DIR}/../includes/persistent-crio-store.sh" \
  && AAP_PERSISTENT_IMAGE_STORE=false bash -c \
    "source '${SCRIPT_DIR}/../includes/persistent-crio-store.sh'; persistent_crio_store_prepare; persistent_crio_store_detach"; then
  _pass "persistent_crio_store_opt_in"
else
  _fail "persistent_crio_store_opt_in - helper wiring or disabled no-op is broken"
fi

# Test 12: persistent storage is detached before CRC deletion
echo "Test 12: persistent CRI-O storage detach order"
detach_line=$(grep -n 'persistent_crio_store_detach' "$AAP_DEMO_SH" | tail -1 | cut -d: -f1)
delete_line=$(grep -n 'if _crc_delete_cluster; then' "$AAP_DEMO_SH" | tail -1 | cut -d: -f1)
if [ -n "$detach_line" ] && [ -n "$delete_line" ] && [ "$detach_line" -lt "$delete_line" ]; then
  _pass "persistent_crio_store_detach_order"
else
  _fail "persistent_crio_store_detach_order - disk must detach before crc delete"
fi

# Cleanup mocks
rm -rf "$SCRIPT_DIR/mocks"

# Summary
echo ""
echo "======================================"
echo "Test Results"
echo "======================================"
echo -e "${GREEN}Passed:${NC}  $PASSED"
echo -e "${RED}Failed:${NC}  $FAILED"
echo -e "${YELLOW}Skipped:${NC} $SKIPPED"
echo "======================================"

if [ "$FAILED" -eq 0 ]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}Some tests failed${NC}"
  exit 1
fi
