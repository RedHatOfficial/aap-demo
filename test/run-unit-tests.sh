#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0
TOTAL=0

run_test() {
  local runner="$1"
  local test_file="$2"

  TOTAL=$((TOTAL + 1))
  printf '\n==> %s\n' "$(basename "$test_file")"
  # Per-test timeout so a single hanging test cannot stall the whole suite.
  # AAP_DEMO_TEST_TIMEOUT overrides the default (seconds).
  if ! timeout "${AAP_DEMO_TEST_TIMEOUT:-120}" "$runner" "$test_file"; then
    FAILED=$((FAILED + 1))
    echo "  FAILED or timed out: $(basename "$test_file")" >&2
  fi
}

for test_file in "$TEST_DIR"/test-*.sh; do
  case "$(basename "$test_file")" in
    # Live tests require a running cluster with the addon deployed.
    test-live-idempotency.sh | test-keycloak-live.sh) continue ;;
  esac
  run_test bash "$test_file"
done

for test_file in "$TEST_DIR"/test-*.py; do
  case "$(basename "$test_file")" in
    test-ao-live-smoke.py) continue ;;
  esac
  run_test python3 "$test_file"
done

echo ""
echo "Unit test files: $((TOTAL - FAILED)) passed, $FAILED failed, $TOTAL total"
[ "$FAILED" -eq 0 ]
