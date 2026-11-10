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

MOCK_DELETE_LOG="$MOCK_BIN/deletes" MOCK_NAMESPACE_EXISTS=yes MOCK_NAMESPACE_OWNER='' \
  PATH="$MOCK_BIN:$PATH" "$ADDON_DIR/deploy.sh" --delete >/dev/null
[ ! -s "$MOCK_BIN/deletes" ] || fail "cleanup deleted an unowned namespace"

MOCK_DELETE_LOG="$MOCK_BIN/deletes" MOCK_NAMESPACE_EXISTS=yes MOCK_NAMESPACE_OWNER=aap-demo-eda-playground \
  PATH="$MOCK_BIN:$PATH" "$ADDON_DIR/deploy.sh" --delete >/dev/null
[ "$(cat "$MOCK_BIN/deletes")" = deleted ] || fail "cleanup should delete its owned namespace"
[ "$HOME_STATE_BEFORE" = "$(home_state_fingerprint)" ] || fail "static checks changed real home OAuth state"

echo "PASS: EDA Playground addon static checks"
