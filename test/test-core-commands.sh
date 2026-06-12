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
  if echo "$output" | grep -q "Infra:" && \
     echo "$output" | grep -q "Cluster:"; then
    _pass "status_format"
  else
    _fail "status_format - missing required sections"
  fi
else
  _fail "status_format - command failed"
fi

# Test 3: stop command - verify it calls crc stop
echo "Test 3: stop command logic"
# Mock crc command to avoid actual stop
export PATH="$SCRIPT_DIR/mocks:$PATH"
mkdir -p "$SCRIPT_DIR/mocks"
cat > "$SCRIPT_DIR/mocks/crc" << 'EOF'
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

# Test 7: create command - verify it calls crc-create.sh
echo "Test 7: create command delegates to crc-create.sh"
# Verify create function sources crc-create.sh
if grep -q 'includes/crc-create.sh' "$AAP_DEMO_SH"; then
  _pass "create_calls_script"
else
  _fail "create_calls_script - crc-create.sh not referenced in create function"
fi

# Test 8: create command - verify OLM addon is enabled after cluster creation
echo "Test 8: create enables OLM addon"
# Verify create function calls OLM deploy
if grep -q 'addons/olm/deploy.sh' "$AAP_DEMO_SH"; then
  _pass "create_enables_olm"
else
  _fail "create_enables_olm - OLM deploy not referenced in create function"
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
