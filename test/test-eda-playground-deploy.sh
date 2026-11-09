#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
REAL_JQ="$(command -v jq)" REAL_BASE64="$(command -v base64)"
cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_LOG"
case "$1 $2" in
  'cluster-info ') exit 0 ;;
  'get route') if [ "$3" = aap ]; then echo 'aap-aap-operator.apps.example.test'; elif [ "$MOCK_MICRO" = yes ]; then echo 'eda-playground.apps.example.test'; else echo 'eda-playground.apps.custom.test'; fi ;;
  'get secret') printf '%s' "$MOCK_PASSWORD_B64" ;;
  'get ingresses.config/cluster') [ "$MOCK_MICRO" = yes ] && exit 1; echo 'apps.custom.test' ;;
  'get svc') echo '10.43.0.20' ;;
  'create -f')
    if [[ " $* " == *' --dry-run=client '* ]]; then cat; else exit 9; fi ;;
  'apply -f') cat >>"$MOCK_MANIFEST" ;;
  'patch deployment') printf '%s\n' "$*" >>"$MOCK_PATCH" ;;
esac
STUB
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_LOG"
case " $* " in
  *'/ping/'*) echo '{"ping":"pong"}' ;;
  *'/organizations/'*)
    if [[ " $* " == *' -X POST '* ]]; then echo '{"id":7,"name":"Default"}'; elif [ "$MOCK_CASE" = first ]; then echo '{"count":0,"results":[]}'; else echo '{"count":1,"results":[{"id":7,"name":"Default"}]}'; fi ;;
  *'/applications/?'*) if [ "$MOCK_CASE" = first ]; then echo '{"count":0,"results":[]}'; else echo '{"count":1,"results":[{"id":42,"name":"EDA Playground","client_id":"client-existing"}]}'; fi ;;
  *'/applications/'*) if [[ " $* " == *' -X POST '* ]]; then echo '{"id":43,"client_id":"client-new","client_secret":"fixture-client-secret"}'; else echo '{}'; fi ;;
esac
STUB
cat >"$TMP/bin/openssl" <<'STUB'
#!/usr/bin/env bash
[ "$*" = 'rand -hex 16' ] || exit 2
echo fixture-session-secret
STUB
cat >"$TMP/bin/jq" <<'STUB'
#!/usr/bin/env bash
exec "$REAL_JQ" "$@"
STUB
cat >"$TMP/bin/base64" <<'STUB'
#!/usr/bin/env bash
exec "$REAL_BASE64" "$@"
STUB
cat >"$TMP/bin/oc" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "oc $*" >>"$MOCK_LOG"
STUB
chmod +x "$TMP/bin/"*
fail() {
  echo "FAIL: $1" >&2
  exit 1
}
assert_log() { grep -Fq -- "$1" "$MOCK_LOG" || fail "$2"; }
run_case() {
  local case_name="$1"
  mkdir -p "$TMP/$case_name"
  export MOCK_CASE="$case_name" MOCK_LOG="$TMP/$case_name/log" MOCK_MANIFEST="$TMP/$case_name/manifest" MOCK_PATCH="$TMP/$case_name/patch"
  export EDA_PLAYGROUND_STATE_DIR="$TMP/$case_name/state" MOCK_MICRO=no
  export MOCK_PASSWORD_B64
  MOCK_PASSWORD_B64="$(printf '%s' fixture-admin-password | "$REAL_BASE64" | tr -d '\n')"
  : >"$MOCK_LOG"
  : >"$MOCK_MANIFEST"
  : >"$MOCK_PATCH"
  if [ "$case_name" = reuse ]; then
    mkdir -p "$EDA_PLAYGROUND_STATE_DIR"
    printf '%s\n' '{"oauth_app_id":"42","client_id":"client-existing","client_secret":"fixture-saved-secret"}' >"$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
  fi
  if [ "$case_name" = micro ]; then export MOCK_MICRO=yes; fi
  PATH="$TMP/bin:$PATH" REAL_JQ="$REAL_JQ" REAL_BASE64="$REAL_BASE64" "$ROOT/addons/eda-playground/deploy.sh" >"$TMP/$case_name/out" 2>&1 || {
    cat "$TMP/$case_name/out"
    fail "$case_name deploy"
  }
  for secret in fixture-admin-password fixture-client-secret fixture-session-secret fixture-saved-secret; do
    ! grep -Fq "$secret" "$TMP/$case_name/out" || fail "$case_name exposed $secret"
  done
}
run_case first
PATH="$TMP/bin:$PATH" REAL_JQ="$REAL_JQ" REAL_BASE64="$REAL_BASE64" bash -x "$ROOT/addons/eda-playground/deploy.sh" >"$TMP/first/traced-out" 2>&1 || fail "traced deploy"
for secret in fixture-admin-password fixture-client-secret fixture-session-secret; do
  ! grep -Fq "$secret" "$TMP/first/traced-out" || fail "tracing exposed $secret"
done
assert_log '-X POST https://aap-aap-operator.apps.example.test/api/gateway/v1/organizations/' 'first should create organization'
assert_log '-X POST https://aap-aap-operator.apps.example.test/api/gateway/v1/applications/' 'first should create application'
[ "$(stat -f %Lp "$EDA_PLAYGROUND_STATE_DIR")" = 700 ] || fail 'state directory permissions'
[ "$(stat -f %Lp "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json")" = 600 ] || fail 'credentials permissions'
grep -Fq 'eda-playground.apps.custom.test' "$MOCK_MANIFEST" || fail 'route domain not rendered'
grep -Fq 'https://aap-aap-operator.apps.example.test' "$MOCK_MANIFEST" || fail 'AAP base URL not rendered'
grep -Fq 'https://eda-playground.apps.custom.test/auth/callback' "$MOCK_MANIFEST" || fail 'callback env not rendered'
grep -Fq 'name: AAP_CLIENT_ID' "$MOCK_MANIFEST" || fail 'AAP client ID env absent'
grep -Fq 'name: AAP_CLIENT_SECRET' "$MOCK_MANIFEST" || fail 'AAP client secret env absent'
assert_log 'https://eda-playground.apps.custom.test/auth/callback' 'redirect not updated'
run_case reuse
! grep -Fq -- '-X DELETE' "$MOCK_LOG" || fail 'reuse deleted application'
! grep -Fq -- '-X POST https://aap-aap-operator.apps.example.test/api/gateway/v1/applications/' "$MOCK_LOG" || fail 'reuse created application'
grep -Fq 'fixture-saved-secret' "$MOCK_MANIFEST" || fail 'saved secret not reused'
assert_log 'create -f - --dry-run=client -o yaml' 'Secret must support repeat apply'
run_case missing
assert_log '-X DELETE https://aap-aap-operator.apps.example.test/api/gateway/v1/applications/42/' 'missing secret should delete owned app'
assert_log '-X POST https://aap-aap-operator.apps.example.test/api/gateway/v1/applications/' 'missing secret should recreate app'
run_case micro
assert_log 'get svc aap -n aap-operator' 'MicroShift service not resolved'
grep -Fq '10.43.0.20' "$MOCK_PATCH" || fail 'host alias IP absent'
grep -Fq 'aap-aap-operator.apps.example.test' "$MOCK_PATCH" || fail 'host alias hostname absent'
grep -Fq 'http://aap-aap-operator.apps.example.test' "$MOCK_MANIFEST" || fail 'MicroShift AAP URL not rendered'
assert_log 'rollout status deployment/eda-playground' 'rollout not awaited'
echo 'PASS: EDA Playground deploy OAuth, reuse, recreate, domain, MicroShift, redaction'
