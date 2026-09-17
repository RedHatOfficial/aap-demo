#!/usr/bin/env bash
# Trigger the AO PR validation workflow from a local shell or an LLM session.

set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <owner/repository> <pull-request-number> [head-sha]" >&2
  exit 2
fi

REPO=$1
PR_NUMBER=$2
HEAD_SHA=unknown
[ "$#" -ge 3 ] && HEAD_SHA=$3
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
[ -n "$ACCESS_TOKEN" ] || {
  echo "Could not obtain an AO service-account access token" >&2
  exit 1
}

payload=$(jq -n \
  --arg repository "$REPO" \
  --arg number "$PR_NUMBER" \
  --arg sha "$HEAD_SHA" \
  '{repository:$repository,pull_request_number:($number|tonumber),head_sha:$sha}')

curl -sk -X POST "https://$AO_ROUTE/api/v1/webhooks/aap-demo-pr-validation" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$payload"
printf '\n'
