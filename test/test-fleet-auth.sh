#!/usr/bin/env bash
# Regression tests for Vault-backed Fleet Red Hat authentication.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export AAP_DEMO_VAULT_FILE="${TEST_DIR}/conf/env-aap-demo.yml"
export AAP_DEMO_VAULT_PASSWORD_FILE="${TEST_DIR}/conf/.vaultpass-aap-demo.txt"
export AAP_DEMO_SECRET_PROMPT_OUTPUT=/dev/null
export FLEET_REDHAT_OPEN_TOKEN_PAGE=false

_err() {
  printf 'ERROR: %s\n' "$*" >&2
}

# shellcheck source=../includes/credential-vault.sh
source "${REPO_ROOT}/includes/credential-vault.sh"
# shellcheck source=../addons/fleet/fleet-auth.sh
source "${REPO_ROOT}/addons/fleet/fleet-auth.sh"

failures=0
fail() {
  echo "✗ $1" >&2
  failures=$((failures + 1))
}

file_mode() {
  if stat -c '%a' "$1" 2>/dev/null; then
    return 0
  fi
  stat -f '%Lp' "$1"
}

curl() {
  local offline_token
  offline_token=$(cat)
  case "${SSO_TEST_MODE:-normal}" in
    network) return 7 ;;
    unavailable) printf '{"error":"temporarily_unavailable"}\n503'; return ;;
    malformed) printf '{}\n200'; return ;;
  esac

  if [ "$offline_token" = "valid-offline-token" ]; then
    printf '{"access_token":"short-lived-access-token"}\n200'
  else
    printf '{"error":"invalid_grant"}\n400'
  fi
}

vault_prompt="${TEST_DIR}/vault-prompt"
printf 'vault-password\nvault-password\n' >"$vault_prompt"
export AAP_DEMO_SECRET_PROMPT_DEVICE="$vault_prompt"
if _aap_demo_vault_ensure_file \
  && [ "$(file_mode "$AAP_DEMO_VAULT_PASSWORD_FILE")" = "600" ] \
  && [ "$(file_mode "$AAP_DEMO_VAULT_FILE")" = "600" ] \
  && head -n 1 "$AAP_DEMO_VAULT_FILE" | grep -q '^[$]ANSIBLE_VAULT;'; then
  echo "✓ creates_private_encrypted_vault"
else
  fail "creates_private_encrypted_vault"
fi

token_prompt="${TEST_DIR}/token-prompt"
cdn_prompt="${TEST_DIR}/cdn-prompt"
account_prompt="${TEST_DIR}/account-prompt"
printf 'cdn-user\ncdn-password\n' >"$cdn_prompt"
export AAP_DEMO_SECRET_PROMPT_DEVICE="$cdn_prompt"
if _fleet_redhat_prompt_cdn_credentials \
  && [ "$(aap_demo_vault_get "$FLEET_CDN_USERNAME_KEY")" = "cdn-user" ] \
  && [ "$(aap_demo_vault_get "$FLEET_CDN_PASSWORD_KEY")" = "cdn-password" ]; then
  echo "✓ prompts_once_and_stores_cdn_credentials"
else
  fail "prompts_once_and_stores_cdn_credentials"
fi

printf '5782799\n' >"$account_prompt"
export AAP_DEMO_SECRET_PROMPT_DEVICE="$account_prompt"
if _fleet_redhat_prompt_account_number \
  && [ "$(aap_demo_vault_get "$FLEET_REDHAT_ACCOUNT_NUMBER_KEY")" = "5782799" ]; then
  echo "✓ prompts_once_and_stores_account_number"
else
  fail "prompts_once_and_stores_account_number"
fi

printf 'valid-offline-token\n' >"$token_prompt"
export AAP_DEMO_SECRET_PROMPT_DEVICE="$token_prompt"
if fleet_redhat_auth configure >/dev/null \
  && [ "$(aap_demo_vault_get "$FLEET_REDHAT_SECRET_KEY")" = "valid-offline-token" ] \
  && [ "$(aap_demo_vault_get "aap_demo.project.name")" = "aap-demo" ] \
  && [ "$(aap_demo_vault_get "aap_demo.cluster.name")" = "crc-microshift" ]; then
  echo "✓ stores_offline_token_and_project_metadata"
else
  fail "stores_offline_token_and_project_metadata"
fi

if [ "$(fleet_redhat_auth status)" = "Red Hat Customer Portal authentication: valid" ]; then
  echo "✓ validates_stored_token_without_prompt"
else
  fail "validates_stored_token_without_prompt"
fi

for mode in network unavailable malformed; do
  if SSO_TEST_MODE="$mode" fleet_redhat_access_token true >"$TEST_DIR/result" 2>"$TEST_DIR/error"; then
    fail "rejects_$mode"
  elif [ "$?" -ne 2 ]; then
    fail "distinguishes_${mode}_from_invalid_token"
  elif grep -q 'new token is required' "$TEST_DIR/error"; then
    fail "does_not_replace_token_on_$mode"
  elif [ "$(aap_demo_vault_get "$FLEET_REDHAT_SECRET_KEY")" != valid-offline-token ]; then
    fail "preserves_token_on_$mode"
  else
    echo "✓ preserves_token_and_reports_$mode"
  fi
done

if _fleet_redhat_exchange_token expired-offline-token >"$TEST_DIR/result" 2>"$TEST_DIR/error"; then
  fail "rejects_invalid_grant"
elif grep -q 'HTTP 400, invalid_grant' "$TEST_DIR/error" \
  && ! grep -q 'expired-offline-token' "$TEST_DIR/error"; then
  echo "✓ explains_rejected_token_without_exposing_it"
else
  fail "explains_rejected_token_without_exposing_it"
fi

aap_demo_vault_set "$FLEET_REDHAT_SECRET_KEY" "expired-offline-token"
printf 'valid-offline-token\n' >"$token_prompt"
if fleet_redhat_auth configure >/dev/null \
  && [ "$(aap_demo_vault_get "$FLEET_REDHAT_SECRET_KEY")" = "valid-offline-token" ]; then
  echo "✓ replaces_expired_token"
else
  fail "replaces_expired_token"
fi

if fleet_redhat_auth reset >/dev/null \
  && ! aap_demo_vault_get "$FLEET_REDHAT_SECRET_KEY" >/dev/null 2>&1 \
  && ! aap_demo_vault_get "$FLEET_CDN_USERNAME_KEY" >/dev/null 2>&1 \
  && ! aap_demo_vault_get "$FLEET_CDN_PASSWORD_KEY" >/dev/null 2>&1 \
  && ! aap_demo_vault_get "$FLEET_REDHAT_ACCOUNT_NUMBER_KEY" >/dev/null 2>&1 \
  && ! aap_demo_vault_get "$FLEET_REDHAT_SUBSCRIPTION_ID_KEY" >/dev/null 2>&1 \
  && [ "$(aap_demo_vault_get "aap_demo.cluster.name")" = "crc-microshift" ]; then
  echo "✓ removes_credentials_and_retains_project_metadata"
else
  fail "removes_credentials_and_retains_project_metadata"
fi

echo "Failed: ${failures}"
[ "$failures" -eq 0 ]
