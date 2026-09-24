#!/usr/bin/env bash
# Tests for portal-operator helper functions (no cluster required).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SH="${SCRIPT_DIR}/../addons/portal-operator/deploy.sh"

PASSED=0
FAILED=0

_pass() {
  echo "✓ $1"
  ((PASSED++))
  return 0
}
_fail() {
  echo "✗ $1"
  ((FAILED++))
  return 1
}

# Source deploy.sh — the BASH_SOURCE guard prevents main() from running.
# shellcheck source=../addons/portal-operator/deploy.sh
source "$DEPLOY_SH"

echo "======================================"
echo "portal-operator Helper Function Tests"
echo "======================================"
echo ""

echo "--- _parse_cpu_m ---"

result=$(_parse_cpu_m "8")
[ "$result" = "8000" ] && _pass "_parse_cpu_m '8' → 8000" \
  || _fail "_parse_cpu_m '8' returned '$result', expected 8000"

result=$(_parse_cpu_m "500m")
[ "$result" = "500" ] && _pass "_parse_cpu_m '500m' → 500" \
  || _fail "_parse_cpu_m '500m' returned '$result', expected 500"

result=$(_parse_cpu_m "1000m")
[ "$result" = "1000" ] && _pass "_parse_cpu_m '1000m' → 1000" \
  || _fail "_parse_cpu_m '1000m' returned '$result', expected 1000"

result=$(_parse_cpu_m "1")
[ "$result" = "1000" ] && _pass "_parse_cpu_m '1' → 1000" \
  || _fail "_parse_cpu_m '1' returned '$result', expected 1000"

result=$(_parse_cpu_m "16")
[ "$result" = "16000" ] && _pass "_parse_cpu_m '16' → 16000" \
  || _fail "_parse_cpu_m '16' returned '$result', expected 16000"

result=$(_parse_cpu_m "250m")
[ "$result" = "250" ] && _pass "_parse_cpu_m '250m' → 250" \
  || _fail "_parse_cpu_m '250m' returned '$result', expected 250"

echo ""
echo "Results: ${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ] || exit 1
