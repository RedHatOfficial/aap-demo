# shellcheck shell=bash

AO_ADMIN_PASSWORD_SECRET="${AO_ADMIN_PASSWORD_SECRET:-automation-orchestrator-initial-admin-password}"
AO_STATE_DIR="${AO_STATE_DIR:-${AAP_DEMO_DIR:-${HOME}/.aap-demo}/ao}"
AO_ADMIN_PASSWORD_FILE="${AO_ADMIN_PASSWORD_FILE:-${AO_STATE_DIR}/initial-admin-password}"
AO_ADMIN_PASSWORD_VAULT_KEY="${AO_ADMIN_PASSWORD_VAULT_KEY:-aap_demo.ao.initial_admin_password}"

ao_admin_password_get() {
  if [ -s "$AO_ADMIN_PASSWORD_FILE" ]; then
    aap_demo_vault_import_file "$AO_ADMIN_PASSWORD_VAULT_KEY" "$AO_ADMIN_PASSWORD_FILE" || return 1
  fi
  aap_demo_vault_get "$AO_ADMIN_PASSWORD_VAULT_KEY"
}

ao_admin_password_save() {
  local namespace="$1" encoded password
  encoded=$(kubectl get secret "$AO_ADMIN_PASSWORD_SECRET" -n "$namespace" \
    -o jsonpath='{.data.password}' 2>/dev/null || true)
  if [ -z "$encoded" ]; then
    if kubectl get cluster orchestrator-postgres -n "$namespace" &>/dev/null \
      || kubectl get pvc orchestrator-postgres-1 -n "$namespace" &>/dev/null; then
      echo "ERROR: Refusing to remove AO: PostgreSQL exists but its admin password is unavailable." >&2
      return 1
    fi
    return 0
  fi

  password=$(printf '%s' "$encoded" | base64 -d 2>/dev/null || true)
  if [ -z "$password" ] || ! aap_demo_vault_set "$AO_ADMIN_PASSWORD_VAULT_KEY" "$password"; then
    echo "ERROR: Could not preserve the AO admin password" >&2
    return 1
  fi
  rm -f "$AO_ADMIN_PASSWORD_FILE"
  echo "  ✓ AO admin password preserved for re-enable"
}

ao_admin_password_restore() {
  local namespace="$1" password
  password=$(ao_admin_password_get 2>/dev/null || true)
  [ -n "$password" ] || return 0

  kubectl delete secret "$AO_ADMIN_PASSWORD_SECRET" -n "$namespace" \
    --ignore-not-found >/dev/null
  kubectl create secret generic "$AO_ADMIN_PASSWORD_SECRET" -n "$namespace" \
    --from-file="password=/dev/fd/3" 3< <(printf '%s' "$password") >/dev/null
  echo "  ✓ AO admin password restored"
}

ao_admin_password_generate() {
  local namespace="$1" password
  password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  aap_demo_vault_set "$AO_ADMIN_PASSWORD_VAULT_KEY" "$password" || return 1
  rm -f "$AO_ADMIN_PASSWORD_FILE"
  ao_admin_password_restore "$namespace" >/dev/null
  echo "  ✓ Fresh AO admin password generated"
}

ao_admin_password_ensure() {
  local namespace="$1"

  if ao_admin_password_get >/dev/null 2>&1; then
    ao_admin_password_restore "$namespace"
    return 0
  fi

  if kubectl get cluster orchestrator-postgres -n "$namespace" &>/dev/null \
    || kubectl get pvc orchestrator-postgres-1 -n "$namespace" &>/dev/null; then
    if kubectl get secret "$AO_ADMIN_PASSWORD_SECRET" -n "$namespace" &>/dev/null; then
      ao_admin_password_save "$namespace"
      return 0
    fi
    ao_admin_password_require_for_retained_database "$namespace"
    return
  fi

  ao_admin_password_generate "$namespace"
}

ao_admin_password_require_for_retained_database() {
  local namespace="$1"
  if ao_admin_password_get >/dev/null 2>&1; then
    return 0
  fi
  if kubectl get cluster orchestrator-postgres -n "$namespace" &>/dev/null \
    || kubectl get pvc orchestrator-postgres-1 -n "$namespace" &>/dev/null; then
    echo "ERROR: Retained AO PostgreSQL data has no recoverable admin password." >&2
    echo "  Restore $AO_ADMIN_PASSWORD_VAULT_KEY in $AAP_DEMO_VAULT_FILE or run FORCE=1 aap-demo enable ao to reset AO data." >&2
    return 1
  fi
}

ao_admin_password_forget() {
  rm -f "$AO_ADMIN_PASSWORD_FILE"
  aap_demo_vault_delete "$AO_ADMIN_PASSWORD_VAULT_KEY"
}
