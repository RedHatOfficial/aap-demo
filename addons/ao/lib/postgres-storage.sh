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

# Do not create a replacement database until the old CNPG controller and its
# data have been removed. Failed reads/deletes are not proof of removal.
ao_remove_cnpg_storage() {
  local namespace="$1" expected_cluster="${2:-}" cluster cluster_crd databases_crd
  if ! cluster_crd=$(kubectl get crd clusters.postgresql.cnpg.io --ignore-not-found -o name); then
    echo "ERROR: Could not check for CloudNativePG; refusing to replace PostgreSQL." >&2
    return 1
  fi
  if [ -z "$cluster_crd" ]; then
    if [ -n "$expected_cluster" ]; then
      echo "ERROR: CloudNativePG CRD disappeared; refusing to replace PostgreSQL." >&2
      return 1
    fi
    return 0
  fi
  cluster=$(ao_cnpg_cluster_name "$namespace") || return 1
  if [ -n "$cluster" ]; then
    if ! kubectl delete clusters.postgresql.cnpg.io orchestrator-postgres -n "$namespace" \
      --ignore-not-found --wait=true --timeout=180s; then
      echo "ERROR: Could not delete the CloudNativePG cluster; refusing to replace PostgreSQL." >&2
      return 1
    fi
    cluster=$(ao_cnpg_cluster_name "$namespace") || return 1
    if [ -n "$cluster" ]; then
      echo "ERROR: CloudNativePG cluster still exists; refusing to replace PostgreSQL." >&2
      return 1
    fi
  fi
  if ! databases_crd=$(kubectl get crd databases.postgresql.cnpg.io --ignore-not-found -o name); then
    echo "ERROR: Could not check CloudNativePG databases; refusing to replace PostgreSQL." >&2
    return 1
  fi
  if [ -n "$databases_crd" ] && ! kubectl delete databases.postgresql.cnpg.io --all \
    -n "$namespace" --wait=false; then
    echo "ERROR: Could not delete CloudNativePG databases; refusing to replace PostgreSQL." >&2
    return 1
  fi
  if ! kubectl delete pvc orchestrator-postgres-1 -n "$namespace" \
    --ignore-not-found --wait=true --timeout=180s; then
    echo "ERROR: Could not delete the CloudNativePG PVC; refusing to replace PostgreSQL." >&2
    return 1
  fi
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
