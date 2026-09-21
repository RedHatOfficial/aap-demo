#!/usr/bin/env bash
# Regression checks for the AO CatalogSource rendering contract.
#
# The normal AO install must proxy the healthy AAP catalog Service. Explicit or
# fallback index images must continue to use an image-backed local CatalogSource.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/../addons/ao/deploy.sh"
ADR="${SCRIPT_DIR}/../docs/adr/017-ao-addon.md"
PASSED=0
FAILED=0

pass() {
  echo "✓ $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo "✗ $1"
  FAILED=$((FAILED + 1))
}

if grep -q 'local _src_ns _target_image _source_image _current_image _shared_address' "$DEPLOY_SCRIPT" \
  && grep -q 'redhat-operators.\${_src_ns}.svc:50051' "$DEPLOY_SCRIPT"; then
  pass "normal_catalog_uses_shared_service_address"
else
  fail "normal_catalog_uses_shared_service_address"
fi

if grep -q '\[ "\$_target_image" = "\$_source_image" \]' "$DEPLOY_SCRIPT" \
  && grep -q 'awk -v catalog_ns=' "$DEPLOY_SCRIPT" \
  && ! grep -q '\\\\n  secrets:' "$DEPLOY_SCRIPT"; then
  pass "shared_catalog_path_matches_default_image"
else
  fail "shared_catalog_path_matches_default_image"
fi

if grep -q 'AO_FALLBACK_INDEX_IMAGE' "$DEPLOY_SCRIPT" \
  && grep -q 'copy_pull_secret_to_namespace' "$DEPLOY_SCRIPT" \
  && grep -q 'sed -e "s|image: .*|image:' "$DEPLOY_SCRIPT"; then
  pass "fallback_catalog_keeps_image_backed_path"
else
  fail "fallback_catalog_keeps_image_backed_path"
fi

if grep -q 'fallback/explicit images use a local catalog pod' "$ADR"; then
  pass "fallback_catalog_behavior_documented"
else
  fail "fallback_catalog_behavior_documented"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
