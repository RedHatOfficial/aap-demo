#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
REAL_BASE64="$(command -v base64)"
cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$MOCK_LOG"
case "$1 $2" in
  'cluster-info ') exit 0 ;;
  'get namespace')
    [ "$MOCK_NS" = fail ] && { echo 'Forbidden' >&2; exit 1; }
    [ "$MOCK_NS" = absent ] && { [[ " $* " == *' --ignore-not-found '* ]] && exit 0; exit 1; }
    if [[ " $* " == *' -o jsonpath='* ]]; then printf '%s' "$MOCK_OWNER"; fi
    ;;
  'get route')
    [ "$MOCK_AAP" = fail ] && { echo 'Forbidden' >&2; exit 1; }
    [ "$MOCK_AAP" = absent ] && { [[ " $* " == *' --ignore-not-found '* ]] && exit 0; exit 1; }
    printf 'aap.example.test'
    ;;
  'get secret')
    [ "$MOCK_AAP" = fail ] && { echo 'Forbidden' >&2; exit 1; }
    [ "$MOCK_AAP" = absent ] && { [[ " $* " == *' --ignore-not-found '* ]] && exit 0; exit 1; }
    printf '%s' "$MOCK_PASSWORD_B64"
    ;;
  'delete namespace') [ "$MOCK_NS_DELETE" = fail ] && { echo 'Forbidden' >&2; exit 1; }; exit 0 ;;
esac
STUB
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$MOCK_LOG"
status=200
case " $* " in
  *'/ping/'*) [ "$MOCK_AAP" = absent ] && { status=404; break_status=22; }; [ "$MOCK_AAP" = fail ] && { status=500; break_status=22; }; [ "$status" = 200 ] && echo '{"ping":"pong"}' ;;
  *'/applications/?page=2'*) echo '{"count":2,"next":null,"results":[{"id":44,"name":"EDA Playground"}]}' ;;
  *'/applications/?'*)
    [ "$MOCK_APPS" = lookup_fail ] && { status=500; break_status=22; }
    if [ "$status" = 200 ]; then
      case "$MOCK_APPS" in
        exact) echo '{"count":3,"results":[{"id":41,"name":"Other","client_secret":"fixture-client-secret"},{"id":42,"name":"EDA Playground","client_id":"client-existing"},{"id":43,"name":"EDA Playground Extra"}]}' ;;
        mismatch) echo '{"count":3,"results":[{"id":41,"name":"Other"},{"id":42,"name":"EDA Playground"},{"id":43,"name":"EDA Playground Extra"}]}' ;;
        duplicate) echo '{"count":2,"results":[{"id":42,"name":"EDA Playground"},{"id":44,"name":"EDA Playground"}]}' ;;
        paginated) echo '{"count":2,"next":"https://aap.example.test/api/gateway/v1/applications/?page=2","results":[{"id":42,"name":"EDA Playground"}]}' ;;
        absent) echo '{"count":0,"results":[]}' ;;
      esac
    fi
    ;;
  *'/applications/'*)
    if [ "$MOCK_APP_DELETE" = absent ]; then status=404; break_status=22; fi
    if [ "$MOCK_APP_DELETE" = fail ]; then status=500; break_status=22; fi
    [ "$status" = 200 ] || echo '{"client_secret":"fixture-client-secret","password":"fixture-admin-password"}' >&2
    ;;
