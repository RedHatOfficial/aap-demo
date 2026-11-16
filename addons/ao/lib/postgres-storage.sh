#!/usr/bin/env bash

ao_validate_postgres_storage_size() {
  local size="$1"
  if [[ ! "$size" =~ ^[0-9]+([.][0-9]+)?([EPTGMK]i|[EPTGMkmun]|[eE][+-]?[0-9]+)?$ ]] \
    || [[ "$size" =~ ^0+([.]0+)?([EPTGMK]i|[EPTGMkmun]|[eE][+-]?[0-9]+)?$ ]]; then
    echo "ERROR: PostgreSQL storage size '${size}' is not a supported Kubernetes quantity." >&2
    return 1
  fi
}

# Return the existing CNPG cluster name, or nothing if it does not exist.
# A failed lookup is not proof of absence: applying the StatefulSet's Service
# could otherwise repoint a running legacy database.
ao_cnpg_cluster_name() {
  local namespace="$1" crd cluster
  if ! crd=$(kubectl get crd clusters.postgresql.cnpg.io --ignore-not-found -o name); then
    echo "ERROR: Could not check for CloudNativePG; refusing to change AO PostgreSQL." >&2
    return 1
  fi
  [ -n "$crd" ] || return 0
  if ! cluster=$(kubectl get clusters.postgresql.cnpg.io orchestrator-postgres -n "$namespace" \
    --ignore-not-found -o name); then
    echo "ERROR: Could not check the CloudNativePG cluster; refusing to change AO PostgreSQL." >&2
    return 1
  fi
  printf '%s' "$cluster"
}

# A StatefulSet's volumeClaimTemplates are immutable. Reuse the template size,
# not the potentially expanded PVC size, when reapplying an existing set. If
# the set is gone but its PVC remains, use the PVC's requested size instead.
ao_postgres_storage_size() {
  local namespace="$1" requested_size="$2" document existing_size=""
  if ! document=$(kubectl get statefulset orchestrator-postgres -n "$namespace" \
    --ignore-not-found -o json); then
    echo "ERROR: Could not read the PostgreSQL StatefulSet; refusing to apply the manifest." >&2
    return 1
  fi
  if [ -n "$document" ]; then
    if ! existing_size=$(printf '%s' "$document" | jq -er \
      '[.spec.volumeClaimTemplates[] | select(.metadata.name == "data") | .spec.resources.requests.storage] | if length == 1 and (.[0] | type == "string" and length > 0) then .[0] else error("missing data claim size") end'); then
      echo "ERROR: Could not read the PostgreSQL StatefulSet claim size; refusing to apply the manifest." >&2
      return 1
    fi
  else
    if ! document=$(kubectl get pvc data-orchestrator-postgres-0 -n "$namespace" \
      --ignore-not-found -o json); then
      echo "ERROR: Could not read the retained PostgreSQL PVC; refusing to apply the manifest." >&2
      return 1
    fi
    if [ -n "$document" ]; then
      if ! existing_size=$(printf '%s' "$document" | jq -er \
        '.spec.resources.requests.storage | strings | select(length > 0)'); then
        echo "ERROR: Could not read the retained PostgreSQL PVC size; refusing to apply the manifest." >&2
        return 1
      fi
    fi
  fi
  local size="${existing_size:-$requested_size}"
  ao_validate_postgres_storage_size "$size" || return 1
  if [ -n "$existing_size" ] && [ "$existing_size" != "$requested_size" ]; then
    echo "  Preserving PostgreSQL claim size in manifest: ${existing_size} (requested: ${requested_size})" >&2
  fi
  printf '%s\n' "$size"
}
