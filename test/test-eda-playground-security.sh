#!/usr/bin/env bash
# Exercise security boundaries with local command fixtures, never a cluster.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$MOCK_LOG"
case "$1 $2" in
  'get route') echo 'aap.apps.example.test' ;;
  'get secret') printf '%s' fixture-admin-password | base64 ;;
  'get ingresses.config/cluster')
    case "$MOCK_CASE" in
      ingress_absent) echo 'Error from server (NotFound): ingresses.config.openshift.io "cluster" not found' >&2; exit 1 ;;
      ingress_api_absent) echo "error: the server doesn't have a resource type \"ingresses\"" >&2; exit 1 ;;
      ingress_forbidden) echo 'Error from server (Forbidden): ingresses.config.openshift.io "cluster" is forbidden' >&2; exit 1 ;;
      ingress_transport) echo 'Unable to connect to the server: proxy host not found' >&2; exit 1 ;;
      ingress_timeout) echo 'Error from server (Timeout): request timed out' >&2; exit 1 ;;
      ingress_other_notfound) echo 'Error from server (NotFound): namespaces "other" not found' >&2; exit 1 ;;
      ingress_empty) exit 0 ;;
      *) echo 'apps.example.test' ;;
    esac ;;
  'get svc') echo '10.43.0.20' ;;
  'create -f')
    payload="$(cat)"
    if [ "$MOCK_CASE" = secret_dry_run ]; then printf '%s\n' "$payload" >&2; exit 1; fi
    printf '%s\n' "$payload" ;;
  'apply -f')
    payload="$(cat)"
    if [ "$MOCK_CASE" = secret_apply ] && [[ "$payload" == *'"kind": "Secret"'* ]]; then
      printf '%s\n' "$payload" >&2
      exit 1
    fi
    printf '%s\n' "$payload" >>"$MOCK_MANIFEST" ;;
esac
exit 0
STUB
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$MOCK_LOG"
case " $* " in
  *'/ping/'*) echo '{}' ;;
  *'/organizations/'*) echo '{"results":[{"id":7}]}' ;;
  *'/applications/?page=2'*)
    [ "$MOCK_CASE" != page_failure ] || { echo 'fixture-client-secret' >&2; exit 22; }
    cat "$MOCK_DIR/page2" ;;
  *'/applications/?'*) cat "$MOCK_DIR/page1" ;;
  *' -X POST '*) echo '{"id":43,"client_id":"client-new","client_secret":"fixture-client-secret"}' ;;
  *) echo '{}' ;;
