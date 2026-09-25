#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../addons/ao/lib/install-plan-approval.sh
source "${REPO_ROOT}/addons/ao/lib/install-plan-approval.sh"

assert_eq() {
  local expected="$1" actual="$2" description="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: ${description}: expected '${expected}', got '${actual}'" >&2
    exit 1
  fi
  echo "PASS: ${description}"
}

SUBSCRIPTION_APPROVAL="Manual"
SUBSCRIPTION_PATCH=""
SUBSCRIPTION_PLAN_CALLS_FILE="$(mktemp)"
trap 'rm -f "$SUBSCRIPTION_PLAN_CALLS_FILE"' EXIT
printf '0\n' >"$SUBSCRIPTION_PLAN_CALLS_FILE"
kubectl() {
  case "$*" in
    *"get subscription automation-orchestrator-operator"*".spec.installPlanApproval"*)
      printf '%s\n' "$SUBSCRIPTION_APPROVAL"
      ;;
    *"get subscription automation-orchestrator-operator"*".status.installplan.name"*)
      SUBSCRIPTION_PLAN_CALLS=$(($(<"$SUBSCRIPTION_PLAN_CALLS_FILE") + 1))
      printf '%s\n' "$SUBSCRIPTION_PLAN_CALLS" >"$SUBSCRIPTION_PLAN_CALLS_FILE"
      if [ "$SUBSCRIPTION_PLAN_CALLS" -eq 1 ]; then
        printf '%s\n' "install-first"
      else
        printf '%s\n' "install-current"
      fi
      ;;
    *"get installplan"*)
      cat <<'JSON'
{"items":[
  {"metadata":{"name":"install-current","ownerReferences":[{"kind":"Subscription","name":"automation-orchestrator-operator"}]},"spec":{"approved":false,"clusterServiceVersionNames":["automation-orchestrator-operator.v1","cloudnative-pg.v1"]}},
  {"metadata":{"name":"install-unrelated","ownerReferences":[{"kind":"Subscription","name":"other-operator"}]},"spec":{"approved":false,"clusterServiceVersionNames":["automation-orchestrator-operator.v2"]}},
  {"metadata":{"name":"install-approved","ownerReferences":[{"kind":"Subscription","name":"automation-orchestrator-operator"}]},"spec":{"approved":true,"clusterServiceVersionNames":["automation-orchestrator-operator.v0"]}}
]}
JSON
      ;;
    *"patch subscription automation-orchestrator-operator"*)
      SUBSCRIPTION_PATCH="$*"
      ;;
    *)
      echo "unexpected kubectl call: $*" >&2
      return 1
      ;;
  esac
}

assert_eq "Manual" "$(ao_resolve_install_plan_approval automation-orchestrator automation-orchestrator-operator '' Automatic)" \
  "existing Manual policy is preserved when no override is supplied"
assert_eq "Automatic" "$(ao_resolve_install_plan_approval automation-orchestrator automation-orchestrator-operator Automatic Manual)" \
  "explicit approval override wins over existing policy"
ao_apply_install_plan_approval automation-orchestrator automation-orchestrator-operator Manual
grep -Fq 'installPlanApproval' <<<"$SUBSCRIPTION_PATCH"
grep -Fq 'Manual' <<<"$SUBSCRIPTION_PATCH"
echo "PASS: explicit approval override is applied to an existing Subscription"

assert_eq "install-first" "$(ao_subscription_install_plan automation-orchestrator automation-orchestrator-operator)" \
  "subscription InstallPlan reference is read from the cluster"
assert_eq "install-current" "$(ao_subscription_install_plan automation-orchestrator automation-orchestrator-operator)" \
  "subscription InstallPlan reference can be refreshed"

pending_plans=$(ao_pending_install_plans automation-orchestrator automation-orchestrator-operator install-current)
assert_eq "install-current" "$pending_plans" \
  "only the Subscription-owned pending InstallPlan is selected"

instructions=$(ao_manual_install_plan_instructions automation-orchestrator install-current)
grep -Fq "Manual approval required for InstallPlan: install-current" <<<"$instructions"
grep -Fq "kubectl patch installplan install-current -n automation-orchestrator" <<<"$instructions"
echo "PASS: Manual mode prints an actionable approval command"

timeout_message=$(ao_install_plan_timeout_message Manual install-current)
grep -Fq "Timed out waiting for manual InstallPlan approval" <<<"$timeout_message"
grep -Fq "install-current" <<<"$timeout_message"
echo "PASS: Manual mode has a distinct timeout message"

echo "AO InstallPlan approval tests passed"