esac
[[ " $* " == *' -w '* ]] && printf '\n%s' "$status"
exit "${break_status:-0}"
STUB
cat >"$TMP/bin/oc" <<'STUB'
#!/usr/bin/env bash
printf 'oc %s\n' "$*" >>"$MOCK_LOG"
[ "$MOCK_SCC" = absent ] && { echo 'Error from server (NotFound): SCC binding not found' >&2; exit 1; }
[ "$MOCK_SCC" = fail ] && { echo 'Forbidden' >&2; exit 1; }
exit 0
STUB
chmod +x "$TMP/bin/"*
fail() {
  echo "FAIL: $1" >&2
  [ ! -f "${MOCK_LOG:-}" ] || cat "$MOCK_LOG" >&2
  exit 1
}
assert_log() { grep -Fq -- "$1" "$MOCK_LOG" || fail "$2"; }
reject_log() { ! grep -Fq -- "$1" "$MOCK_LOG" || fail "$2"; }
run_case() {
  local name="$1" action="${2:---delete}" expect_failure=no preserve_state=no
  export MOCK_LOG="$TMP/$name.log" EDA_PLAYGROUND_STATE_DIR="$TMP/$name/state"
  export MOCK_NS=present MOCK_OWNER=aap-demo-eda-playground MOCK_AAP=present
  export MOCK_APPS=exact MOCK_APP_DELETE=present MOCK_NS_DELETE=present MOCK_SCC=present
  export MOCK_PASSWORD_B64
  MOCK_PASSWORD_B64="$(printf '%s' fixture-admin-password | "$REAL_BASE64" | tr -d '\n')"
  mkdir -p "$EDA_PLAYGROUND_STATE_DIR"
  printf '%s\n' '{"oauth_app_id":"42","client_id":"client-existing","client_secret":"fixture-client-secret"}' >"$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
  : >"$MOCK_LOG"
  case "$name" in
    fallback)
      rm "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
      rmdir "$EDA_PLAYGROUND_STATE_DIR"
      ;;
    wrong_id)
      printf '%s\n' '{"oauth_app_id":"41","client_secret":"fixture-client-secret"}' >"$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
      MOCK_APPS=mismatch
      ;;
    marker_write_fail)
      printf '%s\n' '{"oauth_app_id":"41","client_secret":"fixture-client-secret"}' >"$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
      mkdir "$EDA_PLAYGROUND_STATE_DIR/oauth_app_id"
      MOCK_APPS=mismatch
      expect_failure=yes
      preserve_state=yes
      ;;
    malformed_metadata)
      printf '%s\n' '{"oauth_app_id":' >"$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
      expect_failure=yes
      preserve_state=yes
      ;;
    duplicate)
      rm "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
      MOCK_APPS=duplicate
      expect_failure=yes
      ;;
    paginated_duplicate)
      rm "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
      MOCK_APPS=paginated
      expect_failure=yes
      ;;
    app_absent) MOCK_APPS=absent ;;
    missing_app_delete) MOCK_APP_DELETE=absent ;;
    missing_scc) MOCK_SCC=absent ;;
    resources_absent)
      MOCK_AAP=absent
      MOCK_NS=absent
      MOCK_SCC=absent
      ;;
    partial)
      MOCK_APP_DELETE=fail
      MOCK_NS_DELETE=fail
      MOCK_SCC=fail
      expect_failure=yes
      ;;
    route_fail)
      MOCK_AAP=fail
      expect_failure=yes
      ;;
    lookup_fail)
      MOCK_APPS=lookup_fail
      expect_failure=yes
      ;;
    delete_fail)
      MOCK_APP_DELETE=fail
      expect_failure=yes
      ;;
    scc_fail)
      MOCK_SCC=fail
      expect_failure=yes
      ;;
    ns_fail)
      MOCK_NS_DELETE=fail
      expect_failure=yes
      ;;
    namespace_lookup_fail)
      MOCK_NS=fail
      expect_failure=yes
      ;;
    unowned) MOCK_OWNER=someone-else ;;
    custom) NAMESPACE=custom-demo ;;
  esac
  export MOCK_APPS MOCK_AAP MOCK_NS MOCK_OWNER MOCK_APP_DELETE MOCK_NS_DELETE MOCK_SCC
  if PATH="$TMP/bin:$PATH" NAMESPACE="${NAMESPACE:-eda-playground}" "$ROOT/addons/eda-playground/deploy.sh" "$action" >"$TMP/$name.out" 2>&1; then
    [ "$expect_failure" = no ] || fail "$name unexpectedly succeeded"
  else
    [ "$expect_failure" = yes ] || fail "$name cleanup failed"
    grep -Fq 'ERROR:' "$TMP/$name.out" || fail "$name missing failure diagnostic"
  fi
  for secret in fixture-admin-password fixture-client-secret fixture-session-secret; do
    ! grep -Fq "$secret" "$TMP/$name.out" || fail "$name exposed $secret"
  done
  ! grep -Fq '"client_secret":"fixture-client-secret"' "$TMP/$name.out" || fail "$name exposed raw API response"
  if [ "$preserve_state" = yes ]; then
    [ -f "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json" ] || fail "$name lost OAuth metadata"
  else
    [ ! -e "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json" ] || fail "$name retained OAuth state"
  fi
  unset NAMESPACE || true
}

