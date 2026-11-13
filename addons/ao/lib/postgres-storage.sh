#!/usr/bin/env bash

ao_postgres_storage_size() {
  local namespace="$1" requested_size="$2" existing_size
  if ! existing_size=$(kubectl get cluster orchestrator-postgres -n "$namespace" \
    --ignore-not-found -o jsonpath='{.spec.storage.size}'); then
    echo "ERROR: Could not read the existing PostgreSQL cluster storage size; refusing to apply the manifest." >&2
    return 1
  fi
  if [ -n "$existing_size" ]; then
    if [ "$existing_size" != "$requested_size" ]; then
      echo "  Preserving existing PostgreSQL storage size: ${existing_size} (requested: ${requested_size})" >&2
    fi
    printf '%s\n' "$existing_size"
  else
    printf '%s\n' "$requested_size"
  fi
}
