#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EXPECTED_IMAGE='quay.io/aapdemo/plaibook-ee:latest'
WORKFLOW="$ROOT_DIR/.github/workflows/plaibook-ee.yaml"

grep -Fq "$EXPECTED_IMAGE" "$ROOT_DIR/addons/ao-pr-testing/deploy.sh"
grep -Fq "$EXPECTED_IMAGE" "$ROOT_DIR/addons/ao-pr-testing/README.md"
grep -Fq "$EXPECTED_IMAGE" "$ROOT_DIR/docs/adr/024-ao-pr-testing-addon.md"

grep -Fq 'repository: aknochow/ansible-plaibook' "$WORKFLOW"
grep -Fq 'ansible-builder create' "$WORKFLOW"
if grep -A4 -F 'ansible-builder create' "$WORKFLOW" | grep -Fq -- '--container-runtime'; then
  echo 'ansible-builder create must not receive --container-runtime' >&2
  exit 1
fi
grep -Fq 'quay.io/aapdemo/plaibook-ee' "$WORKFLOW"
grep -Fq 'docker/login-action@v3' "$WORKFLOW"
grep -Fq 'docker build' "$WORKFLOW"
grep -Fq 'docker push' "$WORKFLOW"
if grep -Eq 'docker/(setup-buildx|build-push)-action' "$WORKFLOW"; then
  echo 'EE CI must use the runner Docker engine without external BuildKit bootstrap' >&2
  exit 1
fi
grep -Fq 'GITHUB_EVENT_NAME' "$WORKFLOW"
grep -Fq "[[ \"\$GITHUB_EVENT_NAME\" != 'pull_request' ]]" "$WORKFLOW"
grep -Fq 'secrets.QUAY_PASSWORD' "$WORKFLOW"

if grep -R -E 'quay.io/(aknochow|cferman)/plaibook-ee' \
  "$ROOT_DIR/addons/ao-pr-testing" "$ROOT_DIR/docs/adr/024-ao-pr-testing-addon.md"; then
  echo 'stale plaibook EE image reference found' >&2
  exit 1
fi

echo 'plaibook EE CI configuration is valid'
