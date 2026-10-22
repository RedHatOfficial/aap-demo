#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

grep -q 'keycloak' "$ROOT_DIR/aap-demo.sh" || { echo "FAIL: keycloak missing from CLI"; exit 1; }
grep -q 'aap-demo-keycloak' "$ROOT_DIR/addons/keycloak/keycloak.yaml" || { echo "FAIL: isolated namespace missing"; exit 1; }
grep -q 'aap-demo-aap' "$ROOT_DIR/addons/keycloak/deploy.sh" || { echo "FAIL: AAP client missing"; exit 1; }
grep -q 'aap-demo-ao' "$ROOT_DIR/addons/keycloak/deploy.sh" || { echo "FAIL: AO client missing"; exit 1; }
grep -q 'KC_BOOTSTRAP_ADMIN_PASSWORD' "$ROOT_DIR/addons/keycloak/keycloak.yaml" || { echo "FAIL: admin secret not wired"; exit 1; }
grep -q 'chmod 600' "$ROOT_DIR/addons/keycloak/deploy.sh" || { echo "FAIL: credential permissions not enforced"; exit 1; }
grep -q 'addon" != "keycloak"' "$ROOT_DIR/aap-demo.sh" || { echo "FAIL: keycloak must not trigger generic addon wiring"; exit 1; }
grep -q 'REALM_REVISION' "$ROOT_DIR/addons/keycloak/keycloak.yaml" || { echo "FAIL: realm revision missing"; exit 1; }
grep -q '_keycloak_state_dir' "$ROOT_DIR/aap-demo.sh" || { echo "FAIL: status credential state missing"; exit 1; }
grep -q 'aap-oidc-admin' "$ROOT_DIR/aap-demo.sh" || { echo "FAIL: status OIDC user missing"; exit 1; }
grep -q 'aap-oidc-auditor' "$ROOT_DIR/aap-demo.sh" || { echo "FAIL: status auditor missing"; exit 1; }
grep -q 'aap-oidc-developer' "$ROOT_DIR/aap-demo.sh" || { echo "FAIL: status developer missing"; exit 1; }
grep -q "tr -d '\\\\r\\\\n'" "$ROOT_DIR/addons/keycloak/deploy.sh" || { echo "FAIL: generated credentials must not include newline"; exit 1; }
if grep -Eq 'echo.*(PASSWORD|SECRET)' "$ROOT_DIR/addons/keycloak/deploy.sh"; then
  echo "FAIL: possible secret output"
  exit 1
fi
echo "PASS: Keycloak addon static checks"
