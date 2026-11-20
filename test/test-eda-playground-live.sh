#!/usr/bin/env bash
# Run only on a disposable AAP demo cluster. Browser OAuth login is manual.
set +x
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: test/test-eda-playground-live.sh

Runs the EDA Playground smoke test on a disposable cluster. After enable and
Route discovery, the default behavior waits for manual browser OAuth verification.
Set AAP_DEMO_LIVE_NONINTERACTIVE=true to skip the wait; OAuth remains unverified.
USAGE
}

case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
esac

if [ "${AAP_DEMO_RUN_LIVE_TESTS:-}" != true ]; then
  echo 'SKIP: set AAP_DEMO_RUN_LIVE_TESTS=true to run EDA Playground live checks on a disposable cluster'
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${AAP_DEMO_CLI:-$ROOT_DIR/aap-demo.sh}"
NAMESPACE="${EDA_PLAYGROUND_NAMESPACE:-eda-playground}"

# Match the legacy CLI's kubeconfig selection and pin it for every child.
# shellcheck source=../includes/aap-demo-paths.sh
source "$ROOT_DIR/includes/aap-demo-paths.sh"
if [ -n "${KUBECONFIG:-}" ]; then
  case "$KUBECONFIG" in
    *:*)
      echo 'FAIL: KUBECONFIG must name one kubeconfig file' >&2
      exit 1
      ;;
  esac
  LIVE_KUBECONFIG="$KUBECONFIG"
else
  LIVE_KUBECONFIG="$(aap_demo_resolve_kubeconfig)"
fi
[ -s "$LIVE_KUBECONFIG" ] || {
  echo "FAIL: selected kubeconfig is missing or empty: $LIVE_KUBECONFIG" >&2
  exit 1
}
export KUBECONFIG="$LIVE_KUBECONFIG"

LIVE_CONTEXT="$(kubectl config current-context 2>/dev/null)" || {
  echo 'FAIL: could not establish the selected kubeconfig context' >&2
  exit 1
}
LIVE_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)" || {
  echo 'FAIL: could not establish the selected cluster API server' >&2
  exit 1
}
[ -n "$LIVE_CONTEXT" ] && [ -n "$LIVE_SERVER" ] || {
  echo 'FAIL: selected cluster identity is incomplete' >&2
  exit 1
}
case "$LIVE_CONTEXT" in
  unknown)
    echo 'FAIL: selected kubeconfig context is unknown' >&2
    exit 1
    ;;
esac
case "$LIVE_SERVER" in
  http://* | https://*) ;;
  *)
    echo 'FAIL: selected cluster API server is invalid' >&2
    exit 1
    ;;
esac

fail() {
  local message="$1" status="${2:-1}"
  echo "FAIL: $message" >&2
  exit "$status"
}

run_quiet() {
  local message="$1" status
  shift
  if "$@" >/dev/null 2>&1; then
    return 0
  else
    status=$?
  fi
  fail "$message" "$status"
}

cleanup_on_exit() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ] && [ "${CLEANUP_REQUIRED:-false}" = true ]; then
    AAP_DEMO_DIR="$LIVE_STATE_ROOT" EDA_PLAYGROUND_STATE_DIR="$STATE_DIR" \
      "$CLI" --kubeconfig "$LIVE_KUBECONFIG" disable eda-playground >/dev/null 2>&1 || true
  fi
  if [ -n "${LIVE_STATE_ROOT:-}" ]; then
    rm -rf -- "$LIVE_STATE_ROOT"
  fi
  exit "$status"
}

# Validate the image before arming cleanup.  The deploy script intentionally
# fails early when no reviewed image is configured, and that failure must not
# trigger cleanup of an installation that existed before this test started.
LIVE_IMAGE="${EDA_PLAYGROUND_IMAGE:-}"
LIVE_ALLOW_UNPINNED="${EDA_PLAYGROUND_ALLOW_UNPINNED_IMAGE:-false}"
if [ -z "$LIVE_IMAGE" ]; then
  fail 'EDA_PLAYGROUND_IMAGE must be set before the live test starts'
fi
if [[ "$LIVE_IMAGE" != *@sha256:* ]] && [ "$LIVE_ALLOW_UNPINNED" != true ]; then
  fail 'EDA_PLAYGROUND_IMAGE must use a sha256 digest before the live test starts'
fi
if EXISTING_NAMESPACE="$(kubectl get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"; then
  :
else
  status=$?
  fail 'could not determine whether the EDA Playground namespace already exists' "$status"
fi
[ -z "$EXISTING_NAMESPACE" ] || fail "refusing to run over existing EDA Playground namespace $NAMESPACE"

# Use a disposable state root for both the legacy and Python CLIs.  The Python
# adapter derives EDA_PLAYGROUND_STATE_DIR from AAP_DEMO_DIR, so checking a
# caller-provided legacy path would not protect cleanup in that mode.
LIVE_STATE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-eda-live.XXXXXX")"
STATE_DIR="$LIVE_STATE_ROOT/eda-playground"

trap cleanup_on_exit EXIT
CLEANUP_REQUIRED=true
run_quiet 'enable eda-playground failed' \
  env AAP_DEMO_DIR="$LIVE_STATE_ROOT" EDA_PLAYGROUND_STATE_DIR="$STATE_DIR" \
  "$CLI" --kubeconfig "$LIVE_KUBECONFIG" enable eda-playground
run_quiet 'EDA Playground Deployment did not become available' \
  kubectl wait --for=condition=available deployment/eda-playground -n "$NAMESPACE" --timeout=180s
if HOST="$(kubectl get route eda-playground -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)"; then
  :
else
  status=$?
  fail 'EDA Playground Route lookup failed' "$status"
fi
[[ "$HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] \
  || fail 'EDA Playground Route has no valid host' 1
printf 'Route host: %s\n' "$HOST"

ROUTE_URL="https://$HOST"
if [ "${AAP_DEMO_LIVE_NONINTERACTIVE:-false}" != true ]; then
  printf 'Open %s and complete AAP Gateway OAuth login in your browser. Press Enter when finished.\n' "$ROUTE_URL"
  IFS= read -r _
else
  printf 'Browser OAuth verification remains manual and is unverified; open %s after enable and before cleanup.\n' "$ROUTE_URL"
fi

run_quiet 'first disable eda-playground failed' \
  env AAP_DEMO_DIR="$LIVE_STATE_ROOT" EDA_PLAYGROUND_STATE_DIR="$STATE_DIR" \
  "$CLI" --kubeconfig "$LIVE_KUBECONFIG" disable eda-playground
run_quiet 'second disable eda-playground failed' \
  env AAP_DEMO_DIR="$LIVE_STATE_ROOT" EDA_PLAYGROUND_STATE_DIR="$STATE_DIR" \
  "$CLI" --kubeconfig "$LIVE_KUBECONFIG" disable eda-playground
if REMAINING="$(kubectl get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"; then
  :
else
  status=$?
  fail 'EDA Playground namespace lookup failed' "$status"
fi
[ -z "$REMAINING" ] || fail 'EDA Playground namespace remains after disable' 1

echo 'PASS: EDA Playground enable, readiness, Route, and repeated disable'
trap - EXIT
rm -rf -- "$LIVE_STATE_ROOT"
LIVE_STATE_ROOT=""