run_case saved
assert_log '--max-time 10 https://aap.example.test/api/gateway/v1/ping/' 'Gateway ping missing'
assert_log '-X DELETE https://aap.example.test/api/gateway/v1/applications/42/' 'saved ID not deleted'
reject_log '/applications/41/' 'unrelated ID deleted'
reject_log '/applications/43/' 'similarly named app deleted'
assert_log 'oc adm policy remove-scc-from-user anyuid -z eda-playground -n eda-playground' 'SCC not removed'
assert_log 'kubectl delete namespace eda-playground' 'owned namespace not deleted'
[ "$(grep -n 'oc adm policy remove-scc-from-user' "$MOCK_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n 'kubectl delete namespace' "$MOCK_LOG" | head -1 | cut -d: -f1)" ] || fail 'SCC removal must precede namespace deletion'
MOCK_AAP=absent MOCK_NS=absent MOCK_SCC=absent PATH="$TMP/bin:$PATH" "$ROOT/addons/eda-playground/deploy.sh" --delete >"$TMP/repeat.out" 2>&1 || fail 'repeated cleanup failed'
[ ! -e "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json" ] || fail 'repeated cleanup restored OAuth state'
run_case fallback delete
assert_log '-X DELETE https://aap.example.test/api/gateway/v1/applications/42/' 'exact-name fallback not deleted'
[ "$(cat "$EDA_PLAYGROUND_STATE_DIR/oauth_app_id")" = 42 ] || fail 'fallback ownership marker missing'
run_case wrong_id
reject_log '-X DELETE' 'mismatched saved ID deleted'
[ "$(cat "$EDA_PLAYGROUND_STATE_DIR/oauth_app_id")" = 41 ] || fail 'wrong ID ownership tombstone missing'
grep -Fq 'OAuth application ownership mismatch' "$TMP/wrong_id.out" || fail 'wrong ID refusal not reported'
: >"$MOCK_LOG"
PATH="$TMP/bin:$PATH" "$ROOT/addons/eda-playground/deploy.sh" --delete >"$TMP/wrong_id/repeat.out" 2>&1 || fail 'wrong ID retry failed'
reject_log '-X DELETE' 'wrong ID retry fell back to name-only deletion'
run_case marker_write_fail
grep -Fq 'could not save OAuth ownership marker' "$TMP/marker_write_fail.out" || fail 'marker write failure not reported'
reject_log '-X DELETE' 'marker write failure deleted application'
reject_log 'kubectl delete namespace' 'marker write failure deleted namespace'
rmdir "$EDA_PLAYGROUND_STATE_DIR/oauth_app_id"
: >"$MOCK_LOG"
PATH="$TMP/bin:$PATH" "$ROOT/addons/eda-playground/deploy.sh" --delete >"$TMP/marker_write_fail/retry.out" 2>&1 || fail 'marker write retry failed'
reject_log '-X DELETE' 'marker write retry deleted wrong application'
[ "$(cat "$EDA_PLAYGROUND_STATE_DIR/oauth_app_id")" = 41 ] || fail 'marker write retry lost ownership ID'
run_case malformed_metadata
grep -Fq 'saved OAuth metadata' "$TMP/malformed_metadata.out" || fail 'malformed metadata failure not reported'
reject_log '-X DELETE' 'malformed metadata deleted application'
reject_log 'kubectl delete namespace' 'malformed metadata deleted namespace'
run_case duplicate
reject_log '-X DELETE' 'ambiguous name deleted'
run_case paginated_duplicate
assert_log '/applications/?page=2' 'Gateway second page not checked'
reject_log '-X DELETE' 'split-page duplicate deleted'
run_case app_absent
reject_log '-X DELETE' 'absent app deleted'
run_case resources_absent
run_case missing_app_delete
run_case missing_scc
assert_log 'kubectl delete namespace eda-playground' 'confirmed missing SCC blocked namespace deletion'
run_case partial
for step in 'OAuth application' 'SCC'; do
  grep -Fq "$step" "$TMP/partial.out" || fail "partial cleanup did not report $step"
done
reject_log 'kubectl delete namespace' 'partial cleanup attempted namespace deletion after SCC failure'
run_case route_fail
grep -Fq 'AAP Route lookup failed' "$TMP/route_fail.out" || fail 'route failure step not reported'
run_case lookup_fail
grep -Fq 'Gateway application lookup failed' "$TMP/lookup_fail.out" || fail 'Gateway lookup failure step not reported'
run_case delete_fail
grep -Fq 'OAuth application 42 deletion failed' "$TMP/delete_fail.out" || fail 'OAuth delete failure step not reported'
run_case scc_fail
grep -Fq 'SCC binding removal failed' "$TMP/scc_fail.out" || fail 'SCC failure step not reported'
reject_log 'kubectl delete namespace' 'SCC failure attempted namespace deletion'
run_case ns_fail
grep -Fq 'namespace eda-playground deletion failed' "$TMP/ns_fail.out" || fail 'namespace deletion failure step not reported'
run_case namespace_lookup_fail
grep -Fq 'namespace eda-playground lookup failed' "$TMP/namespace_lookup_fail.out" || fail 'namespace lookup failure step not reported'
run_case unowned
reject_log 'kubectl delete namespace' 'unowned namespace deleted'
run_case custom
assert_log 'kubectl delete namespace custom-demo' 'configured namespace not deleted'
reject_log 'kubectl delete namespace eda-playground' 'default namespace deleted with custom setting'
echo 'PASS: EDA Playground guarded cleanup fixtures'
