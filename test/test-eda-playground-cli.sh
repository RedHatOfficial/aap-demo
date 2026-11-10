#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.aap-demo"

cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_LOG"
case "$*" in
  *'config view'*) exit 0 ;;
  'cluster-info'*) exit 0 ;;
  'get namespace '*)
    if [[ "$*" == *' -o jsonpath='* ]]; then printf '%s' "${MOCK_OWNER:-aap-demo-eda-playground}"; fi
    if [[ "$*" == *' -o name'* ]]; then printf 'namespace/%s' "$3"; fi
    exit 0
    ;;
  'get route aap '* | 'get secret aap-admin-password '*) exit 0 ;;
  'delete namespace '*)
    [ "${MOCK_DELETE_FAIL:-no}" != yes ] || exit 1
    ;;
esac
exit 0
STUB
cat >"$TMP/bin/oc" <<'STUB'
#!/usr/bin/env bash
printf 'oc %s\n' "$*" >>"$MOCK_LOG"
exit 0
STUB
chmod +x "$TMP/bin/"*

fail() {
  echo "FAIL: $1" >&2
  cat "$MOCK_LOG" >&2
  exit 1
}

run_disable() {
  local name="$1" addon_namespace="$2" delete_fail="$3" expected_status="$4" owner="${5:-aap-demo-eda-playground}"
  printf 'ADDONS=eda-playground\n' >"$TMP/home/.aap-demo/config"
  export MOCK_LOG="$TMP/$name.log" MOCK_DELETE_FAIL="$delete_fail" MOCK_OWNER="$owner"
  : >"$MOCK_LOG"
  if HOME="$TMP/home" AAP_DEMO_DIR="$TMP/home/.aap-demo" AAP_DEMO_CONFIG="$TMP/home/.aap-demo/config" \
    QUIET=true NAMESPACE=aap-operator EDA_PLAYGROUND_NAMESPACE="$addon_namespace" \
    EDA_PLAYGROUND_STATE_DIR="$TMP/$name-state" PATH="$TMP/bin:$PATH" \
    "$ROOT/aap-demo.sh" disable eda-playground >"$TMP/$name.out" 2>&1; then
    [ "$expected_status" = success ] || fail "$name unexpectedly succeeded"
  else
    [ "$expected_status" = failure ] || {
      cat "$TMP/$name.out" >&2
      fail "$name failed"
    }
  fi
}

run_disable default '' no success
grep -Fq 'delete namespace eda-playground' "$MOCK_LOG" || fail 'default addon namespace not deleted'
! grep -Fq 'delete namespace aap-operator' "$MOCK_LOG" || fail 'AAP namespace deletion attempted'
grep -Fxq 'ADDONS=' "$TMP/home/.aap-demo/config" || fail 'successful disable did not clear addon state'

run_disable custom custom-demo no success
grep -Fq 'delete namespace custom-demo' "$MOCK_LOG" || fail 'custom addon namespace not deleted'
! grep -Fq 'delete namespace aap-operator' "$MOCK_LOG" || fail 'AAP namespace deletion attempted with custom target'

run_disable unsafe aap-operator no failure
! grep -Fq 'delete namespace ' "$MOCK_LOG" || fail 'unsafe namespace deletion attempted'
grep -Fxq 'ADDONS=eda-playground' "$TMP/home/.aap-demo/config" || fail 'unsafe namespace cleared addon state'

run_disable failed eda-playground yes failure
grep -Fq 'delete namespace eda-playground' "$MOCK_LOG" || fail 'failed cleanup did not attempt namespace deletion'
grep -Fxq 'ADDONS=eda-playground' "$TMP/home/.aap-demo/config" || fail 'failed cleanup cleared addon state'

run_disable unowned custom-demo no failure another-owner
! grep -Fq 'delete namespace custom-demo' "$MOCK_LOG" || fail 'unowned custom namespace deletion attempted'
grep -Fxq 'ADDONS=eda-playground' "$TMP/home/.aap-demo/config" || fail 'unowned namespace cleared addon state'

for addon_namespace in eda-playground custom-demo; do
  printf 'ADDONS=\n' >"$TMP/home/.aap-demo/config"
  MOCK_LOG="$TMP/enable-$addon_namespace.log" MOCK_DELETE_FAIL=no MOCK_OWNER=aap-demo-eda-playground \
    HOME="$TMP/home" AAP_DEMO_DIR="$TMP/home/.aap-demo" \
    AAP_DEMO_CONFIG="$TMP/home/.aap-demo/config" QUIET=true NAMESPACE=aap-operator \
    EDA_PLAYGROUND_NAMESPACE="$addon_namespace" \
    EDA_PLAYGROUND_STATE_DIR="$TMP/enable-$addon_namespace-state" \
    PATH="$TMP/bin:$PATH" "$ROOT/aap-demo.sh" enable eda-playground \
    >"$TMP/enable-$addon_namespace.out" 2>&1 \
    && fail "enable $addon_namespace unexpectedly succeeded with no AAP route"
  grep -Fq "get namespace $addon_namespace --ignore-not-found -o name" \
    "$TMP/enable-$addon_namespace.log" || fail "enable did not target $addon_namespace"
  grep -Fq 'AAP route unavailable' "$TMP/enable-$addon_namespace.out" \
    || fail "enable did not pass namespace ownership for $addon_namespace"
  ! grep -Fq 'get namespace aap-operator' "$TMP/enable-$addon_namespace.log" \
    || fail 'enable attempted addon ownership in the AAP namespace'
done

MOCK_LOG="$TMP/unrelated.log" MOCK_OWNER=another-owner HOME="$TMP/home" \
  NAMESPACE=aap-operator EDA_PLAYGROUND_NAMESPACE=custom-demo \
  EDA_PLAYGROUND_STATE_DIR="$TMP/unrelated-state" PATH="$TMP/bin:$PATH" \
  "$ROOT/addons/eda-playground/deploy.sh" >"$TMP/unrelated.out" 2>&1 \
  && fail 'deploy accepted an existing unrelated namespace'
! grep -Fq 'apply ' "$TMP/unrelated.log" || fail 'deploy applied resources in unrelated namespace'

echo 'PASS: EDA Playground CLI namespace and failed cleanup state'
