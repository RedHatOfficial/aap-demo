#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDON_DIR="$ROOT_DIR/addons/eda-playground"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -d "$ADDON_DIR" ] || fail "addon directory missing"
[ -x "$ADDON_DIR/deploy.sh" ] || fail "deploy.sh must be executable"

for file in README.md deploy.sh namespace.yaml configmap.yaml service.yaml deployment.yaml route.yaml; do
  [ -f "$ADDON_DIR/$file" ] || fail "missing addon file: $file"
done

for file in namespace.yaml configmap.yaml service.yaml deployment.yaml route.yaml; do
  grep -q '^apiVersion:' "$ADDON_DIR/$file" || fail "$file missing apiVersion"
  grep -q '^kind:' "$ADDON_DIR/$file" || fail "$file missing kind"
done

grep -q '^  name: eda-playground$' "$ADDON_DIR/namespace.yaml" || fail "dedicated namespace missing"
grep -q '^      serviceAccountName: eda-playground$' "$ADDON_DIR/deployment.yaml" || fail "dedicated service account missing"
grep -q 'secretKeyRef:' "$ADDON_DIR/deployment.yaml" || fail "OAuth Secret reference missing"
grep -q 'name: eda-playground-oauth' "$ADDON_DIR/deployment.yaml" || fail "OAuth Secret name missing"
grep -q 'readinessProbe:' "$ADDON_DIR/deployment.yaml" || fail "readiness probe missing"
grep -q 'livenessProbe:' "$ADDON_DIR/deployment.yaml" || fail "liveness probe missing"
grep -q 'requests:' "$ADDON_DIR/deployment.yaml" || fail "resource requests missing"
grep -q 'limits:' "$ADDON_DIR/deployment.yaml" || fail "resource limits missing"
grep -q '__EDA_PLAYGROUND_ROUTE_HOST__' "$ADDON_DIR/route.yaml" || fail "Route host template missing"

echo "PASS: EDA Playground addon static checks"
