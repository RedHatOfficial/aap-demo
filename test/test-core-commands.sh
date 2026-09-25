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

# Test 2b: persistent storage is shown under the VM section
echo "Test 2b: status places persistent storage under VM"
vm_section_line=$(grep -n '^  echo "VM:"' "$AAP_DEMO_SH" | cut -d: -f1)
persistent_status_line=$(grep -n '^  persistent_crio_store_status$' "$AAP_DEMO_SH" | cut -d: -f1)
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
exit 0
EOF
chmod +x "$SCRIPT_DIR/mocks/crc"

if output=$(QUIET=true "$AAP_DEMO_SH" stop 2>&1); then
  if echo "$output" | grep -q "MOCK: crc stop"; then
    _pass "stop_calls_crc"
  else
    _fail "stop_calls_crc - did not call crc stop"
  fi
else
  _fail "stop_calls_crc - command failed"
fi

# Test 4: start command - verify it calls crc start
echo "Test 4: start command logic"
if output=$(QUIET=true "$AAP_DEMO_SH" start 2>&1); then
  if echo "$output" | grep -q "MOCK: crc start"; then
    _pass "start_calls_crc"
  else
    _fail "start_calls_crc - did not call crc start"
  fi
else
  _fail "start_calls_crc - command failed"
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
  && grep -q 'bash "\$addon_dir/deploy.sh" --delete "\$@"' "$AAP_DEMO_SH"; then
  _pass "disable_forwards_purge_data"
else
  _fail "disable_forwards_purge_data - purge option parsing or forwarding is missing"
fi

# Test 9: create command - verify OLM addon is enabled after cluster creation
echo "Test 9: create enables OLM addon"
# Verify create function calls OLM deploy
if grep -q 'addons/olm/deploy.sh' "$AAP_DEMO_SH"; then
  _pass "create_enables_olm"
else
  _fail "create_enables_olm - OLM deploy not referenced in create function"
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
delete_line=$(grep -n 'crc delete' "$AAP_DEMO_SH" | tail -1 | cut -d: -f1)
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
