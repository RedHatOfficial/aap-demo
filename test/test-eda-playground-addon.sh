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

CLI="$ROOT_DIR/aap-demo.sh"
HELP="$(QUIET=true "$CLI" help)"
printf '%s\n' "$HELP" | grep -Fq 'eda-playground' || fail "help must list EDA Playground"
printf '%s\n' "$HELP" | grep -Fq 'EDA Playground for testing event-driven integrations' || fail "help must describe EDA Playground"
AVAILABLE_LINE="$(grep '^AVAILABLE_ADDONS=' "$CLI")"
[[ " $AVAILABLE_LINE " == *" eda-playground"* ]] || fail "AVAILABLE_ADDONS must list EDA Playground"
grep -Eq '^[[:space:]]*fleet \| mcp-server.*\| eda-playground\)' "$CLI" || fail "enable/disable parser must accept EDA Playground"
grep -Fq 'for a in $AVAILABLE_ADDONS; do' "$CLI" || fail "legacy status must read AVAILABLE_ADDONS"
grep -Fq 'addons/${addon}' "$CLI" || fail "CLI must resolve addon deploy path"

for file in README.md deploy.sh namespace.yaml configmap.yaml service.yaml deployment.yaml route.yaml; do
  [ -f "$ADDON_DIR/$file" ] || fail "missing addon file: $file"
done

README="$ADDON_DIR/README.md"
DEPLOY="$ADDON_DIR/deploy.sh"
grep -Fq 'EDA_PLAYGROUND_IMAGE:-}' "$DEPLOY" || fail "deployment must require an explicit image"
grep -Fq 'EDA_PLAYGROUND_ALLOW_UNPINNED_IMAGE' "$DEPLOY" || fail "deployment must make unpinned images explicit"
grep -Fq -- '--insecure' "$DEPLOY" || fail "deployment must make insecure TLS explicit"
grep -Fq 'existing OAuth application is not owned' "$DEPLOY" \
  || fail "deployment must reject unowned OAuth applications"
for required in \
  'aap-demo enable eda-playground' \
  'aap-demo disable eda-playground' \
  'legacy Bash' \
  'macOS and Linux' \
  'ghcr.io/bbgrimmett2/eda-playground' \
  'EDA_PLAYGROUND_IMAGE' \
  'OAuth' \
  'not supported for production' \
  'AAP_DEMO_RUN_LIVE_TESTS=true' \
  'AAP_DEMO_LIVE_NONINTERACTIVE=true'; do
  grep -Fq "$required" "$README" || fail "README missing: $required"
done
README_ENABLE_LINE="$(grep -n -m1 'aap-demo enable eda-playground' "$README" | cut -d: -f1)"
README_OAUTH_LINE="$(grep -n -m1 'complete AAP Gateway OAuth login manually' "$README" | cut -d: -f1)"
README_DISABLE_LINE="$(grep -n -m1 'aap-demo disable eda-playground' "$README" | cut -d: -f1)"
[ "$README_ENABLE_LINE" -lt "$README_OAUTH_LINE" ] && [ "$README_OAUTH_LINE" -lt "$README_DISABLE_LINE" ] \
  || fail "README must place manual OAuth access between enable and disable"

GUIDE="$ROOT_DIR/docs/guides/addons.md"
GUIDE_ENABLE_LINE="$(grep -n -m1 'aap-demo enable eda-playground' "$GUIDE" | cut -d: -f1)"
GUIDE_OAUTH_LINE="$(grep -n -m1 'finish AAP OAuth login manually' "$GUIDE" | cut -d: -f1)"
GUIDE_DISABLE_LINE="$(grep -n -m1 'aap-demo disable eda-playground' "$GUIDE" | cut -d: -f1)"
[ "$GUIDE_ENABLE_LINE" -lt "$GUIDE_OAUTH_LINE" ] && [ "$GUIDE_OAUTH_LINE" -lt "$GUIDE_DISABLE_LINE" ] \
  || fail "addon guide must place manual OAuth access between enable and disable"
grep -Fq 'AAP_DEMO_LIVE_NONINTERACTIVE=true' "$GUIDE" \
  || fail "addon guide must document the noninteractive live override"

LIVE="$ROOT_DIR/test/test-eda-playground-live.sh"
[ -f "$LIVE" ] || fail "live smoke-test harness missing"
LIVE_HELP="$(bash "$LIVE" --help 2>&1)" || fail "live harness help failed"
grep -Fq 'AAP_DEMO_LIVE_NONINTERACTIVE=true' <<<"$LIVE_HELP" \
  || fail "live harness help must document the noninteractive override"
grep -Fq 'default behavior waits' <<<"$LIVE_HELP" \
  || fail "live harness help must document the interactive default"
