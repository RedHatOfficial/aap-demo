#!/usr/bin/env bash
set -uo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export AAP_DEMO_DIR="$TEST_DIR/state"
export AO_STATE_DIR="$AAP_DEMO_DIR/ao"

KUBE_SECRET_EXISTS=false
KUBE_SECRET_B64=""
KUBE_DATABASE_EXISTS=false
CREATE_PASSWORD=""
DELETE_CALLED=false

kubectl() {
  if [ "$1 $2" = "get secret" ]; then
    if [ "$KUBE_SECRET_EXISTS" = true ]; then
      case "$*" in
        *jsonpath*) printf '%s' "$KUBE_SECRET_B64" ;;
      esac
      return 0
    fi
    return 1
  fi
  if [ "$1 $2" = "get cluster" ] || [ "$1 $2" = "get pvc" ]; then
    [ "$KUBE_DATABASE_EXISTS" = true ]
    return
  fi
  if [ "$1 $2 $3" = "create secret generic" ]; then
    local arg
    for arg in "$@"; do
      case "$arg" in
        --from-file=password=*) CREATE_PASSWORD=$(<"${arg#--from-file=password=}") ;;
      esac
    done
    return 0
  fi
  if [ "$1 $2" = "delete secret" ]; then
    DELETE_CALLED=true
    return 0
  fi
  return 1
}

# shellcheck source=addons/ao/lib/admin-password.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/addons/ao/lib/admin-password.sh"

KUBE_SECRET_EXISTS=true
EXPECTED_VALUE="fixture-value"
KUBE_SECRET_B64=$(printf '%s' "$EXPECTED_VALUE" | base64)
ao_admin_password_save test >/dev/null
[ "$(<"$AO_ADMIN_PASSWORD_FILE")" = "$EXPECTED_VALUE" ]
if password_mode=$(stat -c '%a' "$AO_ADMIN_PASSWORD_FILE" 2>/dev/null); then
  :
else
  password_mode=$(stat -f '%Lp' "$AO_ADMIN_PASSWORD_FILE")
fi
[ "$password_mode" = "600" ]

KUBE_SECRET_EXISTS=false
ao_admin_password_restore test >/dev/null
[ "$CREATE_PASSWORD" = "$EXPECTED_VALUE" ]
[ "$DELETE_CALLED" = true ]

ao_admin_password_forget
KUBE_DATABASE_EXISTS=true
if ao_admin_password_require_for_retained_database test 2>/dev/null; then
  echo "expected retained database guard to fail" >&2
  exit 1
fi

KUBE_DATABASE_EXISTS=false
ao_admin_password_generate test >/dev/null
[ "${#CREATE_PASSWORD}" -eq 32 ]
[ "$(<"$AO_ADMIN_PASSWORD_FILE")" = "$CREATE_PASSWORD" ]

MANIFEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/addons/ao/manifests/automationorchestrator-cr.yaml"
grep -q 'initialAdminPasswordSecretRef:' "$MANIFEST"
grep -q 'name: automation-orchestrator-initial-admin-password' "$MANIFEST"

echo "AO admin password lifecycle tests passed"
