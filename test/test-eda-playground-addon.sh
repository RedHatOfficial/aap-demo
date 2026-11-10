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
for required in \
  'aap-demo enable eda-playground' \
  'aap-demo disable eda-playground' \
  'legacy Bash' \
  'macOS and Linux' \
  'ghcr.io/bbgrimmett2/eda-playground' \
  'EDA_PLAYGROUND_IMAGE' \
  'OAuth' \
  'not supported for production'; do
  grep -Fq "$required" "$README" || fail "README missing: $required"
done

LIVE="$ROOT_DIR/test/test-eda-playground-live.sh"
[ -f "$LIVE" ] || fail "live smoke-test harness missing"
LIVE_SKIP="$(AAP_DEMO_RUN_LIVE_TESTS=false bash "$LIVE" 2>&1)" || fail "opt-in live test must skip successfully"
[[ "$LIVE_SKIP" == *'SKIP:'* ]] || fail "opt-in live test must explain the skip"

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
cat >"$MOCK_BIN/live/aap-demo" <<'MOCK_LIVE_CLI'
#!/usr/bin/env bash
printf 'cli %s\n' "$*" >>"$LIVE_LOG"
echo 'fixture-secret' >&2
MOCK_LIVE_CLI
cat >"$MOCK_BIN/live/kubectl" <<'MOCK_LIVE_KUBECTL'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$LIVE_LOG"
case "$*" in
  "get route eda-playground -n eda-playground -o jsonpath={.spec.host}") printf 'eda.example.test' ;;
esac
MOCK_LIVE_KUBECTL
chmod +x "$MOCK_BIN/live/aap-demo" "$MOCK_BIN/live/kubectl"
LIVE_LOG="$MOCK_BIN/live/commands" \
  AAP_DEMO_CLI="$MOCK_BIN/live/aap-demo" AAP_DEMO_RUN_LIVE_TESTS=true \
  PATH="$MOCK_BIN/live:$PATH" bash "$LIVE" >"$MOCK_BIN/live/output" 2>&1 \
  || fail "enabled live harness failed with controlled commands"
! grep -Fq 'fixture-secret' "$MOCK_BIN/live/output" || fail "live harness printed credentials"
grep -Fxq 'Route host: eda.example.test' "$MOCK_BIN/live/output" || fail "live harness did not print route host"
cat >"$MOCK_BIN/live/expected" <<'EXPECTED_LIVE'
cli enable eda-playground
kubectl wait --for=condition=available deployment/eda-playground -n eda-playground --timeout=180s
kubectl get route eda-playground -n eda-playground -o jsonpath={.spec.host}
cli disable eda-playground
cli disable eda-playground
kubectl get namespace eda-playground --ignore-not-found -o name
EXPECTED_LIVE
cmp -s "$MOCK_BIN/live/expected" "$MOCK_BIN/live/commands" \
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
