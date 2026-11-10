#!/usr/bin/env bash
# Run only on a disposable AAP demo cluster. Browser OAuth login is manual.
set +x
set -euo pipefail

if [ "${AAP_DEMO_RUN_LIVE_TESTS:-}" != true ]; then
  echo 'SKIP: set AAP_DEMO_RUN_LIVE_TESTS=true to run EDA Playground live checks on a disposable cluster'
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${AAP_DEMO_CLI:-$ROOT_DIR/aap-demo.sh}"
NAMESPACE="${EDA_PLAYGROUND_NAMESPACE:-eda-playground}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

"$CLI" enable eda-playground >/dev/null 2>&1 || fail 'enable eda-playground failed'
kubectl wait --for=condition=available deployment/eda-playground -n "$NAMESPACE" --timeout=180s \
  >/dev/null 2>&1 || fail 'EDA Playground Deployment did not become available'
HOST="$(kubectl get route eda-playground -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)" \
  || fail 'EDA Playground Route lookup failed'
[[ "$HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] \
  || fail 'EDA Playground Route has no valid host'
printf 'Route host: %s\n' "$HOST"

# For a manual OAuth check, enable again, open the Route, then disable.
"$CLI" disable eda-playground >/dev/null 2>&1 || fail 'first disable eda-playground failed'
"$CLI" disable eda-playground >/dev/null 2>&1 || fail 'second disable eda-playground failed'
REMAINING="$(kubectl get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)" \
  || fail 'EDA Playground namespace lookup failed'
[ -z "$REMAINING" ] || fail 'EDA Playground namespace remains after disable'

echo 'PASS: EDA Playground enable, readiness, Route, and repeated disable'
