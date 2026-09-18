#!/usr/bin/env bash
# Trigger the AO PR validation workflow from a local shell or an LLM session.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 <owner/repository> <pull-request-number> [head-sha] [webhook-path]" >&2
  exit 2
fi

REPO=$1
PR_NUMBER=$2
HEAD_SHA=unknown
[ "$#" -ge 3 ] && HEAD_SHA=$3
WEBHOOK_PATH=${AO_PR_TESTING_WEBHOOK_PATH:-aap-demo-pr-validation}
[ "$#" -ge 4 ] && WEBHOOK_PATH=$4
STATE_DIR=$(printenv AO_PR_TESTING_STATE_DIR 2>/dev/null || true)
[ -n "$STATE_DIR" ] || STATE_DIR="$HOME/.aap-demo/ao-pr-testing"
CLIENT_ID_FILE=$STATE_DIR/webhook-client-id
CLIENT_SECRET_FILE=$STATE_DIR/webhook-client-secret

[ -s "$CLIENT_ID_FILE" ] && [ -s "$CLIENT_SECRET_FILE" ] \
  || {
    echo "Enable the addon first: aap-demo enable ao-pr-testing" >&2
    exit 1
  }

AO_ROUTE=$(kubectl get route -n automation-orchestrator -o jsonpath='{.items[0].spec.host}')
[ -n "$AO_ROUTE" ] || {
  echo "Automation Orchestrator route not found" >&2
  exit 1
}

CLIENT_ID=$(<"$CLIENT_ID_FILE")
CLIENT_SECRET=$(<"$CLIENT_SECRET_FILE")
TOKEN_RESPONSE=$(curl -sk -X POST "https://$AO_ROUTE/api/v1/auth/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET")
unset CLIENT_SECRET

ACCESS_TOKEN=$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.access_token // empty')
if [ -z "$ACCESS_TOKEN" ]; then
  # Client credentials are intentionally short-lived. Refresh the stored
  # credential when a prior enable left behind an expired client secret.
  # shellcheck source=../../includes/addon-wire.sh
  source "$REPO_ROOT/includes/addon-wire.sh"
  AO_ACCESS_TOKEN=$(wire_ao_login_token)
  export AO_ACCESS_TOKEN
  SERVICE_ACCOUNT_ID=$(wire_ao_api GET '/service_accounts?limit=100' \
    | wire_ao_list_items \
    | jq -r '[.[] | select(.name == "aap-demo webhook caller")] | .[0].id // empty')
  [ -n "$SERVICE_ACCOUNT_ID" ] || {
    echo "Could not find the AO webhook service account" >&2
    exit 1
  }
  CREDENTIAL_RESPONSE=$(wire_ao_api POST "/service_accounts/${SERVICE_ACCOUNT_ID}/credentials" \
    '{"credential_type":"client_credentials","grace_period_seconds":3600}')
  NEW_CREDENTIAL_ID=$(printf '%s' "$CREDENTIAL_RESPONSE" | jq -r '.id // empty')
  CLIENT_ID=$(printf '%s' "$CREDENTIAL_RESPONSE" | jq -r '.identifier // empty')
  CLIENT_SECRET=$(printf '%s' "$CREDENTIAL_RESPONSE" | jq -r '.client_secret // empty')
  [ -n "$NEW_CREDENTIAL_ID" ] && [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] || {
    echo "Could not refresh the AO webhook client credential" >&2
    exit 1
  }
  umask 077
  printf '%s' "$CLIENT_ID" >"$CLIENT_ID_FILE"
  printf '%s' "$CLIENT_SECRET" >"$CLIENT_SECRET_FILE"
  printf '%s' "$NEW_CREDENTIAL_ID" >"$STATE_DIR/webhook-credential-id"
  unset CLIENT_SECRET CREDENTIAL_RESPONSE
  TOKEN_RESPONSE=$(curl -sk -X POST "https://$AO_ROUTE/api/v1/auth/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode grant_type=client_credentials \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "client_secret=$(<"$CLIENT_SECRET_FILE")")
  ACCESS_TOKEN=$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.access_token // empty')
fi
[ -n "$ACCESS_TOKEN" ] || {
  echo "Could not obtain an AO service-account access token" >&2
  exit 1
}

payload=$(jq -n \
  --arg repository "$REPO" \
  --arg number "$PR_NUMBER" \
  --arg sha "$HEAD_SHA" \
  '{repository:$repository,pull_request_number:($number|tonumber),head_sha:$sha}')

curl -sk -X POST "https://$AO_ROUTE/api/v1/webhooks/$WEBHOOK_PATH" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$payload"
printf '\n'
