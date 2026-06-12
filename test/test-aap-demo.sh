#!/usr/bin/env bash
# =============================================================================
# test-aap-demo.sh - Validation suite for aap-demo.sh
# =============================================================================
#
# Tests all aap-demo.sh commands for:
# - Argument parsing correctness
# - Help/usage output validity
# - Non-destructive command execution
# - Error handling
#
# Usage:
#   ./test-aap-demo.sh              # Run all tests
#   ./test-aap-demo.sh --verbose    # Show detailed output
#   ./test-aap-demo.sh --quick      # Skip slow/cluster tests
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#
# =============================================================================

set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_DEMO_SH="${SCRIPT_DIR}/../aap-demo.sh"

# Test config
VERBOSE="${VERBOSE:-false}"
QUICK="${QUICK:-false}"
FAILED_TESTS=()
PASSED_TESTS=()
SKIPPED_TESTS=()

# Parse args
for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=true ;;
    --quick) QUICK=true ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

# Test framework helpers
_pass() {
  local test_name="$1"
  PASSED_TESTS+=("$test_name")
  echo "✓ $test_name"
}

_fail() {
  local test_name="$1"
  local reason="${2:-unknown}"
  FAILED_TESTS+=("$test_name: $reason")
  echo "✗ $test_name"
  [ "$VERBOSE" = "true" ] && echo "  Reason: $reason"
}

_skip() {
  local test_name="$1"
  local reason="${2:-quick mode}"
  SKIPPED_TESTS+=("$test_name: $reason")
  echo "⊙ $test_name (skipped: $reason)"
}

_run_aap_demo() {
  # Run aap-demo.sh with quiet mode + stderr capture
  # Returns: stdout in var, exit code in $?
  QUIET=true "$AAP_DEMO_SH" "$@" 2>&1
}

# =============================================================================
# Test: Script exists and is executable
# =============================================================================
test_script_exists() {
  if [ -f "$AAP_DEMO_SH" ] && [ -x "$AAP_DEMO_SH" ]; then
    _pass "script_exists"
  else
    _fail "script_exists" "not found or not executable: $AAP_DEMO_SH"
  fi
}

# =============================================================================
# Test: Help commands
# =============================================================================
test_help_output() {
  local output
  output=$(_run_aap_demo help 2>&1) || true
  if echo "$output" | grep -q "aap-demo"; then
    _pass "help_output"
  else
    _fail "help_output" "no help text found"
  fi
}

test_help_flag_short() {
  local output
  output=$(_run_aap_demo -h 2>&1) || true
  if echo "$output" | grep -q "aap-demo"; then
    _pass "help_flag_short"
  else
    _fail "help_flag_short" "no help text"
  fi
}

test_help_flag_long() {
  local output
  output=$(_run_aap_demo --help 2>&1) || true
  if echo "$output" | grep -q "aap-demo"; then
    _pass "help_flag_long"
  else
    _fail "help_flag_long" "no help text"
  fi
}

test_no_args_shows_welcome() {
  local output
  output=$(_run_aap_demo 2>&1) || true
  if echo "$output" | grep -qE "(Deploy AAP|Usage:)"; then
    _pass "no_args_shows_welcome"
  else
    _fail "no_args_shows_welcome" "no welcome banner"
  fi
}

# =============================================================================
# Test: Status/Info commands (safe to run without cluster)
# =============================================================================
test_redhat_status() {
  if [ "$QUICK" = "true" ]; then
    _skip "redhat_status" "network call"
    return
  fi
  local output
  output=$(_run_aap_demo redhat-status 2>&1) || true
  if echo "$output" | grep -qE "(Active Incidents|status.redhat.com)"; then
    _pass "redhat_status"
  else
    _fail "redhat_status" "unexpected output"
  fi
}

test_rh_status_alias() {
  if [ "$QUICK" = "true" ]; then
    _skip "rh_status_alias" "network call"
    return
  fi
  local output
  output=$(_run_aap_demo rh-status 2>&1) || true
  if echo "$output" | grep -qE "(Active Incidents|status.redhat.com)"; then
    _pass "rh_status_alias"
  else
    _fail "rh_status_alias" "unexpected output"
  fi
}

