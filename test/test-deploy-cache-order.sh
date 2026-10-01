#!/usr/bin/env bash
# Regression test: deploy must verify cluster and OVN readiness before loading
# cached images into the MicroShift runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/../aap-demo.sh"

cmd_deploy=$(sed -n '/^cmd_deploy() {$/,/^}$/p' "$DEPLOY_SCRIPT")

cluster_info_line=$(printf '%s\n' "$cmd_deploy" | grep -n 'kubectl cluster-info' | head -1 | cut -d: -f1)
ovn_ready_line=$(printf '%s\n' "$cmd_deploy" | grep -n '_wait_for_ovn_ready' | head -1 | cut -d: -f1)
cache_load_line=$(printf '%s\n' "$cmd_deploy" | grep -n '^  _load_local_cache$' | head -1 | cut -d: -f1)

if [ -z "$cluster_info_line" ] || [ -z "$ovn_ready_line" ] || [ -z "$cache_load_line" ]; then
  echo "✗ deploy must contain cluster, OVN, and cache readiness steps" >&2
  exit 1
fi

if [ "$cluster_info_line" -ge "$cache_load_line" ]; then
  echo "✗ deploy must verify Kubernetes connectivity before loading the cache" >&2
  exit 1
fi

if [ "$ovn_ready_line" -ge "$cache_load_line" ]; then
  echo "✗ deploy must wait for OVN readiness before loading the cache" >&2
  exit 1
fi

echo "✓ deploy verifies Kubernetes and OVN readiness before loading the cache"