LIVE_SKIP="$(AAP_DEMO_RUN_LIVE_TESTS=false bash "$LIVE" 2>&1)" || fail "opt-in live test must skip successfully"
[[ "$LIVE_SKIP" == *'SKIP:'* ]] || fail "opt-in live test must explain the skip"
grep -Fq 'aap_demo_resolve_kubeconfig' "$LIVE" || fail "live test must resolve the CLI kubeconfig"
grep -Fq 'export KUBECONFIG=' "$LIVE" || fail "live test must pin KUBECONFIG"
grep -Fq 'config current-context' "$LIVE" || fail "live test must establish cluster context"
grep -Fq 'config view --minify' "$LIVE" || fail "live test must establish API identity"
grep -Fq 'trap cleanup_on_exit EXIT' "$LIVE" || fail "live test must register failure cleanup"
grep -Fq 'exit "$status"' "$LIVE" || fail "live test must preserve original status"
grep -Fq 'disable eda-playground' "$LIVE" || fail "live test cleanup must disable the addon"
grep -Fq -- '--kubeconfig "$LIVE_KUBECONFIG"' "$LIVE" \
  || fail "legacy CLI calls must pass the pinned kubeconfig explicitly"
grep -Fq 'AAP_DEMO_LIVE_NONINTERACTIVE' "$LIVE" || fail "live test must expose the noninteractive override"
grep -Fq 'read -r' "$LIVE" || fail "interactive checkpoint must wait for Enter"
grep -Fq 'Browser OAuth verification remains manual' "$LIVE" \
  || fail "noninteractive live run must state manual browser verification"

for file in namespace.yaml configmap.yaml service.yaml deployment.yaml route.yaml; do
  grep -q '^apiVersion:' "$ADDON_DIR/$file" || fail "$file missing apiVersion"
  grep -q '^kind:' "$ADDON_DIR/$file" || fail "$file missing kind"
done

grep -q '^  name: eda-playground$' "$ADDON_DIR/namespace.yaml" || fail "dedicated namespace missing"
grep -q '^kind: ServiceAccount$' "$ADDON_DIR/namespace.yaml" || fail "dedicated ServiceAccount resource missing"
grep -q '^      serviceAccountName: eda-playground$' "$ADDON_DIR/deployment.yaml" || fail "dedicated service account missing"
for oauth_pair in 'OAUTH_CLIENT_ID:client-id' 'OAUTH_CLIENT_SECRET:client-secret' 'SESSION_SECRET:session-secret'; do
  oauth_variable="${oauth_pair%%:*}"
  secret_key="${oauth_pair#*:}"
  oauth_block="$(grep -A5 -F "name: $oauth_variable" "$ADDON_DIR/deployment.yaml" || true)"
  printf '%s\n' "$oauth_block" | grep -Fq 'name: eda-playground-oauth' \
    || fail "$oauth_variable must reference Secret eda-playground-oauth"
  printf '%s\n' "$oauth_block" | grep -Fq "key: $secret_key" \
    || fail "$oauth_variable must reference OAuth Secret key $secret_key"
done
grep -q 'name: eda-playground-oauth' "$ADDON_DIR/deployment.yaml" || fail "OAuth Secret name missing"
grep -q 'readinessProbe:' "$ADDON_DIR/deployment.yaml" || fail "readiness probe missing"
grep -q 'livenessProbe:' "$ADDON_DIR/deployment.yaml" || fail "liveness probe missing"
grep -A3 'requests:' "$ADDON_DIR/deployment.yaml" | grep -Fq 'cpu: 100m' || fail "CPU request must be bounded at 100m"
grep -A3 'requests:' "$ADDON_DIR/deployment.yaml" | grep -Fq 'memory: 128Mi' || fail "memory request must be bounded at 128Mi"
grep -A3 'limits:' "$ADDON_DIR/deployment.yaml" | grep -Fq 'cpu: 500m' || fail "CPU limit must be bounded at 500m"
grep -A3 'limits:' "$ADDON_DIR/deployment.yaml" | grep -Fq 'memory: 512Mi' || fail "memory limit must be bounded at 512Mi"
grep -q '__EDA_PLAYGROUND_ROUTE_HOST__' "$ADDON_DIR/route.yaml" || fail "Route host template missing"
grep -Fq 'app.kubernetes.io/managed-by: aap-demo-eda-playground' "$ADDON_DIR/namespace.yaml" || fail "addon ownership marker missing"
grep -Fq 'app\.kubernetes\.io/managed-by' "$ADDON_DIR/deploy.sh" || fail "cleanup ownership validation missing"

