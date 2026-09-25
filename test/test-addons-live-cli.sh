#!/usr/bin/env bash
# Offline tests for the live add-on smoke-test harness.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${SCRIPT_DIR}/test-addons-live.sh"

pass=0
fail=0

assert_contains() {
  local output="$1" expected="$2" name="$3"
  if grep -Fq -- "$expected" <<<"$output"; then
    printf 'PASS: %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s (missing: %s)\n' "$name" "$expected" >&2
    fail=$((fail + 1))
  fi
}

output=$("$HARNESS" --dry-run)
assert_contains "$output" "DRY-RUN: mcp-server" "lists MCP"
assert_contains "$output" "DRY-RUN: portal" "lists portal"
assert_contains "$output" "DRY-RUN: portal-operator" "lists portal operator"
assert_contains "$output" "DRY-RUN: setup-pah" "lists PAH"
assert_contains "$output" "DRY-RUN: ao" "lists AO"
assert_contains "$output" "DRY-RUN: apme-eap" "lists APME"
assert_contains "$output" "DRY-RUN: local-cache" "lists local cache"
assert_contains "$output" "DRY-RUN: product-demos" "lists product demos"
assert_contains "$output" "DRY-RUN: product-demo-satellite" "lists satellite demos"
assert_contains "$output" "DRY-RUN: opa" "lists OPA"
assert_contains "$output" "DRY-RUN: ollama" "lists Ollama"

output=$("$HARNESS" --dry-run --addon ao --low-resource)
assert_contains "$output" "DRY-RUN: ao" "selects one add-on"
assert_contains "$output" "AO_LOW_RESOURCE=1" "passes low-resource setting"
if grep -Fq "DRY-RUN: mcp-server" <<<"$output"; then
  printf 'FAIL: --addon selected unrelated add-on\n' >&2
  fail=$((fail + 1))
else
  printf 'PASS: --addon filters inventory\n'
  pass=$((pass + 1))
fi

if "$HARNESS" --addon ao >/dev/null 2>&1; then
  printf 'FAIL: live mode did not require --live\n' >&2
  fail=$((fail + 1))
else
  printf 'PASS: live mode requires explicit --live\n'
  pass=$((pass + 1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
test "$fail" -eq 0
