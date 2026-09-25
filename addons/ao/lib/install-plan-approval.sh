# shellcheck shell=bash

ao_validate_install_plan_approval() {
  case "$1" in
    Automatic | Manual) return 0 ;;
    *)
      echo "ERROR: AO_INSTALL_PLAN_APPROVAL must be Automatic or Manual" >&2
      return 1
      ;;
  esac
}

ao_resolve_install_plan_approval() {
  local namespace="$1" subscription_name="$2" requested="$3" default="$4" current

  if [ -n "$requested" ]; then
    ao_validate_install_plan_approval "$requested"
    printf '%s\n' "$requested"
    return 0
  fi

  current=$(kubectl get subscription "$subscription_name" -n "$namespace" \
    -o jsonpath='{.spec.installPlanApproval}' 2>/dev/null || true)
  case "$current" in
    Automatic | Manual)
      printf '%s\n' "$current"
      ;;
    *)
      ao_validate_install_plan_approval "$default"
      printf '%s\n' "$default"
      ;;
  esac
}

ao_apply_install_plan_approval() {
  local namespace="$1" subscription_name="$2" approval_mode="$3"
  ao_validate_install_plan_approval "$approval_mode"
  kubectl patch subscription "$subscription_name" -n "$namespace" \
    --type merge -p "{\"spec\":{\"installPlanApproval\":\"${approval_mode}\"}}" \
    >/dev/null
}

ao_subscription_install_plan() {
  local namespace="$1" subscription_name="$2"
  kubectl get subscription "$subscription_name" -n "$namespace" \
    -o jsonpath='{.status.installplan.name}' 2>/dev/null || true
}

ao_pending_install_plans() {
  local namespace="$1" subscription_name="$2" subscription_installplan="$3"
  kubectl get installplan -n "$namespace" -o json 2>/dev/null \
    | AO_INSTALLPLAN_NAME="$subscription_installplan" \
      AO_SUBSCRIPTION_NAME="$subscription_name" \
      python3 -c '
import json
import os
import sys

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)

subscription_installplan = os.environ.get("AO_INSTALLPLAN_NAME", "")
subscription_name = os.environ.get("AO_SUBSCRIPTION_NAME", "")
for item in data.get("items", []):
    metadata = item.get("metadata", {})
    spec = item.get("spec", {})
    owners = metadata.get("ownerReferences", [])
    owned_by_subscription = any(
        owner.get("kind") == "Subscription"
        and owner.get("name") == subscription_name
        for owner in owners
    )
    if (metadata.get("name") == subscription_installplan or owned_by_subscription) \
            and not spec.get("approved", False):
        print(metadata.get("name", ""))
' 2>/dev/null || true
}

ao_manual_install_plan_instructions() {
  local namespace="$1" installplan="$2"
  printf '  Manual approval required for InstallPlan: %s\n' "$installplan"
  printf '  Approve it with:\n'
  printf "    kubectl patch installplan %s -n %s --type merge -p '{\"spec\":{\"approved\":true}}'\n" \
    "$installplan" "$namespace"
}

ao_install_plan_timeout_message() {
  local approval_mode="$1" installplan="${2:-}"
  if [ "$approval_mode" = "Manual" ]; then
    printf 'ERROR: Timed out waiting for manual InstallPlan approval.\n'
    if [ -n "$installplan" ]; then
      printf '  Pending InstallPlan: %s\n' "$installplan"
    fi
  else
    printf 'ERROR: Operator CSV not found after 5 minutes.\n'
  fi
}
