#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EXPECTED_IMAGE='ghcr.io/aknochow/plaibook-ee:latest'
WORKFLOW="$ROOT_DIR/.github/workflows/plaibook-ee.yaml"

grep -Fq "$EXPECTED_IMAGE" "$ROOT_DIR/addons/ao-pr-testing/deploy.sh"
grep -Fq "$EXPECTED_IMAGE" "$ROOT_DIR/addons/ao-pr-testing/README.md"
grep -Fq "$EXPECTED_IMAGE" "$ROOT_DIR/docs/adr/024-ao-pr-testing-addon.md"

if [ -e "$WORKFLOW" ]; then
  echo 'local plaibook EE publishing workflow should not be needed' >&2
  exit 1
fi

if grep -R -E 'quay.io/(aapdemo|aknochow|cferman)/plaibook-ee' \
  "$ROOT_DIR/addons/ao-pr-testing" "$ROOT_DIR/docs/adr/024-ao-pr-testing-addon.md"; then
  echo 'stale plaibook EE image reference found' >&2
  exit 1
fi

echo 'plaibook EE CI configuration is valid'
