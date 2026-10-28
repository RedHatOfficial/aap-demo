#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BRIDGE="$ROOT_DIR/addons/ao-pr-testing/playbooks/plaibook-review-bridge.yml"

# The published verdict must describe actionable findings in this PR. The
# upstream verdict is retained separately as review metadata for diagnostics.
grep -Fq 'review_effective_verdict:' "$BRIDGE"
grep -Fq '## Plaibook review: {{ review_effective_verdict }}' "$BRIDGE"
grep -Fq "'verdict': review_effective_verdict" "$BRIDGE"
grep -Fq "'target_verdict': (plaibook_result.targets | default([]) | first).verdict" "$BRIDGE"

echo 'plaibook publication verdict is scoped to current PR findings'