esac
exit 0
STUB
cat >"$TMP/bin/openssl" <<'STUB'
#!/usr/bin/env bash
echo fixture-session-secret
STUB
cat >"$TMP/bin/oc" <<'STUB'
#!/usr/bin/env bash
printf 'oc %s\n' "$*" >>"$MOCK_LOG"
STUB
chmod +x "$TMP/bin/"*
fail() {
  echo "FAIL: $MOCK_CASE: $1" >&2
  exit 1
}
reject_mutation() {
  ! grep -Eq -- '-X (DELETE|POST|PATCH)|kubectl (apply|patch)|oc adm' "$MOCK_LOG" || fail 'mutated resources before validation'
}
run_case() {
  export MOCK_CASE="$1" MOCK_DIR="$TMP/$1"
  export MOCK_LOG="$MOCK_DIR/log" MOCK_MANIFEST="$MOCK_DIR/manifests" EDA_PLAYGROUND_STATE_DIR="$MOCK_DIR/state"
  local expected=failure saved='' marker='' status=0
  mkdir -p "$EDA_PLAYGROUND_STATE_DIR"
  : >"$MOCK_LOG"
  : >"$MOCK_MANIFEST"
  printf '%s\n' '{"results":[{"id":42,"name":"EDA Playground","client_id":"client-existing"}],"next":null}' >"$MOCK_DIR/page1"
  printf '%s\n' '{"results":[{"id":44,"name":"EDA Playground","client_id":"client-other"}],"next":null}' >"$MOCK_DIR/page2"
  case "$MOCK_CASE" in
    saved_mismatch) saved=41 ;;
    marker_mismatch) marker=41 ;;
    state_conflict)
      saved=42
      marker=41
      ;;
    invalid_saved) saved=invalid ;;
    invalid_marker) marker=invalid ;;
    marker_only)
      marker=42
      expected=recreate
      ;;
    matching_state)
      saved=42
      marker=42
      expected=reuse
      ;;
    owned_absent)
      marker=42
      expected=create
      echo '{"results":[],"next":null}' >"$MOCK_DIR/page1"
      ;;
    paginated_duplicate | paginated_saved | paginated_marker | repeated_id | page_failure | page_invalid)
      printf '%s\n' '{"results":[{"id":42,"name":"EDA Playground","client_id":"client-existing"}],"next":"/api/gateway/v1/applications/?page=2"}' >"$MOCK_DIR/page1"
      case "$MOCK_CASE" in
        paginated_saved)
          saved=44
          expected=reuse
          ;;
        paginated_marker)
          marker=44
          expected=recreate
          ;;
        repeated_id)
          saved=42
          echo '{"results":[{"id":42,"name":"EDA Playground"}],"next":null}' >"$MOCK_DIR/page2"
          ;;
        page_failure) saved=42 ;;
        page_invalid)
          saved=42
          echo '{"results":null,"next":null}' >"$MOCK_DIR/page2"
          ;;
      esac
      ;;
    foreign_next | traversal_next | cyclic_next)
      local next='https://untrusted.example/api/gateway/v1/applications/?page=2'
      [ "$MOCK_CASE" != traversal_next ] || next='/api/gateway/v1/applications/../organizations/'
      [ "$MOCK_CASE" != cyclic_next ] || next='/api/gateway/v1/applications/?name=EDA%20Playground'
      jq --arg next "$next" '.next=$next' "$MOCK_DIR/page1" >"$MOCK_DIR/new"
      mv "$MOCK_DIR/new" "$MOCK_DIR/page1"
      ;;
    invalid_app_id) echo '{"results":[{"id":"invalid","name":"EDA Playground"}]}' >"$MOCK_DIR/page1" ;;
    secret_dry_run | secret_apply)
      saved=42
      expected=secret_failure
      ;;
    ingress_absent | ingress_api_absent)
      saved=42
      expected=micro
      ;;
    ingress_*) saved=42 ;;
  esac
  if [ -n "$saved" ]; then
    jq -n --arg id "$saved" '{oauth_app_id:$id,client_id:"client-existing",client_secret:"fixture-saved-secret"}' >"$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
  fi
  if [ -n "$marker" ]; then printf '%s\n' "$marker" >"$EDA_PLAYGROUND_STATE_DIR/oauth_app_id"; fi
  cp -R "$EDA_PLAYGROUND_STATE_DIR" "$MOCK_DIR/before"
  PATH="$TMP/bin:$PATH" EDA_PLAYGROUND_DOMAIN=apps.override.test "$ROOT/addons/eda-playground/deploy.sh" >"$MOCK_DIR/output" 2>&1 || status=$?
  for secret in fixture-admin-password fixture-client-secret fixture-saved-secret fixture-session-secret; do
    ! grep -Fq "$secret" "$MOCK_DIR/output" || fail "output exposed $secret"
    ! grep -Fq "$secret" "$MOCK_LOG" || fail "argv exposed $secret"
  done
  case "$expected" in
    failure)
      [ "$status" -ne 0 ] || fail 'unexpected success'
      reject_mutation
      diff -qr "$MOCK_DIR/before" "$EDA_PLAYGROUND_STATE_DIR" >/dev/null || fail 'changed recovery state'
      grep -Fq 'ERROR:' "$MOCK_DIR/output" || fail 'missing diagnostic'
      if [[ "$MOCK_CASE" == ingress_* ]]; then
        grep -Eq 'ingress.*retry' "$MOCK_DIR/output" || fail 'missing ingress retry guidance'
        ! grep -Fq 'get svc' "$MOCK_LOG" || fail 'attempted MicroShift host alias'
      fi
      ;;
    secret_failure)
      [ "$status" -ne 0 ] || fail 'ignored pipeline failure'
      [ "$(cat "$MOCK_DIR/output")" = 'ERROR: EDA Playground OAuth Secret reconciliation failed; check cluster access and retry deployment' ] || fail 'expected fixed Secret retry diagnostic only'
      ! grep -Eq 'oc adm|kubectl patch|rollout status' "$MOCK_LOG" || fail 'continued deployment after Secret failure'
      [ -f "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json" ] || fail 'lost retry credentials'
      ;;
    *)
      [ "$status" -eq 0 ] || fail 'deployment failed'
      if [ "$expected" = recreate ]; then
        grep -Fq -- "-X DELETE https://aap.apps.example.test/api/gateway/v1/applications/$marker/" "$MOCK_LOG" || fail 'did not delete owned app'
        [ "$(grep -c -- '-X DELETE' "$MOCK_LOG")" = 1 ] || fail 'deleted additional apps'
        [ "$(cat "$EDA_PLAYGROUND_STATE_DIR/oauth_app_id")" = 43 ] || fail 'stale recovery marker after recreation'
        [ "$(jq -r .oauth_app_id "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json")" = 43 ] || fail 'stale credentials after recreation'
      else
        ! grep -Fq -- '-X DELETE' "$MOCK_LOG" || fail 'deleted an application'
      fi
      if [ "$expected" = reuse ]; then
        ! grep -Fq -- '-X POST' "$MOCK_LOG" || fail 'created an application instead of reusing'
        grep -Fq 'fixture-saved-secret' "$MOCK_MANIFEST" || fail 'did not reuse saved secret'
      fi
      if [ "$expected" = micro ]; then
        grep -Fq 'http://aap.apps.example.test' "$MOCK_MANIFEST" || fail 'missing MicroShift HTTP behavior'
        grep -Fq 'hostAliases' "$MOCK_LOG" || fail 'missing MicroShift host alias'
      fi
      ;;
  esac
  if [[ "$MOCK_CASE" == paginated_* || "$MOCK_CASE" == repeated_id || "$MOCK_CASE" == page_* ]]; then
    grep -Fq '/applications/?page=2' "$MOCK_LOG" || fail 'did not exhaust pagination'
  fi
  ! grep -Fq 'curl --config - -fsSk https://untrusted.example' "$MOCK_LOG" || fail 'sent credentials to foreign pagination URL'
  echo "PASS: $MOCK_CASE"
}
failures=0
cases=(saved_mismatch marker_mismatch state_conflict invalid_saved invalid_marker marker_only matching_state owned_absent
  paginated_duplicate paginated_saved paginated_marker repeated_id page_failure page_invalid foreign_next traversal_next cyclic_next invalid_app_id
  secret_dry_run secret_apply ingress_absent ingress_api_absent ingress_forbidden ingress_transport ingress_timeout ingress_other_notfound ingress_empty)
if [ "$#" -gt 0 ]; then cases=("$@"); fi
for security_case in "${cases[@]}"; do
  (run_case "$security_case") || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || {
  echo "FAIL: $failures security regression cases" >&2
  exit 1
}
echo 'PASS: EDA Playground security regressions'