MOCK_BIN="$(mktemp -d)"
trap 'rm -rf "$MOCK_BIN"' EXIT
mkdir -p "$MOCK_BIN/live"
LIVE_LOG="$MOCK_BIN/live/commands"
LIVE_FAIL_LOG="$MOCK_BIN/live/failure-commands"
cat >"$MOCK_BIN/live/kubectl" <<'MOCK_LIVE_FAIL_KUBECTL'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$LIVE_LOG"
case "$1 $2" in
  "config current-context") printf 'aap-demo' ;;
  "config view") printf 'https://127.0.0.1:6443' ;;
  "wait "*) exit 23 ;;
esac
MOCK_LIVE_FAIL_KUBECTL
cat >"$MOCK_BIN/live/aap-demo" <<'MOCK_LIVE_FAIL_CLI'
#!/usr/bin/env bash
printf 'cli %s\n' "$*" >>"$LIVE_FAIL_LOG"
exit 0
MOCK_LIVE_FAIL_CLI
chmod +x "$MOCK_BIN/live/aap-demo" "$MOCK_BIN/live/kubectl"
printf '%s\n' 'fixture-kubeconfig' >"$MOCK_BIN/live/kubeconfig"
set +e
LIVE_LOG="$MOCK_BIN/live/failure-kubectl" LIVE_FAIL_LOG="$MOCK_BIN/live/failure-cli" \
  AAP_DEMO_CLI="$MOCK_BIN/live/aap-demo" AAP_DEMO_RUN_LIVE_TESTS=true \
  KUBECONFIG="$MOCK_BIN/live/kubeconfig" PATH="$MOCK_BIN/live:$PATH" \
  bash "$LIVE" >"$MOCK_BIN/live/failure-output" 2>&1
LIVE_FAILURE_STATUS=$?
set -e
[ "$LIVE_FAILURE_STATUS" -ne 0 ] || fail "live harness must preserve a failed readiness status"
grep -Fxq "cli --kubeconfig $MOCK_BIN/live/kubeconfig disable eda-playground" "$MOCK_BIN/live/failure-cli" \
  || fail "live harness must attempt cleanup after readiness failure"
! grep -Fq 'fixture-secret' "$MOCK_BIN/live/failure-output" || fail "failure cleanup printed credentials"
cat >"$MOCK_BIN/live/aap-demo" <<'MOCK_LIVE_CLI'
#!/usr/bin/env bash
printf 'cli %s\n' "$*" >>"$LIVE_LOG"
echo 'fixture-secret' >&2
MOCK_LIVE_CLI
cat >"$MOCK_BIN/live/kubectl" <<'MOCK_LIVE_KUBECTL'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$LIVE_LOG"
case "$1 $2" in
  "config current-context") printf 'aap-demo' ;;
  "config view") printf 'https://127.0.0.1:6443' ;;
  "get route") printf 'eda.example.test' ;;
esac
MOCK_LIVE_KUBECTL
chmod +x "$MOCK_BIN/live/aap-demo" "$MOCK_BIN/live/kubectl"
printf '\n' | LIVE_LOG="$MOCK_BIN/live/commands" \
  AAP_DEMO_CLI="$MOCK_BIN/live/aap-demo" AAP_DEMO_RUN_LIVE_TESTS=true \
  KUBECONFIG="$MOCK_BIN/live/kubeconfig" \
  PATH="$MOCK_BIN/live:$PATH" bash "$LIVE" >"$MOCK_BIN/live/output" 2>&1 \
  || fail "enabled live harness failed with controlled commands"
! grep -Fq 'fixture-secret' "$MOCK_BIN/live/output" || fail "live harness printed credentials"
grep -Fxq 'Route host: eda.example.test' "$MOCK_BIN/live/output" || fail "live harness did not print route host"
grep -Fq 'Open https://eda.example.test and complete AAP Gateway OAuth login' "$MOCK_BIN/live/output" \
  || fail "default live run must wait for browser verification"
LIVE_LOG="$MOCK_BIN/live/noninteractive-commands" \
  AAP_DEMO_CLI="$MOCK_BIN/live/aap-demo" AAP_DEMO_RUN_LIVE_TESTS=true \
  AAP_DEMO_LIVE_NONINTERACTIVE=true KUBECONFIG="$MOCK_BIN/live/kubeconfig" \
  PATH="$MOCK_BIN/live:$PATH" bash "$LIVE" >"$MOCK_BIN/live/noninteractive-output" 2>&1 \
  || fail "noninteractive live override failed with controlled commands"
grep -Fq 'Browser OAuth verification remains manual and is unverified' \
  "$MOCK_BIN/live/noninteractive-output" || fail "noninteractive live run did not report unverified OAuth"
