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
  'get route') if [ "$3" = aap ]; then [ "$MOCK_CASE" = route_fail ] && exit 1; echo 'aap-aap-operator.apps.example.test'; elif [ "$MOCK_MICRO" = yes ]; then echo 'eda-playground.apps.example.test'; else echo 'eda-playground.apps.custom.test'; fi ;;
  'get secret') [ "$MOCK_CASE" = secret_fail ] && exit 1; printf '%s' "$MOCK_PASSWORD_B64" ;;
  'get deployment')
    if [ -s "$MOCK_CURRENT_REVISION_FILE" ]; then
      cat "$MOCK_CURRENT_REVISION_FILE"
    else
      exit 0
    fi
    ;;
  'rollout status') [ "$MOCK_CASE" = rollout_fail ] && exit 1; exit 0 ;;
  'get ingresses.config/cluster') [ "$MOCK_MICRO" = yes ] && exit 1; echo 'apps.custom.test' ;;
  'get svc') echo '10.43.0.20' ;;
  'create -f')
    if [[ " $* " == *' --dry-run=client '* ]]; then cat; else exit 9; fi ;;
  'apply -f') payload="$(cat)"; printf '%s\n' "$payload" >>"$MOCK_MANIFEST"; [[ "$payload" == *'kind: Deployment'* ]] && echo 'apply deployment' >>"$MOCK_LOG"; exit 0 ;;
  'patch deployment')
    printf '%s\n' "$*" >>"$MOCK_PATCH"
    printf '%s\n' "$*" >>"$MOCK_LOG"
    ;;
esac
STUB
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_LOG"
case " $* " in
  *'/ping/'*) echo '{"ping":"pong"}' ;;
  *'/organizations/'*)
    if [[ " $* " == *' -X POST '* ]]; then echo '{"id":7,"name":"Default"}'; elif [ "$MOCK_CASE" = first ]; then echo '{"count":0,"results":[]}'; else echo '{"count":1,"results":[{"id":7,"name":"Default"}]}'; fi ;;
  *'/applications/?'*) if [ "$MOCK_CASE" = first ]; then echo '{"count":0,"results":[]}'; elif [[ "$MOCK_CASE" = later_saved || "$MOCK_CASE" = ambiguous ]]; then echo '{"count":2,"results":[{"id":41,"name":"EDA Playground","client_id":"client-wrong"},{"id":42,"name":"EDA Playground","client_id":"client-existing"}]}'; else echo '{"count":1,"results":[{"id":42,"name":"EDA Playground","client_id":"client-existing"}]}'; fi ;;
  *'/applications/'*) if [[ " $* " == *' -X POST '* ]]; then echo '{"id":43,"client_id":"client-new","client_secret":"fixture-client-secret"}'; elif [ "$MOCK_CASE" = patch_secret_fail ] && [[ " $* " == *' -X PATCH '* ]]; then echo '{"client_secret":"fixture-client-secret","password":"fixture-admin-password","session":"fixture-session-secret"}' >&2; exit 22; else echo '{}'; fi ;;
