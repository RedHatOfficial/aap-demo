#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export EDA_PLAYGROUND_IMAGE='ghcr.io/test/eda-playground@sha256:fixture'
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
        missing_gateway_id) echo '{"count":1,"results":[{"name":"EDA Playground"}]}' ;;
        invalid_gateway_id) echo '{"count":1,"results":[{"id":"fixture-client-secret","name":"EDA Playground"}]}' ;;
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
if [ "$1 $2" = 'get rolebinding' ]; then
  [ "$MOCK_BINDING_CASE" = lookup_fail ] && { echo 'fixture-client-secret: transport failure' >&2; exit 1; }
  [ "$MOCK_BINDING_CASE" = malformed ] && { echo '{invalid fixture-client-secret'; exit 0; }
  cat "$MOCK_BINDING_FILE"
  exit 0
fi
if [ "$MOCK_SCC" = shared ]; then
  if jq -e --arg ns "${NAMESPACE:-eda-playground}" '.subjects[] | select(.kind == "ServiceAccount" and .name == "eda-playground" and .namespace == $ns)' "$MOCK_BINDING_FILE" >/dev/null; then
    jq --arg ns "${NAMESPACE:-eda-playground}" '.subjects |= map(select(.kind != "ServiceAccount" or .name != "eda-playground" or .namespace != $ns))' "$MOCK_BINDING_FILE" >"$MOCK_BINDING_FILE.new"
    mv "$MOCK_BINDING_FILE.new" "$MOCK_BINDING_FILE"
    exit 0
  fi
