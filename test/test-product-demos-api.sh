#!/usr/bin/env bash
# Regression tests for product-demos AAP API readiness and subscription checks.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_SH="${REPO_ROOT}/addons/product-demos-base/lib.sh"
DEPLOY_SH="${REPO_ROOT}/addons/product-demos-base/deploy.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for these tests" >&2
  exit 1
fi

# shellcheck source=addons/product-demos-base/lib.sh
source "$LIB_SH"

export AAP_USERNAME="admin"
export AAP_PASSWORD=""
export AAP_API="https://aap.example.test/api/controller/v2"
export AAP_UI_URL="https://aap.example.test"
export APD_API_WAIT_ATTEMPTS=2
export APD_API_WAIT_DELAY=0

MOCK_ORGS_BODY=""
MOCK_CONFIG_BODY=""
ORGS_CALLS=0

curl() {
  local url=""
  local arg
  for arg in "$@"; do
    case "$arg" in
      http://* | https://*) url="$arg" ;;
    esac
  done
  case "$url" in
    *"/organizations/"*)
      ORGS_CALLS=$((ORGS_CALLS + 1))
      printf '%s' "$MOCK_ORGS_BODY"
      ;;
    *"/config/"*)
      printf '%s' "$MOCK_CONFIG_BODY"
      ;;
    *)
      echo "unexpected curl url: $url" >&2
      return 1
      ;;
  esac
}

PASSED=0
FAILED=0

pass() {
  echo "✓ $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo "✗ $1" >&2
  FAILED=$((FAILED + 1))
}

ORG_JSON='{"count":1,"results":[{"id":1,"name":"Default"}]}'
LICENSE_JSON='{"license_info":{"valid_key":true,"license_type":"enterprise"}}'
NO_LICENSE_JSON='{"license_info":{}}'
UNLICENSED_JSON='{"license_info":{"valid_key":false,"license_type":"UNLICENSED"}}'

ORGS_CALLS=0
MOCK_ORGS_BODY="$ORG_JSON"
if output=$(apd_wait_for_controller_api 2>&1) && [[ "$output" == *"AAP controller API is ready"* ]]; then
  pass "wait_succeeds_when_organizations_json_is_valid"
else
  fail "wait_succeeds_when_organizations_json_is_valid"
  echo "$output" >&2
fi

ORGS_CALLS=0
MOCK_ORGS_BODY="OK"
if output=$(apd_wait_for_controller_api 2>&1); then
  fail "wait_fails_when_api_returns_non_json"
  echo "$output" >&2
else
  if [[ "$output" == *"API is not ready"* ]] && [[ "$output" == *"OK"* ]]; then
    pass "wait_fails_when_api_returns_non_json"
  else
    fail "wait_fails_when_api_returns_non_json"
    echo "$output" >&2
  fi
fi

MOCK_ORGS_BODY="OK"
org_id=$(apd_default_org_id)
if [ -z "$org_id" ]; then
  pass "default_org_id_empty_on_non_json"
else
  fail "default_org_id_empty_on_non_json"
  echo "got: $org_id" >&2
fi

MOCK_ORGS_BODY="$ORG_JSON"
org_id=$(apd_default_org_id)
if [ "$org_id" = "1" ]; then
  pass "default_org_id_parses_json"
else
  fail "default_org_id_parses_json"
  echo "got: $org_id" >&2
fi

MOCK_CONFIG_BODY="$LICENSE_JSON"
if apd_require_subscription >/dev/null 2>&1; then
  pass "require_subscription_accepts_valid_license"
else
  fail "require_subscription_accepts_valid_license"
fi

MOCK_CONFIG_BODY="$NO_LICENSE_JSON"
if output=$(apd_require_subscription 2>&1); then
  fail "require_subscription_rejects_missing_license"
  echo "$output" >&2
else
  if [[ "$output" == *"does not have a registered subscription"* ]] \
    && [[ "$output" == *"https://aap.example.test"* ]]; then
    pass "require_subscription_rejects_missing_license"
  else
    fail "require_subscription_rejects_missing_license"
    echo "$output" >&2
  fi
fi

MOCK_CONFIG_BODY="$UNLICENSED_JSON"
if output=$(apd_require_subscription 2>&1); then
  fail "require_subscription_rejects_unlicensed_response"
  echo "$output" >&2
else
  if [[ "$output" == *"does not have a registered subscription"* ]]; then
    pass "require_subscription_rejects_unlicensed_response"
  else
    fail "require_subscription_rejects_unlicensed_response"
    echo "$output" >&2
  fi
fi

if grep -q 'apd_wait_for_controller_api || exit 1' "$DEPLOY_SH" \
  && grep -q 'apd_require_subscription || exit 1' "$DEPLOY_SH"; then
  pass "deploy_waits_and_requires_subscription"
else
  fail "deploy_waits_and_requires_subscription"
fi

if grep -q 'apd_wait_for_controller_api || return 1' "$LIB_SH" \
  && grep -q 'apd_require_subscription || return 1' "$LIB_SH"; then
  pass "init_connection_waits_and_requires_subscription"
else
  fail "init_connection_waits_and_requires_subscription"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
