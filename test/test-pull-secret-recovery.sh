#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

_err() {
  printf 'ERROR: %s\n' "$*" >&2
}

# shellcheck source=../includes/credential-vault.sh
source "${REPO_ROOT}/includes/credential-vault.sh"

_AAP_DEMO_SECURE_CURL_LOADED=1
AAP_DEMO_VAULT_PYTHON=python3

aap_demo_vault_get() {
  [ "$1" = "aap_demo.redhat.offline_token" ] || return 1
  printf '%s' 'offline-token'
}

aap_demo_vault_set() {
  printf '%s' "$1" >"${TEST_DIR}/stored-key"
  printf '%s' "$2" >"${TEST_DIR}/stored-value"
}

curl() {
  local args="$*"
  cat >/dev/null
  case "$args" in
    *openid-connect/token*)
      printf '%s' '{"access_token":"short-lived"}'
      ;;
    *accounts_mgmt/v1/access_token*)
      printf '%s' '{"auths":{"registry.redhat.io":{"auth":"test"}}}'
      ;;
    *)
      return 1
      ;;
  esac
}

result=$(aap_demo_pull_secret_fetch_redhat)
[ "$result" = '{"auths":{"registry.redhat.io":{"auth":"test"}}}' ]
[ "$(cat "${TEST_DIR}/stored-key")" = "aap_demo.redhat.pull_secret" ]
[ "$(cat "${TEST_DIR}/stored-value")" = "$result" ]

rm -f "${TEST_DIR}/stored-key" "${TEST_DIR}/stored-value"
curl() {
  cat >/dev/null
  case "$*" in
    *openid-connect/token*) printf '%s' '{"access_token":"short-lived"}' ;;
    *) printf '%s' '{"unexpected":"response"}' ;;
  esac
}
if aap_demo_pull_secret_fetch_redhat >/dev/null 2>&1; then
  echo "FAIL: invalid pull-secret response was accepted" >&2
  exit 1
fi
[ ! -e "${TEST_DIR}/stored-key" ]

grep -q 'aap_demo_pull_secret_fetch_redhat' "${REPO_ROOT}/includes/crc-create.sh"

echo "PASS: securely recovers and validates a missing pull secret"
