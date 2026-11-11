#!/usr/bin/env bash
# satellite-manifest — create and download a Red Hat Satellite subscription
# manifest programmatically via the RHSM management API.
#
# Reuses the aap-demo credential Vault's Red Hat offline token (the same
# rhsm-api token the fleet addon uses for image downloads). The manifest is
# written to ~/.aap-demo/satellite/manifest.zip, ready for
# satellite-lab/03-content-hammer.sh.
#
# Usage:
#   aap-demo enable satellite-manifest            # create + download manifest
#   MANIFEST_SAT_VERSION=sat-6.17 aap-demo enable satellite-manifest
#   MANIFEST_NAME=my-lab aap-demo enable satellite-manifest
#
# Requires the Red Hat account to hold the "View/Renew Subscription
# Information" permission (console.redhat.com -> Settings -> User Access).
# Without it the RHSM allocations API returns 401 and this addon stops with
# guidance instead of a cryptic failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../includes/credential-vault.sh
source "${SCRIPT_DIR}/../../includes/credential-vault.sh"
# shellcheck source=../fleet/fleet-auth.sh
source "${SCRIPT_DIR}/../fleet/fleet-auth.sh"

MANIFEST_DIR="${MANIFEST_DIR:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/satellite}"
MANIFEST_NAME="${MANIFEST_NAME:-aap-demo-satellite}"
MANIFEST_SAT_VERSION="${MANIFEST_SAT_VERSION:-sat-6.17}"
RHSM_API_BASE="${RHSM_API_BASE:-https://api.access.redhat.com/management/v1}"

_err() { printf 'ERROR: %s\n' "$*" >&2; }

# Set by _rhsm_api on every call; initialized so `set -u` never trips on it.
RHSM_HTTP_CODE=""
MANIFEST_DOWNLOAD_URL=""

# --- RHSM API helpers -------------------------------------------------------

# _rhsm_api <method> <path> [curl-args...] — authenticated call. Prints the
# HTTP status on the first stdout line, then the response body. Callers split
# them from the captured output (a global would not survive the subshell).
_rhsm_api() {
  local method="$1" path="$2"
  shift 2
  local token
  token=$(fleet_redhat_access_token false) || {
    _err "No valid Red Hat offline token in the Vault. Run: aap-demo fleet auth"
    return 2
  }
  local response
  # Pass the token via a curl config file on stdin so it never appears in the
  # process list or shell tracing (matches the fleet addon's pattern).
  response=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - --silent --show-error \
      --connect-timeout 15 --max-time 60 \
      --write-out '\n%{http_code}' \
      --request "$method" \
      --header "Accept: application/json" \
      "$@" \
      "${RHSM_API_BASE}${path}") || {
      _err "Unable to contact the Red Hat RHSM API"
      return 2
    }
  # First line: HTTP status. Remaining lines: body. (A global would not
  # survive the caller's command-substitution subshell.)
  printf '%s\n' "${response##*$'\n'}"
  printf '%s' "${response%$'\n'*}"
}

# Stop with actionable guidance when the account lacks the manifest permission.
_rhsm_require_permission() {
  case "${RHSM_HTTP_CODE:-}" in
    401 | 403)
      cat >&2 <<'EOF'
ERROR: The Red Hat account cannot use the subscription-manifest API (HTTP 401/403).

The offline token is valid, but the account lacks the
"View/Renew Subscription Information" permission required for manifest
management. Grant it, then re-run:

  1. console.redhat.com -> Settings (gear) -> User Access -> Users
  2. Edit your user -> add the Subscription Management /
     "View/Renew Subscription Information" role
  3. Re-run: aap-demo enable satellite-manifest

If you are the org admin and still see this, the account's subscriptions may
be managed under a different org, or the account needs Satellite entitlements.
EOF
      return 1
      ;;
  esac
  return 0
}

# --- Manifest workflow ------------------------------------------------------

_satellite_manifest_find_allocation() {
  # Print the UUID of an existing allocation named MANIFEST_NAME, if any.
  local out body
  out=$(_rhsm_api GET "/allocations") || return $?
  RHSM_HTTP_CODE="${out%%$'\n'*}"
  body="${out#*$'\n'}"
  _rhsm_require_permission || return 1
  [ "$RHSM_HTTP_CODE" = 200 ] || { _err "Listing allocations failed (HTTP $RHSM_HTTP_CODE)"; return 1; }
  printf '%s' "$body" | MANIFEST_NAME="$MANIFEST_NAME" python3 -c '
import json
import os
import sys

name = os.environ["MANIFEST_NAME"]
try:
    data = json.load(sys.stdin)
except (ValueError, AttributeError):
    raise SystemExit(0)
for alloc in data.get("body", []):
    if isinstance(alloc, dict) and alloc.get("name") == name:
        print(alloc.get("uuid", ""))
        break
'
}