fi
[[ "$MOCK_SCC" = shared || "$MOCK_SCC" = target_absent ]] && { echo 'error: unable to find target [eda-playground]' >&2; exit 1; }
[ "$MOCK_SCC" = absent ] && { echo 'Error from server (NotFound): rolebindings.rbac.authorization.k8s.io "system:openshift:scc:anyuid" not found' >&2; exit 1; }
[ "$MOCK_SCC" = resource_absent ] && { echo 'Error from server (NotFound): securitycontextconstraints.security.openshift.io "anyuid" not found' >&2; exit 1; }
[ "$MOCK_SCC" = config_not_found ] && { echo 'error: context "fixture-client-secret" not found' >&2; exit 1; }
[ "$MOCK_SCC" = transport_not_found ] && { echo 'Unable to connect to the server: proxy host not found' >&2; exit 1; }
[ "$MOCK_SCC" = unrelated_not_found ] && { echo 'Error from server (NotFound): namespaces "other" not found' >&2; exit 1; }
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
  local name="$1" action="${2:---delete}" expect_failure=no preserve_state=no addon_namespace
  export MOCK_LOG="$TMP/$name.log" EDA_PLAYGROUND_STATE_DIR="$TMP/$name/state"
  export MOCK_NS=present MOCK_OWNER=aap-demo-eda-playground MOCK_AAP=present
  export MOCK_APPS=exact MOCK_APP_DELETE=present MOCK_NS_DELETE=present MOCK_SCC=present
  export MOCK_BINDING_CASE=present MOCK_BINDING_FILE="$TMP/$name/binding.json"
  export MOCK_PASSWORD_B64
  MOCK_PASSWORD_B64="$(printf '%s' fixture-admin-password | "$REAL_BASE64" | tr -d '\n')" # pragma: allowlist secret
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
    conflicting_state)
      printf '%s\n' 41 >"$EDA_PLAYGROUND_STATE_DIR/oauth_app_id"
      expect_failure=yes
      preserve_state=yes
      ;;
    malformed_metadata)
      printf '%s\n' '{"oauth_app_id":' >"$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
      expect_failure=yes
      preserve_state=yes
      ;;
    missing_id_metadata)
      printf '%s\n' '{}' >"$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
      printf '%s\n' 41 >"$EDA_PLAYGROUND_STATE_DIR/oauth_app_id"
      expect_failure=yes
      preserve_state=yes
      ;;
    invalid_id_metadata)
      printf '%s\n' '{"oauth_app_id":"not-an-id"}' >"$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"
      printf '%s\n' 41 >"$EDA_PLAYGROUND_STATE_DIR/oauth_app_id"
      expect_failure=yes
      preserve_state=yes
      ;;
    empty_marker | invalid_marker | empty_marker_with_metadata | invalid_marker_with_metadata)
      if [[ "$name" != *_with_metadata ]]; then rm "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"; fi
      if [[ "$name" == empty_* ]]; then
        : >"$EDA_PLAYGROUND_STATE_DIR/oauth_app_id"
      else
        printf '%s\n' 'fixture-client-secret' >"$EDA_PLAYGROUND_STATE_DIR/oauth_app_id"
      fi
      expect_failure=yes
      preserve_state=yes
      ;;
    missing_gateway_id | invalid_gateway_id | missing_gateway_id_with_metadata | invalid_gateway_id_with_metadata)
      if [[ "$name" != *_with_metadata ]]; then rm "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json"; fi
      MOCK_APPS="${name%_with_metadata}"
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
    missing_scc_resource) MOCK_SCC=resource_absent ;;
    config_not_found | transport_not_found | unrelated_not_found)
      MOCK_SCC="$name"
      expect_failure=yes
      ;;
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
    shared_retry | shared_retry_custom)
      if [ "$name" = shared_retry_custom ]; then NAMESPACE=custom-demo; fi
      MOCK_SCC=shared
      MOCK_NS_DELETE=fail
      expect_failure=yes
      ;;
    subject_present | subject_lookup_fail | subject_malformed | subject_wrong_namespace)
      MOCK_SCC=target_absent
      MOCK_BINDING_CASE="${name#subject_}"
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
    unowned)
      MOCK_OWNER=someone-else
      expect_failure=yes
      ;;
    custom) NAMESPACE=custom-demo ;;
  esac
  jq -n --arg ns "${NAMESPACE:-eda-playground}" '{
    apiVersion:"rbac.authorization.k8s.io/v1", kind:"RoleBinding",
    metadata:{name:"system:openshift:scc:anyuid",namespace:$ns},
    roleRef:{apiGroup:"rbac.authorization.k8s.io",kind:"ClusterRole",name:"system:openshift:scc:anyuid"},
    subjects:[{kind:"ServiceAccount",name:"eda-playground",namespace:$ns},
      {kind:"ServiceAccount",name:"shared",namespace:$ns},
      {kind:"ServiceAccount",name:"eda-playground",namespace:"other"},
      {kind:"User",name:"eda-playground",apiGroup:"rbac.authorization.k8s.io"}]
  }' >"$MOCK_BINDING_FILE"
  if [ "$MOCK_BINDING_CASE" = wrong_namespace ]; then
    jq '.metadata.namespace = "other" | .subjects = []' "$MOCK_BINDING_FILE" >"$MOCK_BINDING_FILE.new"
    mv "$MOCK_BINDING_FILE.new" "$MOCK_BINDING_FILE"
  fi
  if [ "$preserve_state" = yes ]; then cp -R "$EDA_PLAYGROUND_STATE_DIR" "$TMP/$name/before"; fi
  export MOCK_APPS MOCK_AAP MOCK_NS MOCK_OWNER MOCK_APP_DELETE MOCK_NS_DELETE MOCK_SCC
  addon_namespace="${NAMESPACE:-eda-playground}"
  if PATH="$TMP/bin:$PATH" NAMESPACE="$addon_namespace" AAP_NAMESPACE=aap-operator \
    EDA_PLAYGROUND_NAMESPACE="$addon_namespace" \
    "$ROOT/addons/eda-playground/deploy.sh" "$action" >"$TMP/$name.out" 2>&1; then
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
    diff -qr "$TMP/$name/before" "$EDA_PLAYGROUND_STATE_DIR" >/dev/null || fail "$name changed OAuth state"
  else
    [ ! -e "$EDA_PLAYGROUND_STATE_DIR/oauth_credentials.json" ] || fail "$name retained OAuth state"
  fi
  unset NAMESPACE || true
}

run_case conflicting_state
reject_log '-X DELETE' 'conflicting state deleted application'
reject_log 'kubectl delete namespace' 'conflicting state deleted namespace'
reject_log 'oc adm' 'conflicting state removed SCC'
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
for bad_case in missing_id_metadata invalid_id_metadata; do
  run_case "$bad_case"
  grep -Fq 'saved OAuth metadata' "$TMP/$bad_case.out" || fail "$bad_case failure not reported"
  [ "$(cat "$EDA_PLAYGROUND_STATE_DIR/oauth_app_id")" = 41 ] || fail "$bad_case overwrote ownership marker"
  reject_log '-X DELETE' "$bad_case deleted application"
  reject_log 'kubectl delete namespace' "$bad_case deleted namespace"
  reject_log 'oc adm policy remove-scc-from-user' "$bad_case removed SCC"
