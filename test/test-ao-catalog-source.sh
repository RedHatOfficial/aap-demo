#!/usr/bin/env bash
# Regression checks for the AO CatalogSource rendering contract.
#
# The normal AO install must proxy the healthy AAP catalog Service. Explicit or
# fallback index images must continue to use an image-backed local CatalogSource.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/../addons/ao/deploy.sh"
ADR="${SCRIPT_DIR}/../docs/adr/017-ao-addon.md"
TEMPLATE="${SCRIPT_DIR}/../config/olm/catalogsource.yaml"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
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

shared_rendered="${TEST_DIR}/shared.yaml"
awk -v catalog_ns="automation-orchestrator" \
  -v address="redhat-operators.aap-operator.svc:50051" '
  /  image: / { next }
  /^  secrets:$/ { skip_secrets=1; next }
  skip_secrets && /^    - / { next }
  /^  grpcPodConfig:/ {
    skip_secrets=0
    print "  address: " address
  }
  { sub(/namespace: aap-operator/, "namespace: " catalog_ns); print }
' "$TEMPLATE" >"$shared_rendered"

if grep -q '^  address: redhat-operators.aap-operator.svc:50051$' "$shared_rendered" \
  && grep -q '^  namespace: automation-orchestrator$' "$shared_rendered" \
  && ! grep -q '^  image:' "$shared_rendered" \
  && ! grep -q '^  secrets:' "$shared_rendered"; then
  pass "normal_catalog_uses_shared_service_address"
else
  fail "normal_catalog_uses_shared_service_address"
fi

fallback_shared_rendered="${TEST_DIR}/fallback-shared.yaml"
awk -v catalog_ns="automation-orchestrator" \
  -v address="ao-fallback.aap-operator.svc:50051" '
  /  image: / { next }
  /^  secrets:$/ { skip_secrets=1; next }
  skip_secrets && /^    - / { next }
  /^  grpcPodConfig:/ {
    skip_secrets=0
    print "  address: " address
  }
  { sub(/namespace: aap-operator/, "namespace: " catalog_ns); print }
' "$TEMPLATE" >"$fallback_shared_rendered"

if grep -q '^  address: ao-fallback.aap-operator.svc:50051$' "$fallback_shared_rendered" \
  && grep -q '^  namespace: automation-orchestrator$' "$fallback_shared_rendered" \
  && ! grep -q '^  image:' "$fallback_shared_rendered" \
  && ! grep -q '^  secrets:' "$fallback_shared_rendered"; then
  pass "fallback_catalog_uses_source_service_address"
else
  fail "fallback_catalog_uses_source_service_address"
fi

fallback_rendered="${TEST_DIR}/fallback.yaml"
sed -e 's|image: .*|image: registry.redhat.io/redhat/redhat-operator-index:v4.22|' \
  -e 's|namespace: aap-operator|namespace: automation-orchestrator|' \
  "$TEMPLATE" >"$fallback_rendered"

if grep -q '^  image: registry.redhat.io/redhat/redhat-operator-index:v4.22$' "$fallback_rendered" \
  && grep -q '^  secrets:$' "$fallback_rendered" \
  && grep -q '^  namespace: automation-orchestrator$' "$fallback_rendered" \
  && ! grep -q '^  address:' "$fallback_rendered"; then
  pass "fallback_catalog_renders_image_and_pull_secret"
else
  fail "fallback_catalog_renders_image_and_pull_secret"
fi

if grep -q 'AO_FALLBACK_INDEX_IMAGE' "$DEPLOY_SCRIPT" \
  && grep -q 'AO_FALLBACK_CATALOG_NAME' "$DEPLOY_SCRIPT" \
  && grep -q 'ensure_fallback_catalog_source' "$DEPLOY_SCRIPT" \
  && grep -q 'wait_for_catalog_service_ready "\$_catalog_ns" "\$AO_FALLBACK_CATALOG_NAME"' "$DEPLOY_SCRIPT" \
  && grep -q 'wait_for_operator_package "\$_catalog_ns" "\$AO_FALLBACK_CATALOG_NAME"' "$DEPLOY_SCRIPT" \
  && grep -q '"\$_image" 100' "$DEPLOY_SCRIPT" \
  && grep -q 'copy_pull_secret_to_namespace' "$DEPLOY_SCRIPT" \
  && grep -q 'apply_image_catalog_source' "$DEPLOY_SCRIPT" \
  && grep -q 'apply_address_catalog_source' "$DEPLOY_SCRIPT"; then
  pass "fallback_catalog_uses_source_namespace_pod"
else
  fail "fallback_catalog_uses_source_namespace_pod"
fi

if grep -q 'local _src_ns _target_image _source_image _current_image _shared_address _refresh_ns' "$DEPLOY_SCRIPT" \
  && grep -q '_refresh_ns="\$_src_ns"' "$DEPLOY_SCRIPT" \
  && grep -q 'kubectl delete pod -n "\$_refresh_ns"' "$DEPLOY_SCRIPT"; then
  pass "refresh_targets_source_catalog_namespace"
else
  fail "refresh_targets_source_catalog_namespace"
fi

if grep -q 'fallback/explicit images use a source-namespace catalog pod' "$ADR"; then
  pass "fallback_catalog_behavior_documented"
else
  fail "fallback_catalog_behavior_documented"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