_satellite_manifest_create_allocation() {
  # Progress to stderr: the caller captures this function's stdout as the UUID,
  # so anything printed to stdout would contaminate it.
  echo "▸ Creating subscription allocation '${MANIFEST_NAME}' (${MANIFEST_SAT_VERSION})..." >&2
  local out body
  out=$(_rhsm_api POST "/allocations?name=${MANIFEST_NAME}&version=${MANIFEST_SAT_VERSION}") || return $?
  RHSM_HTTP_CODE="${out%%$'\n'*}"
  body="${out#*$'\n'}"
  _rhsm_require_permission || return 1
  if [ "$RHSM_HTTP_CODE" != 200 ] && [ "$RHSM_HTTP_CODE" != 201 ]; then
    _err "Creating the allocation failed (HTTP $RHSM_HTTP_CODE): ${body:0:200}"
    return 1
  fi
  printf '%s' "$body" | python3 -c '
import json
import sys
data = json.load(sys.stdin)
body = data.get("body", data)
print(body.get("uuid", "") if isinstance(body, dict) else "")
'
}

_satellite_manifest_export() {
  local uuid="$1"
  echo "▸ Triggering manifest export for allocation ${uuid}..."
  local out body job_id
  out=$(_rhsm_api GET "/allocations/${uuid}/export") || return $?
  RHSM_HTTP_CODE="${out%%$'\n'*}"
  body="${out#*$'\n'}"
  _rhsm_require_permission || return 1
  if [ "$RHSM_HTTP_CODE" != 200 ] && [ "$RHSM_HTTP_CODE" != 202 ]; then
    _err "Triggering the export failed (HTTP $RHSM_HTTP_CODE): ${body:0:200}"
    return 1
  fi
  job_id=$(printf '%s' "$body" | python3 -c '
import json
import sys
data = json.load(sys.stdin)
body = data.get("body", data)
print(body.get("exportJobID", "") if isinstance(body, dict) else "")
')
  [ -n "$job_id" ] || { _err "The export response did not include a job ID"; return 1; }

  echo "▸ Waiting for export job ${job_id}..."
  # The exportJob endpoint returns 202 while running and 200 with a download
  # href once the manifest is ready (matching the RHSM API / Manifester flow).
  local attempt href
  for attempt in $(seq 1 60); do
    out=$(_rhsm_api GET "/allocations/${uuid}/exportJob/${job_id}") || return $?
    RHSM_HTTP_CODE="${out%%$'\n'*}"
    body="${out#*$'\n'}"
    case "$RHSM_HTTP_CODE" in
      200)
        href=$(printf '%s' "$body" | python3 -c '
import json
import sys
data = json.load(sys.stdin)
body = data.get("body", data)
print(body.get("href", "") if isinstance(body, dict) else "")
')
        [ -n "$href" ] || { _err "Export completed but no download URL was returned"; return 1; }
        MANIFEST_DOWNLOAD_URL="$href"
        return 0
        ;;
      202)
        sleep 5
        ;;
      *)
        _err "Polling the export job failed (HTTP $RHSM_HTTP_CODE): ${body:0:200}"
        return 1
        ;;
    esac
  done
  _err "Timed out waiting for the manifest export job"
  return 1
}

_satellite_manifest_download() {
  local dest="${MANIFEST_DIR}/manifest.zip"
  mkdir -p "$MANIFEST_DIR"
  local token
  token=$(fleet_redhat_access_token false) || return 2
  echo "▸ Downloading manifest to ${dest}..." >&2
  local code
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - --silent --show-error \
      --connect-timeout 15 --max-time 300 \
      --output "$dest" --write-out '%{http_code}' \
      "$MANIFEST_DOWNLOAD_URL") || { _err "Unable to download the manifest"; return 1; }
  if [ "$code" != 200 ]; then
    rm -f "$dest"
    _err "Manifest download failed (HTTP $code)"
    return 1
  fi
  [ -s "$dest" ] || { rm -f "$dest"; _err "Downloaded manifest is empty"; return 1; }
  chmod 600 "$dest"
  printf '%s' "$dest"
}

main() {
  echo "Building a Satellite subscription manifest via the RHSM API..."
  echo "  Allocation: ${MANIFEST_NAME}  (${MANIFEST_SAT_VERSION})"

  local uuid
  uuid=$(_satellite_manifest_find_allocation)
  if [ -n "$uuid" ]; then
    echo "✓ Reusing existing allocation ${uuid}"
  else
    uuid=$(_satellite_manifest_create_allocation) || return 1
    [ -n "$uuid" ] || { _err "Allocation creation did not return a UUID"; return 1; }
    echo "✓ Created allocation ${uuid}"
    cat >&2 <<EOF

  NOTE: the new allocation has no subscriptions yet. Add Satellite
  infrastructure + RHEL entitlements before the manifest is useful:
    console.redhat.com -> Subscriptions -> Subscription Allocations
    -> ${MANIFEST_NAME} -> Add subscriptions
  (Entitlement auto-attach via the API is account-specific and not automated
  here; the export below produces a manifest from whatever is attached.)
EOF
  fi

  _satellite_manifest_export "$uuid" || return 1
  local path
  path=$(_satellite_manifest_download) || return 1

  echo ""
  echo "✓ Satellite manifest ready: ${path}"
  echo "  Use it with the Satellite lab:"
  echo "    scp ${path} root@192.168.122.20:/root/manifest.zip"
  echo "    ssh root@192.168.122.20 'cd satellite-lab && ./03-content-hammer.sh /root/manifest.zip'"
}

main "$@"