done
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
run_case missing_scc_resource
assert_log 'kubectl delete namespace eda-playground' 'confirmed missing SCC resource blocked namespace deletion'
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
grep -Fq 'namespace eda-playground is not owned' "$TMP/unowned.out" || fail 'unowned namespace failure not reported'
run_case custom
assert_log 'kubectl delete namespace custom-demo' 'configured namespace not deleted'
reject_log 'kubectl delete namespace eda-playground' 'default namespace deleted with custom setting'
marker_failures=0
for bad_case in empty_marker invalid_marker empty_marker_with_metadata invalid_marker_with_metadata; do
  (
    run_case "$bad_case"
    grep -Fq 'saved OAuth ownership marker' "$TMP/$bad_case.out" || fail "$bad_case failure not reported"
    reject_log 'curl ' "$bad_case attempted OAuth lookup or cleanup"
    reject_log 'oc adm policy remove-scc-from-user' "$bad_case removed SCC"
    reject_log 'kubectl delete namespace' "$bad_case deleted namespace"
  ) || marker_failures=$((marker_failures + 1))
done
[ "$marker_failures" -eq 0 ] || fail "$marker_failures invalid marker regressions failed"
gateway_id_failures=0
for bad_case in missing_gateway_id invalid_gateway_id missing_gateway_id_with_metadata invalid_gateway_id_with_metadata; do
  (
    run_case "$bad_case"
    grep -Fq 'Gateway application has a missing or invalid ID' "$TMP/$bad_case.out" || fail "$bad_case failure not reported"
    reject_log '-X DELETE' "$bad_case deleted application"
    reject_log 'oc adm policy remove-scc-from-user' "$bad_case removed SCC"
    reject_log 'kubectl delete namespace' "$bad_case deleted namespace"
  ) || gateway_id_failures=$((gateway_id_failures + 1))
done
[ "$gateway_id_failures" -eq 0 ] || fail "$gateway_id_failures invalid Gateway ID regressions failed"
scc_failures=0
for bad_case in config_not_found transport_not_found unrelated_not_found; do
  (
    run_case "$bad_case"
    grep -Fq 'SCC binding removal failed' "$TMP/$bad_case.out" || fail "$bad_case failure not reported"
    reject_log 'kubectl delete namespace' "$bad_case deleted namespace"
  ) || scc_failures=$((scc_failures + 1))
done
[ "$scc_failures" -eq 0 ] || fail "$scc_failures SCC error regressions failed"
for bad_case in subject_present subject_lookup_fail subject_malformed subject_wrong_namespace; do
  run_case "$bad_case"
  reject_log 'kubectl delete namespace' "$bad_case deleted namespace without confirming subject absence"
done
for retry_namespace in eda-playground custom-demo; do
  if [ "$retry_namespace" = eda-playground ]; then run_case shared_retry; else run_case shared_retry_custom; fi
  assert_log "kubectl delete namespace $retry_namespace" 'first cleanup did not attempt namespace deletion'
  jq -e '.subjects | length == 3' "$MOCK_BINDING_FILE" >/dev/null || fail 'first cleanup did not remove only the addon subject'
  cp "$MOCK_BINDING_FILE" "$TMP/shared-before-retry.json"
  : >"$MOCK_LOG"
  MOCK_APPS=absent MOCK_NS_DELETE=present NAMESPACE="$retry_namespace" AAP_NAMESPACE=aap-operator \
    EDA_PLAYGROUND_NAMESPACE="$retry_namespace" PATH="$TMP/bin:$PATH" \
    "$ROOT/addons/eda-playground/deploy.sh" --delete >"$TMP/shared-retry.out" 2>&1 || fail 'shared SCC binding retry failed'
  assert_log "oc get rolebinding system:openshift:scc:anyuid -n $retry_namespace -o json" 'retry did not verify the shared binding'
  assert_log "kubectl delete namespace $retry_namespace" 'confirmed absent subject blocked namespace deletion'
  cmp -s "$TMP/shared-before-retry.json" "$MOCK_BINDING_FILE" || fail 'retry changed shared binding subjects'
  for secret in fixture-admin-password fixture-client-secret fixture-session-secret; do
    ! grep -Fq "$secret" "$TMP/shared-retry.out" || fail "shared retry exposed $secret"
  done
done
echo 'PASS: EDA Playground guarded cleanup fixtures'
