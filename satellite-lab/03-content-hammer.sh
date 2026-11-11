#!/usr/bin/env bash
# 03-content-hammer.sh — run ON the Satellite VM as root.
# Content architecture for RHEL 9 + RHEL 10 with on_demand everywhere:
#   manifest -> download policy -> repo sets -> sync -> LCEs -> CVs -> activation keys
# Usage: ./03-content-hammer.sh [/root/manifest.zip]
set -euo pipefail

ORG="Default Organization"
MANIFEST="${1:-/root/manifest.zip}"
RHEL_PRODUCT="Red Hat Enterprise Linux for x86_64"
CLIENT_PRODUCT="Red Hat Satellite Client 6"   # verify: hammer repository-set list --search "Satellite Client"

[[ -f $MANIFEST ]] || { echo "ERROR: manifest not found at $MANIFEST"; exit 1; }

hammer defaults add --param-name organization --param-value "$ORG" 2>/dev/null || true

echo "== 1/7 Upload manifest =="
hammer subscription upload --file "$MANIFEST"

echo "== 2/7 Force on_demand download policy (BEFORE enabling repos) =="
hammer settings set --name default_redhat_download_policy --value on_demand
hammer settings set --name default_download_policy --value on_demand

echo "== 3/7 Enable repository sets (RHEL 9 + RHEL 10, BaseOS/AppStream, RPM + Kickstart) =="
enable_set() { # <product> <repository-set name> [releasever]
  local product=$1 set=$2 rel=${3:-}
  if [[ -n $rel ]]; then
    hammer repository-set enable --product "$product" --name "$set" --basearch x86_64 --releasever "$rel"
  else
    hammer repository-set enable --product "$product" --name "$set" --basearch x86_64
  fi
}
# RHEL 9
enable_set "$RHEL_PRODUCT" "Red Hat Enterprise Linux 9 for x86_64 - BaseOS (RPMs)" 9
enable_set "$RHEL_PRODUCT" "Red Hat Enterprise Linux 9 for x86_64 - AppStream (RPMs)" 9
enable_set "$RHEL_PRODUCT" "Red Hat Enterprise Linux 9 for x86_64 - BaseOS (Kickstart)" 9.5
enable_set "$RHEL_PRODUCT" "Red Hat Enterprise Linux 9 for x86_64 - AppStream (Kickstart)" 9.5
# RHEL 10
enable_set "$RHEL_PRODUCT" "Red Hat Enterprise Linux 10 for x86_64 - BaseOS (RPMs)" 10
enable_set "$RHEL_PRODUCT" "Red Hat Enterprise Linux 10 for x86_64 - AppStream (RPMs)" 10
enable_set "$RHEL_PRODUCT" "Red Hat Enterprise Linux 10 for x86_64 - BaseOS (Kickstart)" 10.0
enable_set "$RHEL_PRODUCT" "Red Hat Enterprise Linux 10 for x86_64 - AppStream (Kickstart)" 10.0
# Satellite Client (katello-host-tools / REX agent bits) for managed nodes
enable_set "$CLIENT_PRODUCT" "Red Hat Satellite Client 6 for RHEL 9 x86_64 (RPMs)"  || echo "WARN: verify client repo-set name via: hammer repository-set list --search 'Satellite Client'"
enable_set "$CLIENT_PRODUCT" "Red Hat Satellite Client 6 for RHEL 10 x86_64 (RPMs)" || echo "WARN: verify client repo-set name via: hammer repository-set list --search 'Satellite Client'"

echo "== 4/7 Enforce on_demand on every repo, then sync =="
# Kickstart trees always sync in full (no on_demand for distribution content) — expected.
sync_repo() { # <product> <repo name>
  hammer repository update --product "$1" --name "$2" --download-policy on_demand 2>/dev/null || true
  hammer repository synchronize --product "$1" --name "$2"
}
sync_repo "$RHEL_PRODUCT" "Red Hat Enterprise Linux 9 for x86_64 - BaseOS RPMs 9"
sync_repo "$RHEL_PRODUCT" "Red Hat Enterprise Linux 9 for x86_64 - AppStream RPMs 9"
sync_repo "$RHEL_PRODUCT" "Red Hat Enterprise Linux 9 for x86_64 - BaseOS Kickstart 9.5"
sync_repo "$RHEL_PRODUCT" "Red Hat Enterprise Linux 9 for x86_64 - AppStream Kickstart 9.5"
sync_repo "$RHEL_PRODUCT" "Red Hat Enterprise Linux 10 for x86_64 - BaseOS RPMs 10"
sync_repo "$RHEL_PRODUCT" "Red Hat Enterprise Linux 10 for x86_64 - AppStream RPMs 10"
sync_repo "$RHEL_PRODUCT" "Red Hat Enterprise Linux 10 for x86_64 - BaseOS Kickstart 10.0"
sync_repo "$RHEL_PRODUCT" "Red Hat Enterprise Linux 10 for x86_64 - AppStream Kickstart 10.0"
sync_repo "$CLIENT_PRODUCT" "Red Hat Satellite Client 6 for RHEL 9 x86_64 RPMs"  || true
sync_repo "$CLIENT_PRODUCT" "Red Hat Satellite Client 6 for RHEL 10 x86_64 RPMs" || true

echo "== 5/7 Lifecycle environments: Library -> DEV -> TEST -> PROD =="
hammer lifecycle-environment create --name DEV  --prior Library
hammer lifecycle-environment create --name TEST --prior DEV
hammer lifecycle-environment create --name PROD --prior TEST

echo "== 6/7 Content views: create, add repos, publish, promote DEV->TEST->PROD =="
create_cv() { # <cv name> <rhel major> <kickstart releasever>
  local cv=$1 major=$2 ksrel=$3
  hammer content-view create --name "$cv"
  for repo in \
    "Red Hat Enterprise Linux ${major} for x86_64 - BaseOS RPMs ${major}" \
    "Red Hat Enterprise Linux ${major} for x86_64 - AppStream RPMs ${major}" \
    "Red Hat Enterprise Linux ${major} for x86_64 - BaseOS Kickstart ${ksrel}"; do
    hammer content-view add-repository --name "$cv" --product "$RHEL_PRODUCT" --repository "$repo"
  done
  hammer content-view add-repository --name "$cv" --product "$CLIENT_PRODUCT" \
    --repository "Red Hat Satellite Client 6 for RHEL ${major} x86_64 RPMs" || true
  # on_demand => publish/promote are metadata-only and take seconds
  hammer content-view publish --name "$cv"
  for env in DEV TEST PROD; do
    hammer content-view version promote --content-view "$cv" --version 1.0 --to-lifecycle-environment "$env"
  done
}
create_cv RHEL9  9  9.5
create_cv RHEL10 10 10.0

echo "== 7/7 Activation keys per OS x lifecycle stage =="
for spec in "rhel9 RHEL9" "rhel10 RHEL10"; do
  set -- $spec
  for env in DEV TEST PROD; do
    if hammer activation-key info --name "ak-$1-${env,,}" >/dev/null 2>&1; then
      echo "  activation key ak-$1-${env,,} already exists"
    else
      hammer activation-key create --name "ak-$1-${env,,}" \
        --lifecycle-environment "$env" --content-view "$2" \
        --auto-attach true --unlimited-hosts
    fi
  done
done

hammer activation-key list
echo "Done. Content views RHEL9/RHEL10 are published and promoted through PROD."
