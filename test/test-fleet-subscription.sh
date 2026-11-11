#!/usr/bin/env bash
# Regression test for automatic AAP subscription attachment.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

FLEET_CDN_USERNAME_KEY="aap_demo.redhat.cdn_username"
FLEET_CDN_PASSWORD_KEY="aap_demo.redhat.cdn_password"
FLEET_REDHAT_ACCOUNT_NUMBER_KEY="aap_demo.redhat.account_number"
FLEET_REDHAT_SUBSCRIPTION_ID_KEY="aap_demo.redhat.aap_subscription_id"

_err() {
  printf 'ERROR: %s\n' "$*" >&2
}

get_ingress_ca_cert_path() {
  return 1
}

aap_demo_vault_get() {
  case "$1" in
    "$FLEET_CDN_USERNAME_KEY") printf 'cdn-user' ;;
    "$FLEET_CDN_PASSWORD_KEY") printf 'cdn-password' ;;
    "$FLEET_REDHAT_ACCOUNT_NUMBER_KEY") printf '5782799' ;;
    "$FLEET_REDHAT_SUBSCRIPTION_ID_KEY") return 1 ;;
    *) return 1 ;;
  esac
}

aap_demo_vault_set() {
  printf '%s=%s\n' "$1" "$2" >>"${TEST_DIR}/vault-set"
}

fleet_redhat_ensure_cdn_credentials() {
  return 0
}

fleet_redhat_ensure_account_number() {
  return 0
}

# shellcheck source=../addons/fleet/fleet-aap.sh
source "${REPO_ROOT}/addons/fleet/fleet-aap.sh"
FLEET_DIR="${TEST_DIR}/fleet"

# shellcheck disable=SC2329
_fleet_aap_api() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"
  case "${method} ${endpoint}" in
    "GET /config/")
      printf '{"license_info":{}}'
      ;;
    "POST /config/subscriptions/")
      if [[ "$body" != *'"subscriptions_username": "cdn-user"'* ]] \
        || [[ "$body" != *'"subscriptions_password": "cdn-password"'* ]]; then
        return 1
      fi
      printf '%s' '[
        {"account_number":"5782799","subscription_id":"18689790","subscription_name":"Employee SKU"},
        {"account_number":"5782799","subscription_id":"26730217","subscription_name":"Developer Subscription"}
      ]'
      ;;
    "POST /config/attach/")
      if [[ "$body" != *'"subscription_id": "18689790"'* ]]; then
        return 1
      fi
      touch "${TEST_DIR}/attached"
      printf '{"valid_key":true,"subscription_id":"18689790"}'
      ;;
    *)
      return 1
      ;;
  esac
}

if ! _fleet_aap_ensure_subscription >/dev/null; then
  echo "FAIL: automatic subscription attachment failed" >&2
  exit 1
fi
if [ ! -e "${TEST_DIR}/attached" ]; then
  echo "FAIL: selected subscription was not attached" >&2
  exit 1
fi
if ! grep -q "^${FLEET_REDHAT_SUBSCRIPTION_ID_KEY}=18689790$" "${TEST_DIR}/vault-set"; then
  echo "FAIL: selected subscription ID was not persisted" >&2
  exit 1
fi
if [ "$(cat "${FLEET_DIR}/aap_subscription_name")" != "Employee SKU" ]; then
  echo "FAIL: selected subscription name was not persisted" >&2
  exit 1
fi

echo "PASS: automatically attaches and records the first account subscription"

_fleet_aap_api() {
  printf ''
}
if output=$(_fleet_aap_ensure_subscription 2>&1); then
  echo "FAIL: empty AAP response was treated as an unlicensed instance" >&2
  exit 1
fi
if ! grep -q "AAP controller API is not ready" <<<"$output" \
  || grep -q "attaching an entitled subscription" <<<"$output"; then
  echo "FAIL: empty AAP response did not produce a readiness error" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
echo "PASS: unavailable AAP API does not trigger subscription attachment"