esac
STUB
cat >"$TMP/bin/openssl" <<'STUB'
#!/usr/bin/env bash
[ "$*" = 'rand -hex 16' ] || exit 2
echo fixture-session-secret
STUB
cat >"$TMP/bin/date" <<'STUB'
#!/usr/bin/env bash
printf '1700000000\n'
STUB
cat >"$TMP/bin/jq" <<'STUB'
#!/usr/bin/env bash
printf 'jq %s\n' "$*" >>"$MOCK_LOG"
exec "$REAL_JQ" "$@"
STUB
cat >"$TMP/bin/base64" <<'STUB'
#!/usr/bin/env bash
printf 'base64 %s\n' "$*" >>"$MOCK_LOG"
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
first_line() { grep -nF -- "$1" "$MOCK_LOG" | head -1 | cut -d: -f1; }
run_case() {
  local case_name="$1"
  mkdir -p "$TMP/$case_name"
  export MOCK_CASE="$case_name" MOCK_LOG="$TMP/$case_name/log" MOCK_MANIFEST="$TMP/$case_name/manifest" MOCK_PATCH="$TMP/$case_name/patch" MOCK_CURRENT_REVISION_FILE="$TMP/$case_name/current-revision"
  export EDA_PLAYGROUND_STATE_DIR="$TMP/$case_name/state" MOCK_MICRO=no
  if [ "$case_name" = custom_namespace ]; then
    export EDA_PLAYGROUND_NAMESPACE=custom-demo
  else
    unset EDA_PLAYGROUND_NAMESPACE || true
  fi
  export MOCK_PASSWORD_B64
  MOCK_PASSWORD_B64="$(printf '%s' fixture-admin-password | "$REAL_BASE64" | tr -d '\n')"
  : >"$MOCK_LOG"
  : >"$MOCK_MANIFEST"
  : >"$MOCK_PATCH"
  : >"$MOCK_CURRENT_REVISION_FILE"
  if [[ "$case_name" = reuse || "$case_name" = later_saved ]]; then
    mkdir -p "$EDA_PLAYGROUND_STATE_DIR"
    printf '%s\n' '{"oauth_app_id":"42","client_id":"client-existing","client_secret":"fixture-saved-secret"}' >"$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
  fi
  if [[ "$case_name" = micro || "$case_name" = micro_override ]]; then export MOCK_MICRO=yes; fi
  if [ "$case_name" = micro_override ]; then export EDA_PLAYGROUND_DOMAIN=apps.override.test; else unset EDA_PLAYGROUND_DOMAIN || true; fi
  PATH="$TMP/bin:$PATH" REAL_JQ="$REAL_JQ" REAL_BASE64="$REAL_BASE64" "$ROOT/addons/eda-playground/deploy.sh" >"$TMP/$case_name/out" 2>&1 || {
    cat "$TMP/$case_name/out"
    fail "$case_name deploy"
  }
  for secret in fixture-admin-password fixture-client-secret fixture-session-secret fixture-saved-secret; do
    ! grep -Fq "$secret" "$MOCK_LOG" || fail "$case_name exposed $secret in argv"
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
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
[ "$(mode "$EDA_PLAYGROUND_STATE_DIR")" = 700 ] || fail 'state directory permissions'
[ "$(mode "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json")" = 600 ] || fail 'credentials permissions'
grep -Fq 'eda-playground.apps.custom.test' "$MOCK_MANIFEST" || fail 'route domain not rendered'
grep -Fq 'https://aap-aap-operator.apps.example.test' "$MOCK_MANIFEST" || fail 'AAP base URL not rendered'
grep -Fq 'https://eda-playground.apps.custom.test/auth/callback' "$MOCK_MANIFEST" || fail 'callback env not rendered'
grep -Fq 'name: AAP_CLIENT_ID' "$MOCK_MANIFEST" || fail 'AAP client ID env absent'
grep -Fq 'name: AAP_CLIENT_SECRET' "$MOCK_MANIFEST" || fail 'AAP client secret env absent'
assert_log 'https://eda-playground.apps.custom.test/auth/callback' 'redirect not updated'
assert_log 'aap-demo/revision' 'pod template revision bump missing'
[ "$(first_line 'aap-demo/revision')" -lt "$(first_line 'rollout status deployment/eda-playground')" ] || fail 'revision bump must precede rollout'
MOCK_CASE=repeat PATH="$TMP/bin:$PATH" REAL_JQ="$REAL_JQ" REAL_BASE64="$REAL_BASE64" \
  "$ROOT/addons/eda-playground/deploy.sh" >"$TMP/first/repeat.out" 2>&1 || {
  cat "$TMP/first/repeat.out"
  fail 'repeat deploy'
}
assert_log 'aap-demo/revision' 'repeat deploy missing revision bump'
run_case reuse
! grep -Fq -- '-X DELETE' "$MOCK_LOG" || fail 'reuse deleted application'
! grep -Fq -- '-X POST https://aap-aap-operator.apps.example.test/api/gateway/v1/applications/' "$MOCK_LOG" || fail 'reuse created application'
grep -Fq 'fixture-saved-secret' "$MOCK_MANIFEST" || fail 'saved secret not reused'
assert_log 'create -f - --dry-run=client -o yaml' 'Secret must support repeat apply'
run_case later_saved
! grep -Fq -- '-X DELETE' "$MOCK_LOG" || fail 'later saved ID deleted an app'
! grep -Fq -- '-X POST https://aap-aap-operator.apps.example.test/api/gateway/v1/applications/' "$MOCK_LOG" || fail 'later saved ID created an app'
grep -Fq 'fixture-saved-secret' "$MOCK_MANIFEST" || fail 'later saved ID secret not reused'
run_case missing
assert_log '-X DELETE https://aap-aap-operator.apps.example.test/api/gateway/v1/applications/42/' 'missing secret should delete owned app'
assert_log '-X POST https://aap-aap-operator.apps.example.test/api/gateway/v1/applications/' 'missing secret should recreate app'
run_case micro
assert_log 'get svc aap -n aap-operator' 'MicroShift service not resolved'
grep -Fq '10.43.0.20' "$MOCK_PATCH" || fail 'host alias IP absent'
grep -Fq 'aap-aap-operator.apps.example.test' "$MOCK_PATCH" || fail 'host alias hostname absent'
grep -Fq 'http://aap-aap-operator.apps.example.test' "$MOCK_MANIFEST" || fail 'MicroShift AAP URL not rendered'
assert_log 'rollout status deployment/eda-playground' 'rollout not awaited'
run_case micro_override
assert_log 'get svc aap -n aap-operator' 'override skipped MicroShift detection'
grep -Fq 'http://aap-aap-operator.apps.example.test' "$MOCK_MANIFEST" || fail 'override lost MicroShift HTTP URL'
grep -Fq 'eda-playground.apps.override.test' "$MOCK_MANIFEST" || fail 'override domain not rendered'
first_line() { grep -nF -- "$1" "$MOCK_LOG" | head -1 | cut -d: -f1; }
[ "$(first_line 'oc adm policy add-scc-to-user anyuid')" -lt "$(first_line 'apply deployment')" ] || fail 'SCC grant must precede manifest apply'
assert_log 'rollout status deployment/eda-playground -n eda-playground --timeout=' 'rollout timeout absent'
run_case custom_namespace
grep -Fq 'name: custom-demo' "$MOCK_MANIFEST" || fail 'custom namespace not rendered'
service_account_block="$(grep -A4 -F 'kind: ServiceAccount' "$MOCK_MANIFEST" || true)"
grep -Fq 'name: eda-playground' <<<"$service_account_block" || fail 'fixed service account name missing'
grep -Fq 'serviceAccountName: eda-playground' "$MOCK_MANIFEST" || fail 'Deployment service account name changed'
assert_log 'oc adm policy add-scc-to-user anyuid -z eda-playground -n custom-demo' 'SCC target changed'
assert_log 'rollout status deployment/eda-playground -n custom-demo --timeout=' 'rollout namespace changed'
run_case revision_collision
revision_patch_lines="$(grep 'patch deployment' "$MOCK_LOG" || true)"
revision_patch_blob="$(tr '\n' ' ' <"$MOCK_PATCH")"
first_revision="$(grep -o 'aap-demo/revision[^0-9]*[0-9][0-9]*' <<<"$revision_patch_blob" | grep -o '[0-9][0-9]*' | head -1 || true)"
[ -n "$first_revision" ] || fail 'first revision annotation missing'
printf '%s' "$first_revision" >"$MOCK_CURRENT_REVISION_FILE"
MOCK_CASE=revision_collision PATH="$TMP/bin:$PATH" REAL_JQ="$REAL_JQ" REAL_BASE64="$REAL_BASE64" \
  "$ROOT/addons/eda-playground/deploy.sh" >"$TMP/revision_collision/repeat.out" 2>&1 || {
  cat "$TMP/revision_collision/repeat.out"
  fail 'same-clock repeat deploy'
}
revision_patch_lines="$(grep 'patch deployment' "$MOCK_LOG" || true)"
revision_patch_blob="$(tr '\n' ' ' <"$MOCK_PATCH")"
second_revision="$(grep -o 'aap-demo/revision[^0-9]*[0-9][0-9]*' <<<"$revision_patch_blob" | grep -o '[0-9][0-9]*' | tail -1 || true)"
[ -n "$second_revision" ] || fail 'second revision annotation missing'
[ "$first_revision" != "$second_revision" ] || fail 'same-clock revision collided'
for failure in route_fail secret_fail rollout_fail patch_secret_fail; do
  export MOCK_CASE="$failure" MOCK_LOG="$TMP/$failure.log" MOCK_MANIFEST="$TMP/$failure.manifest" MOCK_PATCH="$TMP/$failure.patch" MOCK_MICRO=no
  export EDA_PLAYGROUND_STATE_DIR="$TMP/$failure/state"
  : >"$MOCK_LOG"
  : >"$MOCK_MANIFEST"
  : >"$MOCK_PATCH"
  if PATH="$TMP/bin:$PATH" REAL_JQ="$REAL_JQ" REAL_BASE64="$REAL_BASE64" "$ROOT/addons/eda-playground/deploy.sh" >"$TMP/$failure.out" 2>&1; then fail "$failure unexpectedly passed"; fi
  case "$failure" in
    route_fail) grep -Fq 'AAP route unavailable' "$TMP/$failure.out" || fail 'route failure diagnostic' ;;
    secret_fail) grep -Fq 'AAP admin Secret unavailable' "$TMP/$failure.out" || fail 'Secret failure diagnostic' ;;
    rollout_fail) grep -Fq 'rollout' "$TMP/$failure.out" || fail 'rollout recovery guidance' ;;
    patch_secret_fail)
      grep -Fq 'OAuth redirect update failed' "$TMP/$failure.out" || fail 'PATCH failure diagnostic'
      for secret in fixture-admin-password fixture-client-secret fixture-session-secret; do
        ! grep -Fq "$secret" "$TMP/$failure.out" || fail "PATCH failure exposed $secret"
      done
      ! grep -Fq '"client_secret"' "$TMP/$failure.out" || fail 'PATCH failure exposed raw API response'
      ;;
  esac
done
export MOCK_CASE=ambiguous MOCK_LOG="$TMP/ambiguous.log" MOCK_MANIFEST="$TMP/ambiguous.manifest" MOCK_PATCH="$TMP/ambiguous.patch" EDA_PLAYGROUND_STATE_DIR="$TMP/ambiguous/state"
: >"$MOCK_LOG"
: >"$MOCK_MANIFEST"
: >"$MOCK_PATCH"
if PATH="$TMP/bin:$PATH" REAL_JQ="$REAL_JQ" REAL_BASE64="$REAL_BASE64" "$ROOT/addons/eda-playground/deploy.sh" >"$TMP/ambiguous.out" 2>&1; then fail 'ambiguous apps unexpectedly passed'; fi
! grep -Fq -- '-X DELETE' "$MOCK_LOG" || fail 'ambiguous apps deleted application'
grep -Fq 'multiple' "$TMP/ambiguous.out" || fail 'ambiguous app diagnostic'
echo 'PASS: EDA Playground deploy hardening fixtures'