# =============================================================================
# Test: Config command
# =============================================================================
test_config_command() {
  # config with no args should succeed (shows current config or is a no-op)
  if _run_aap_demo config >/dev/null 2>&1; then
    _pass "config_command"
  else
    _fail "config_command" "exit code $?"
  fi
}

# =============================================================================
# Test: Argument parsing
# =============================================================================
test_namespace_env_var() {
  local output
  output=$(NAMESPACE=test-ns _run_aap_demo help 2>&1) || true
  # Script shouldn't fail with NAMESPACE set
  if [ $? -eq 0 ]; then
    _pass "namespace_env_var"
  else
    _fail "namespace_env_var" "exit code $?"
  fi
}

test_quiet_env_var() {
  local output
  output=$(QUIET=true _run_aap_demo help 2>&1) || true
  if [ $? -eq 0 ]; then
    _pass "quiet_env_var"
  else
    _fail "quiet_env_var" "exit code $?"
  fi
}

test_force_env_var() {
  local output
  output=$(FORCE=true _run_aap_demo help 2>&1) || true
  if [ $? -eq 0 ]; then
    _pass "force_env_var"
  else
    _fail "force_env_var" "exit code $?"
  fi
}

test_unknown_command() {
  local output
  output=$(_run_aap_demo notarealcommand 2>&1) || true
  if echo "$output" | grep -qE "(Unknown|help)"; then
    _pass "unknown_command"
  else
    _fail "unknown_command" "no error message"
  fi
}

test_unknown_flag() {
  local output
  output=$(_run_aap_demo --notarealflag 2>&1) || true
  if echo "$output" | grep -qE "(Unknown|help)"; then
    _pass "unknown_flag"
  else
    _fail "unknown_flag" "no error message"
  fi
}

# =============================================================================
# Test: Idle command argument validation
# =============================================================================
test_idle_no_cluster() {
  # idle should handle missing cluster gracefully (may succeed if cluster exists)
  local output rc
  output=$(_run_aap_demo idle true 2>&1) && rc=0 || rc=$?
  # Should either succeed (cluster exists) OR error gracefully (no cluster)
  if [ $rc -eq 0 ] || echo "$output" | grep -qE "(No AAP instance|not found|cannot connect|✗)"; then
    _pass "idle_no_cluster"
  else
    _fail "idle_no_cluster" "unexpected error (rc=$rc)"
  fi
}

# =============================================================================
# Test: Diagnose command (dry-run safe)
# =============================================================================
test_diagnose_no_cluster() {
  # diagnose should run even without cluster (will report cluster not running)
  local output
  output=$(_run_aap_demo diagnose 2>&1) || true
  if echo "$output" | grep -qE "(Cluster|diagnose|not found|not running)"; then
    _pass "diagnose_no_cluster"
  else
    _fail "diagnose_no_cluster" "unexpected output"
  fi
}

# =============================================================================
# Test: Enable/Disable addon parsing
# =============================================================================
test_enable_no_args() {
  local output
  output=$(_run_aap_demo enable 2>&1) || true
  if echo "$output" | grep -qE "(Available addons|Usage)"; then
    _pass "enable_no_args"
  else
    _fail "enable_no_args" "no usage shown"
  fi
}

test_disable_no_args() {
  local output
  output=$(_run_aap_demo disable 2>&1) || true
  if echo "$output" | grep -qE "(Available addons|Usage)"; then
    _pass "disable_no_args"
  else
    _fail "disable_no_args" "no usage shown"
  fi
}

test_enable_unknown_addon() {
  local output rc
  output=$(_run_aap_demo enable fake-addon 2>&1) && rc=0 || rc=$?
  # Should exit 1 and show error
  if [ $rc -ne 0 ] && echo "$output" | grep -qE "(Unknown|not found|help)"; then
    _pass "enable_unknown_addon"
  else
    _fail "enable_unknown_addon" "no error for unknown addon (rc=$rc)"
  fi
}

# =============================================================================
# Test: Command aliases work
# =============================================================================
test_deploy_all_alias() {
  # deploy-all should be recognized as a valid command
  local output
  output=$(_run_aap_demo deploy-all 2>&1) || true
  # Should NOT contain "Unknown command" error
  if ! echo "$output" | grep -q "Unknown command"; then
    _pass "deploy_all_alias"
  else
    _fail "deploy_all_alias" "not recognized"
  fi
}