printf '\n' | LIVE_LOG="$MOCK_BIN/live/interactive-commands" \
  AAP_DEMO_CLI="$MOCK_BIN/live/aap-demo" AAP_DEMO_RUN_LIVE_TESTS=true \
  KUBECONFIG="$MOCK_BIN/live/kubeconfig" \
  PATH="$MOCK_BIN/live:$PATH" bash "$LIVE" >"$MOCK_BIN/live/interactive-output" 2>&1 \
  || fail "interactive live checkpoint failed with controlled commands"
grep -Fq 'Open https://eda.example.test and complete AAP Gateway OAuth login' \
  "$MOCK_BIN/live/interactive-output" || fail "interactive checkpoint did not print the URL"
grep -Fq 'Press Enter when finished' "$MOCK_BIN/live/interactive-output" \
  || fail "interactive checkpoint did not wait for Enter"
sed "s|$MOCK_BIN/live/kubeconfig|LIVE_KUBECONFIG|g" "$MOCK_BIN/live/commands" >"$MOCK_BIN/live/normalized-commands"
cat >"$MOCK_BIN/live/expected" <<'EXPECTED_LIVE'
kubectl config current-context
kubectl config view --minify -o jsonpath={.clusters[0].cluster.server}
cli --kubeconfig LIVE_KUBECONFIG enable eda-playground
kubectl wait --for=condition=available deployment/eda-playground -n eda-playground --timeout=180s
kubectl get route eda-playground -n eda-playground -o jsonpath={.spec.host}
cli --kubeconfig LIVE_KUBECONFIG disable eda-playground
cli --kubeconfig LIVE_KUBECONFIG disable eda-playground
kubectl get namespace eda-playground --ignore-not-found -o name
EXPECTED_LIVE
cmp -s "$MOCK_BIN/live/expected" "$MOCK_BIN/live/normalized-commands" \
  || fail "live harness checks are missing or out of order"
export EDA_PLAYGROUND_STATE_DIR="$MOCK_BIN/state"
mkdir -p "$EDA_PLAYGROUND_STATE_DIR"
home_state_fingerprint() {
  local file
  if [ -d "$HOME/.aap-demo/eda-playground" ]; then
    printf 'directory present\n'
  else
    printf 'directory absent\n'
  fi
  for file in oauth_credentials.json oauth_app_id; do
    if [ -f "$HOME/.aap-demo/eda-playground/$file" ]; then
      cksum <"$HOME/.aap-demo/eda-playground/$file"
    else
      printf '%s absent\n' "$file"
    fi
  done
}
HOME_STATE_BEFORE="$(home_state_fingerprint)"
cat >"$MOCK_BIN/kubectl" <<'MOCK_KUBECTL'
#!/usr/bin/env bash
if [[ "${EDA_PLAYGROUND_STATE_DIR:-}" != "${MOCK_DELETE_LOG%/*}/state" ]]; then
  echo 'FAIL: static cleanup state is not isolated' >&2
  exit 1
fi
case "$1 $2" in
  "cluster-info") exit 0 ;;
  "get namespace")
    if [ "${MOCK_NAMESPACE_EXISTS:-yes}" = no ]; then exit 1; fi
    if [[ " $* " == *" -o jsonpath="* ]]; then printf '%s' "${MOCK_NAMESPACE_OWNER:-}"; fi
    exit 0
    ;;
  "delete namespace") printf 'deleted\n' >>"$MOCK_DELETE_LOG" ;;
esac
MOCK_KUBECTL
cat >"$MOCK_BIN/oc" <<'MOCK_OC'
#!/usr/bin/env bash
case "$*" in
  'adm policy remove-scc-from-user anyuid -z eda-playground -n eda-playground') exit 0 ;;
  *) exit 2 ;;
esac
MOCK_OC
chmod +x "$MOCK_BIN/kubectl"
chmod +x "$MOCK_BIN/oc"

if MOCK_DELETE_LOG="$MOCK_BIN/deletes" MOCK_NAMESPACE_EXISTS=yes MOCK_NAMESPACE_OWNER='' \
  PATH="$MOCK_BIN:$PATH" "$ADDON_DIR/deploy.sh" --delete >/dev/null 2>&1; then
  fail "cleanup accepted an unowned namespace"
fi
[ ! -s "$MOCK_BIN/deletes" ] || fail "cleanup deleted an unowned namespace"

MOCK_DELETE_LOG="$MOCK_BIN/deletes" MOCK_NAMESPACE_EXISTS=yes MOCK_NAMESPACE_OWNER=aap-demo-eda-playground \
  PATH="$MOCK_BIN:$PATH" "$ADDON_DIR/deploy.sh" --delete >/dev/null
[ "$(cat "$MOCK_BIN/deletes")" = deleted ] || fail "cleanup should delete its owned namespace"
[ "$HOME_STATE_BEFORE" = "$(home_state_fingerprint)" ] || fail "static checks changed real home OAuth state"

echo "PASS: EDA Playground addon static checks"
