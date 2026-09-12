#!/usr/bin/env bash
# HashiVault Helper Functions
# Shared utility functions for vault operations

# Vault CLI wrapper (uses kubectl exec)
vault_exec() {
  kubectl exec vault-0 -n "$NAMESPACE" -- vault "$@" 2>/dev/null
}

# Read secret from vault
vault_read_secret() {
  local path="$1"
  vault_exec kv get -format=json "$path"
}

# Write secret to vault
vault_write_secret() {
  local path="$1"
  shift
  vault_exec kv put "$path" "$@"
}

# Check if KV v2 engine exists at given path
vault_kv_engine_exists() {
  local path="${1:-secret/}"
  vault_exec secrets list -format=json 2>/dev/null | jq -e ".\"${path}\"" >/dev/null 2>&1
}

# Get vault health status
vault_get_health() {
  local vault_addr="${1:-http://vault.${NAMESPACE}.svc.cluster.local:8200}"
  curl -sk "${vault_addr}/v1/sys/health" 2>/dev/null
}

# Check if vault pod is ready
vault_pod_ready() {
  kubectl get pod vault-0 -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"
}

# Get vault pod phase
vault_pod_phase() {
  kubectl get pod vault-0 -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null
}