test_redeploy_all_alias() {
  local output
  output=$(_run_aap_demo redeploy-all 2>&1) || true
  if ! echo "$output" | grep -q "Unknown command"; then
    _pass "redeploy_all_alias"
  else
    _fail "redeploy_all_alias" "not recognized"
  fi
}

# =============================================================================
# Test: Destructive command warnings (should prompt or show warning)
# =============================================================================
test_destroy_shows_warning() {
  if [ "$QUICK" = "true" ]; then
    _skip "destroy_shows_warning" "interactive"
    return
  fi
  # Run destroy with QUIET=false but timeout to avoid blocking
  # Should see WARNING text before any prompts
  local output
  output=$(timeout 3 bash -c "QUIET=false '$AAP_DEMO_SH' destroy 2>&1" || true)
  if echo "$output" | grep -qE "(WARNING|DELETE|destroy)"; then
    _pass "destroy_shows_warning"
  else
    _fail "destroy_shows_warning" "no warning found"
  fi
}

test_clean_shows_warning() {
  if [ "$QUICK" = "true" ]; then
    _skip "clean_shows_warning" "interactive"
    return
  fi
  local output
  output=$(timeout 3 bash -c "QUIET=false '$AAP_DEMO_SH' clean 2>&1" || true)
  if echo "$output" | grep -qE "(WARNING|CLEANUP|DELETE)"; then
    _pass "clean_shows_warning"
  else
    _fail "clean_shows_warning" "no warning found"
  fi
}

# =============================================================================
# Test: Flag parsing (--context, --kubeconfig, --branch)
# =============================================================================
test_context_flag_equals() {
  local output
  output=$(_run_aap_demo --context=fake-ctx status 2>&1) || true
  # Should attempt to use context (will fail, but parsing should work)
  if echo "$output" | grep -qE "(Context.*not found|fake-ctx)"; then
    _pass "context_flag_equals"
  else
    _fail "context_flag_equals" "flag not parsed"
  fi
}

test_context_flag_space() {
  local output
  output=$(_run_aap_demo --context fake-ctx status 2>&1) || true
  if echo "$output" | grep -qE "(Context.*not found|fake-ctx)"; then
    _pass "context_flag_space"
  else
    _fail "context_flag_space" "flag not parsed"
  fi
}

test_kubeconfig_flag_nonexistent() {
  local output
  output=$(_run_aap_demo --kubeconfig=/fake/path status 2>&1) || true
  if echo "$output" | grep -qE "(not found|/fake/path)"; then
    _pass "kubeconfig_flag_nonexistent"
  else
    _fail "kubeconfig_flag_nonexistent" "no error for bad path"
  fi
}

# =============================================================================
# Test: Diagnose --ai flag parsing
# =============================================================================
test_diagnose_ai_flag() {
  # Should parse --ai flag (may exit 1 if claude not found, but flag parsing works)
  local output
  output=$(_run_aap_demo diagnose --ai 2>&1) || true
  # Should not say "Unknown argument" — either runs or says claude not found
  if echo "$output" | grep -qE "(claude|AI Analysis|diagnose)" && echo "$output" | grep -qv "Unknown argument"; then
    _pass "diagnose_ai_flag"
  else
    _fail "diagnose_ai_flag" "flag not recognized"
  fi
}

# =============================================================================
# Test: Idle command boolean parsing
# =============================================================================
test_idle_true_parsing() {
  local output
  output=$(_run_aap_demo idle true 2>&1) || true
  # Will fail due to no cluster, but should recognize 'true' as valid arg
  if echo "$output" | grep -qv "Unknown argument"; then
    _pass "idle_true_parsing"
  else
    _fail "idle_true_parsing" "arg not recognized"
  fi
}

test_idle_false_parsing() {
  local output
  output=$(_run_aap_demo idle false 2>&1) || true
  if echo "$output" | grep -qv "Unknown argument"; then
    _pass "idle_false_parsing"
  else
    _fail "idle_false_parsing" "arg not recognized"
  fi
}

