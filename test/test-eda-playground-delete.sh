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
    [ "$MOCK_NS" = absent ] && exit 1
    if [[ " $* " == *' -o jsonpath='* ]]; then printf '%s' "$MOCK_OWNER"; fi
    ;;
  'get route') [ "$MOCK_AAP" = absent ] && exit 1; printf 'aap.example.test' ;;
  'get secret') [ "$MOCK_AAP" = absent ] && exit 1; printf '%s' "$MOCK_PASSWORD_B64" ;;
  'delete namespace') [ "$MOCK_NS_DELETE" = absent ] && exit 1; exit 0 ;;
esac
STUB
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$MOCK_LOG"
case " $* " in
  *'/ping/'*) [ "$MOCK_AAP" = absent ] && exit 22; echo '{"ping":"pong"}' ;;
  *'/applications/?'*)
    case "$MOCK_APPS" in
      exact) echo '{"count":3,"results":[{"id":41,"name":"Other","client_secret":"fixture-client-secret"},{"id":42,"name":"EDA Playground","client_id":"client-existing"},{"id":43,"name":"EDA Playground Extra"}]}' ;;
      mismatch) echo '{"count":3,"results":[{"id":41,"name":"Other"},{"id":42,"name":"EDA Playground"},{"id":43,"name":"EDA Playground Extra"}]}' ;;
      duplicate) echo '{"count":2,"results":[{"id":42,"name":"EDA Playground"},{"id":44,"name":"EDA Playground"}]}' ;;
      absent) echo '{"count":0,"results":[]}' ;;
    esac
    ;;
  *'/applications/'*) if [ "$MOCK_APP_DELETE" = absent ]; then echo '{"client_secret":"fixture-client-secret","password":"fixture-admin-password"}' >&2; exit 22; fi ;;
esac
STUB
cat >"$TMP/bin/oc" <<'STUB'
#!/usr/bin/env bash
printf 'oc %s\n' "$*" >>"$MOCK_LOG"
[ "$MOCK_SCC" = absent ] && exit 1
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
  local name="$1" action="${2:---delete}"
  export MOCK_LOG="$TMP/$name.log" EDA_PLAYGROUND_STATE_DIR="$TMP/$name/state"
  export MOCK_NS=present MOCK_OWNER=aap-demo-eda-playground MOCK_AAP=present
  export MOCK_APPS=exact MOCK_APP_DELETE=present MOCK_NS_DELETE=present MOCK_SCC=present
  export MOCK_PASSWORD_B64
  MOCK_PASSWORD_B64="$(printf '%s' fixture-admin-password | "$REAL_BASE64" | tr -d '\n')"
  mkdir -p "$EDA_PLAYGROUND_STATE_DIR"
  printf '%s\n' '{"oauth_app_id":"42","client_id":"client-existing","client_secret":"fixture-client-secret"}' >"$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
  : >"$MOCK_LOG"
  case "$name" in
    fallback) rm "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json" ;;
    wrong_id)
      printf '%s\n' '{"oauth_app_id":"41","client_secret":"fixture-client-secret"}' >"$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
      MOCK_APPS=mismatch
      ;;
    duplicate)
      rm "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
      MOCK_APPS=duplicate
      ;;
    app_absent) MOCK_APPS=absent ;;
    resources_absent)
      MOCK_AAP=absent
      MOCK_NS=absent
      MOCK_SCC=absent
      ;;
    partial)
      MOCK_APP_DELETE=absent
      MOCK_NS_DELETE=absent
      MOCK_SCC=absent
      ;;
    unowned) MOCK_OWNER=someone-else ;;
    custom) NAMESPACE=custom-demo ;;
  esac
  export MOCK_APPS MOCK_AAP MOCK_NS MOCK_OWNER MOCK_APP_DELETE MOCK_NS_DELETE MOCK_SCC
  if ! PATH="$TMP/bin:$PATH" NAMESPACE="${NAMESPACE:-eda-playground}" "$ROOT/addons/eda-playground/deploy.sh" "$action" >"$TMP/$name.out" 2>&1; then
    cat "$TMP/$name.out"
    fail "$name cleanup failed"
  fi
  for secret in fixture-admin-password fixture-client-secret fixture-session-secret; do
    ! grep -Fq "$secret" "$TMP/$name.out" || fail "$name exposed $secret"
  done
  ! grep -Fq '"client_secret":"fixture-client-secret"' "$TMP/$name.out" || fail "$name exposed raw API response"
  [ ! -e "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json" ] || fail "$name retained OAuth state"
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
run_case wrong_id
reject_log '-X DELETE' 'mismatched saved ID deleted'
run_case duplicate
reject_log '-X DELETE' 'ambiguous name deleted'
run_case app_absent
reject_log '-X DELETE' 'absent app deleted'
run_case resources_absent
run_case partial
run_case unowned
reject_log 'kubectl delete namespace' 'unowned namespace deleted'
run_case custom
assert_log 'kubectl delete namespace custom-demo' 'configured namespace not deleted'
reject_log 'kubectl delete namespace eda-playground' 'default namespace deleted with custom setting'
echo 'PASS: EDA Playground guarded cleanup fixtures'
