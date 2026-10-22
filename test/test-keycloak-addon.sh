#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

grep -q 'keycloak' "$ROOT_DIR/aap-demo.sh" || {
  echo "FAIL: keycloak missing from CLI"
  exit 1
}
grep -q 'aap-demo-keycloak' "$ROOT_DIR/addons/keycloak/keycloak.yaml" || {
  echo "FAIL: isolated namespace missing"
  exit 1
}
grep -q 'aap-demo-aap' "$ROOT_DIR/addons/keycloak/deploy.sh" || {
  echo "FAIL: AAP client missing"
  exit 1
}
grep -q 'aap-demo-ao' "$ROOT_DIR/addons/keycloak/deploy.sh" || {
  echo "FAIL: AO client missing"
  exit 1
}
grep -q 'KC_BOOTSTRAP_ADMIN_PASSWORD' "$ROOT_DIR/addons/keycloak/keycloak.yaml" || {
  echo "FAIL: admin secret not wired"
  exit 1
}
grep -q 'chmod 600' "$ROOT_DIR/addons/keycloak/deploy.sh" || {
  echo "FAIL: credential permissions not enforced"
  exit 1
}
grep -q 'addon" != "keycloak"' "$ROOT_DIR/aap-demo.sh" || {
  echo "FAIL: keycloak must not trigger generic addon wiring"
  exit 1
}
grep -q 'REALM_REVISION' "$ROOT_DIR/addons/keycloak/keycloak.yaml" || {
  echo "FAIL: realm revision missing"
  exit 1
}
grep -q '_keycloak_state_dir' "$ROOT_DIR/aap-demo.sh" || {
  echo "FAIL: status credential state missing"
  exit 1
}
grep -q 'aap-oidc-admin' "$ROOT_DIR/aap-demo.sh" || {
  echo "FAIL: status OIDC user missing"
  exit 1
}
grep -q 'aap-oidc-auditor' "$ROOT_DIR/aap-demo.sh" || {
  echo "FAIL: status auditor missing"
  exit 1
}
grep -q 'aap-oidc-developer' "$ROOT_DIR/aap-demo.sh" || {
  echo "FAIL: status developer missing"
  exit 1
}
grep -q "tr -d '\\\\r\\\\n'" "$ROOT_DIR/addons/keycloak/deploy.sh" || {
  echo "FAIL: generated credentials must not include newline"
  exit 1
}
if grep -Eq 'printf.*_keycloak_.*pw' "$ROOT_DIR/aap-demo.sh"; then
  echo "FAIL: status must not print Keycloak passwords"
  exit 1
fi
grep -q 'app.kubernetes.io/managed-by=aap-demo-keycloak' "$ROOT_DIR/addons/keycloak/deploy.sh" || {
  echo "FAIL: namespace ownership marker missing"
  exit 1
}
grep -q 'protected_namespace' "$ROOT_DIR/addons/keycloak/deploy.sh" || {
  echo "FAIL: protected namespace guard missing"
  exit 1
}
if grep -Eq 'redirectUris:.*\\/\\*|post.logout.redirect.uris.*\\/\\*' "$ROOT_DIR/addons/keycloak/deploy.sh"; then
  echo "FAIL: Keycloak redirect URI must not use a wildcard"
  exit 1
fi
grep -q 'KEYCLOAK_AAP_REDIRECT_URI' "$ROOT_DIR/addons/keycloak/deploy.sh" || {
  echo "FAIL: AAP redirect URI must be configurable"
  exit 1
}
grep -q 'automountServiceAccountToken: false' "$ROOT_DIR/addons/keycloak/keycloak.yaml" || {
  echo "FAIL: service-account token automount must be disabled"
  exit 1
}
grep -q 'allowPrivilegeEscalation: false' "$ROOT_DIR/addons/keycloak/keycloak.yaml" || {
  echo "FAIL: privilege escalation must be disabled"
  exit 1
}
grep -q 'drop:' "$ROOT_DIR/addons/keycloak/keycloak.yaml" || {
  echo "FAIL: container capabilities must be dropped"
  exit 1
}
grep -Eq 'KEYCLOAK_IMAGE=.*@sha256:' "$ROOT_DIR/addons/keycloak/deploy.sh" || {
  echo "FAIL: default Keycloak image must be digest pinned"
  exit 1
}
if grep -Eq 'echo.*(PASSWORD|SECRET)' "$ROOT_DIR/addons/keycloak/deploy.sh"; then
  echo "FAIL: possible secret output"
  exit 1
fi
echo "PASS: Keycloak addon static checks"