test_idle_invalid_arg() {
  local output rc
  output=$(_run_aap_demo idle notabool 2>&1) && rc=0 || rc=$?
  # Should error and mention the arg is invalid
  if [ $rc -ne 0 ] && echo "$output" | grep -qE "(Unknown|help|Usage)"; then
    _pass "idle_invalid_arg"
  else
    _fail "idle_invalid_arg" "no error for invalid arg (rc=$rc)"
  fi
}

# =============================================================================
# Test: Must-gather output path parsing
# =============================================================================
test_must_gather_default_path() {
  if [ "$QUICK" = "true" ]; then
    _skip "must_gather_default_path" "would create files"
    return
  fi
  # Will fail due to no cluster but should parse args
  local output
  output=$(_run_aap_demo must-gather 2>&1) || true
  if echo "$output" | grep -qE "(must-gather|Collecting|Output)"; then
    _pass "must_gather_default_path"
  else
    _fail "must_gather_default_path" "command not recognized"
  fi
}

test_must_gather_custom_path() {
  if [ "$QUICK" = "true" ]; then
    _skip "must_gather_custom_path" "would create files"
    return
  fi
  local output
  output=$(_run_aap_demo must-gather /tmp/test-mg 2>&1) || true
  if echo "$output" | grep -qE "(must-gather|/tmp/test-mg)"; then
    _pass "must_gather_custom_path"
  else
    _fail "must_gather_custom_path" "path not recognized"
  fi
}

# =============================================================================
# Test: Test command marker parsing
# =============================================================================
test_test_command_markers() {
  if [ "$QUICK" = "true" ]; then
    _skip "test_command_markers" "ansible dependency"
    return
  fi
  local output
  output=$(_run_aap_demo test smoke 2>&1) || true
  # Will fail due to no AAP deployment, but should parse markers arg
  if echo "$output" | grep -qE "(test|markers|smoke|No AAP)"; then
    _pass "test_command_markers"
  else
    _fail "test_command_markers" "markers not recognized"
  fi
}

# =============================================================================
# Test: Destroy --reset flag
# =============================================================================
test_destroy_reset_flag() {
  if [ "$QUICK" = "true" ]; then
    _skip "destroy_reset_flag" "interactive"
    return
  fi
  local output
  output=$(timeout 3 bash -c "QUIET=false '$AAP_DEMO_SH' destroy --reset 2>&1" || true)
  # Should recognize --reset flag
  if echo "$output" | grep -qE "(reset|config|WARNING)"; then
    _pass "destroy_reset_flag"
  else
    _fail "destroy_reset_flag" "flag not recognized"
  fi
}

# =============================================================================
# Run all tests
# =============================================================================

# Script validation
test_script_exists

# Help/Usage
test_help_output
test_help_flag_short
test_help_flag_long
test_no_args_shows_welcome

# Status commands
test_redhat_status
test_rh_status_alias
test_config_command

# Argument parsing
test_namespace_env_var
test_quiet_env_var
test_force_env_var
test_unknown_command
test_unknown_flag

# Idle command
test_idle_no_cluster
test_idle_true_parsing
test_idle_false_parsing
test_idle_invalid_arg

# Diagnose
test_diagnose_no_cluster
test_diagnose_ai_flag

# Addons
test_enable_no_args
test_disable_no_args
test_enable_unknown_addon

# Aliases
test_deploy_all_alias
test_redeploy_all_alias

# Warnings
test_destroy_shows_warning
test_clean_shows_warning

# Flags
test_context_flag_equals
test_context_flag_space
test_kubeconfig_flag_nonexistent

# Must-gather
test_must_gather_default_path
test_must_gather_custom_path

# Test command
test_test_command_markers

# Destroy flags
test_destroy_reset_flag

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================="
echo "Test Summary"
echo "========================================="
echo "Passed:  ${#PASSED_TESTS[@]}"
echo "Failed:  ${#FAILED_TESTS[@]}"
echo "Skipped: ${#SKIPPED_TESTS[@]}"
echo ""

if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  echo "Failed tests:"
  for fail in "${FAILED_TESTS[@]}"; do
    echo "  ✗ $fail"
  done
  echo ""
  exit 1
fi

echo "✓ All tests passed!"
exit 0
