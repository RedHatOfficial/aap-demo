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
# deploy.sh enables errexit for production execution; this helper test records
# all assertions so a failing expectation does not stop later checks.
set +e

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
echo "--- _ollama_cpu_reservation_m ---"

result=$(_ollama_cpu_reservation_m "200m" 1)
[ "$result" = "200" ] && _pass "one 200m Ollama replica reserves 200m" \
  || _fail "one 200m Ollama replica reserved '$result', expected 200"

result=$(_ollama_cpu_reservation_m "200m" 2)
[ "$result" = "400" ] && _pass "two 200m Ollama replicas reserve 400m" \
  || _fail "two 200m Ollama replicas reserved '$result', expected 400"

result=$(_ollama_cpu_reservation_m "1" 1)
[ "$result" = "1000" ] && _pass "one 1-core Ollama replica reserves 1000m" \
  || _fail "one 1-core Ollama replica reserved '$result', expected 1000"

echo ""
echo "--- apply_portal manifest ---"

# Capture the manifest sent to kubectl so the portal CR shape is tested without
# requiring a live cluster.
kubectl() {
  if [ "${1:-}" = "apply" ] && [ "${2:-}" = "-f" ] && [ "${3:-}" = "-" ]; then
    cat
  fi
}

AAP_ROUTE="aap.apps.127.0.0.1.nip.io"
portal_manifest=$(apply_portal)
if printf '%s\n' "$portal_manifest" | rg -q '^    caCertificates:$'; then
  _pass "portal CA configuration is under deployment"
else
  _fail "portal CA configuration is not under deployment"
fi
if printf '%s\n' "$portal_manifest" | rg -q '^    route:$'; then
  _pass "portal route configuration is under deployment"
else
  _fail "portal route configuration is not under deployment"
fi
if printf '%s\n' "$portal_manifest" | rg -q '^  deployment:$'; then
  _pass "portal manifest includes deployment configuration"
else
  _fail "portal manifest is missing deployment configuration"
fi
if printf '%s\n' "$portal_manifest" | rg -q '^  backstage:$'; then
  _fail "portal manifest still uses the obsolete backstage block"
else
  _pass "portal manifest omits obsolete backstage block"
fi

echo ""
echo "Results: ${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ] || exit 1
