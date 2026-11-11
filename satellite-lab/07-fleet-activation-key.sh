#!/usr/bin/env bash
# 07-fleet-activation-key.sh — create a Satellite activation key for fleet nodes
#
# Fleet nodes register to the Satellite (not directly to Red Hat) so content
# is served from the local Pulp and hosts appear in the Satellite inventory.
# This creates an activation key bound to the RHEL9 content view in Library,
# with auto-attach enabled (Simple Content Access). Idempotent.
#
# Runs on the Satellite VM as root (hammer is configured for the admin user).
set -euo pipefail

# The lab's RHEL content views (RHEL9/RHEL10) are published in Demo Org by
# 03-content; Default Organization only holds the empty default view. Register
# fleet nodes to whichever org actually owns the content view.
ORG="${SAT_ORG:-Demo Org}"
AK_NAME="${SAT_FLEET_AK:-fleet-rhel9}"
CV_NAME="${SAT_FLEET_CV:-RHEL9}"
LCE="${SAT_FLEET_LCE:-Library}"

_log() { printf '  %s\n' "$*"; }
_err() { printf 'ERROR: %s\n' "$*" >&2; }

# Pick the content view that actually has repositories. RHEL9 is the fleet
# default; fall back to RHEL10 when RHEL9 is empty. The REPOSITORY IDS column
# is the last pipe-separated field on the row whose NAME matches exactly.
_cv_has_repos() {
  local cv="$1"
  hammer --no-headers content-view list --organization "$ORG" 2>/dev/null \
    | awk -F'|' -v name="$cv" '
        { n=$2; gsub(/^[ \t]+|[ \t]+$/, "", n) }
        n == name { ids=$NF; gsub(/^[ \t]+|[ \t]+$/, "", ids); if (ids ~ /[0-9]/) found=1 }
        END { exit(found ? 0 : 1) }'
}

TARGET_CV="$CV_NAME"
if ! _cv_has_repos "$CV_NAME"; then
  if _cv_has_repos "RHEL10"; then
    _log "Content view $CV_NAME has no repositories; using RHEL10"
    TARGET_CV="RHEL10"
  else
    _err "Neither $CV_NAME nor RHEL10 content view has repositories; run 03-content first"
    exit 1
  fi
fi

# Create the activation key if missing.
if hammer --no-headers activation-key list --organization "$ORG" 2>/dev/null \
    | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | grep -qx "$AK_NAME"; then
  _log "✓ Activation key $AK_NAME already exists"
else
  hammer activation-key create --organization "$ORG" --name "$AK_NAME" \
    --content-view "$TARGET_CV" --lifecycle-environment "$LCE" \
    --unlimited-hosts >/dev/null
  _log "✓ Created activation key $AK_NAME ($TARGET_CV / $LCE)"
fi

# Bind it to the content view environment and enable auto-attach (SCA).
hammer activation-key update --organization "$ORG" --name "$AK_NAME" \
  --content-view "$TARGET_CV" --lifecycle-environment "$LCE" \
  --auto-attach true >/dev/null 2>&1 || true

_log "✓ Activation key ready: $AK_NAME (org: $ORG, cv: $TARGET_CV, lce: $LCE)"
printf '%s\n' "$AK_NAME"
