#!/usr/bin/env bash

AO_ADMIN_PASSWORD_SECRET="${AO_ADMIN_PASSWORD_SECRET:-automation-orchestrator-initial-admin-password}"
AO_STATE_DIR="${AO_STATE_DIR:-${AAP_DEMO_DIR:-${HOME}/.aap-demo}/ao}"
AO_ADMIN_PASSWORD_FILE="${AO_ADMIN_PASSWORD_FILE:-${AO_STATE_DIR}/initial-admin-password}"

ao_admin_password_save() {
  local namespace="$1" encoded
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

  mkdir -p "$AO_STATE_DIR"
  umask 077
  if ! printf '%s' "$encoded" | base64 -d >"$AO_ADMIN_PASSWORD_FILE" 2>/dev/null \
    || [ ! -s "$AO_ADMIN_PASSWORD_FILE" ]; then
    rm -f "$AO_ADMIN_PASSWORD_FILE"
    echo "ERROR: Could not preserve the AO admin password" >&2
    return 1
  fi
  chmod 600 "$AO_ADMIN_PASSWORD_FILE"
  echo "  ✓ AO admin password preserved for re-enable"
}

ao_admin_password_restore() {
  local namespace="$1"
  [ -s "$AO_ADMIN_PASSWORD_FILE" ] || return 0

  # The saved password belongs to the retained database. Replace any Secret
  # generated during a partial reinstall before the AO instance consumes it.
  kubectl delete secret "$AO_ADMIN_PASSWORD_SECRET" -n "$namespace" \
    --ignore-not-found >/dev/null
  kubectl create secret generic "$AO_ADMIN_PASSWORD_SECRET" -n "$namespace" \
    --from-file="password=$AO_ADMIN_PASSWORD_FILE" >/dev/null
  echo "  ✓ AO admin password restored"
}

ao_admin_password_generate() {
  local namespace="$1"
  mkdir -p "$AO_STATE_DIR"
  umask 077
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n' >"$AO_ADMIN_PASSWORD_FILE"
  chmod 600 "$AO_ADMIN_PASSWORD_FILE"
  ao_admin_password_restore "$namespace" >/dev/null
  echo "  ✓ Fresh AO admin password generated"
}

ao_admin_password_require_for_retained_database() {
  local namespace="$1"
  if [ -s "$AO_ADMIN_PASSWORD_FILE" ]; then
    return 0
  fi
  if kubectl get cluster orchestrator-postgres -n "$namespace" &>/dev/null \
    || kubectl get pvc orchestrator-postgres-1 -n "$namespace" &>/dev/null; then
    echo "ERROR: Retained AO PostgreSQL data has no recoverable admin password." >&2
    echo "  Restore $AO_ADMIN_PASSWORD_FILE or run FORCE=1 aap-demo enable ao to reset AO data." >&2
    return 1
  fi
}

ao_admin_password_forget() {
  rm -f "$AO_ADMIN_PASSWORD_FILE"
}
