#!/usr/bin/env bash
# Regression test: deploy must fail before OLM/AAP work when the selected CR
# requires the missing nfs-local-rwx StorageClass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/../aap-demo.sh"

cmd_deploy=$(sed -n '/^cmd_deploy() {$/,/^}$/p' "$DEPLOY_SCRIPT")
storage_check=$(sed -n '/^_verify_aap_storage_prerequisites() {$/,/^}$/p' "$DEPLOY_SCRIPT")

if [ -z "$storage_check" ]; then
  echo "✗ deploy must define an AAP storage prerequisite check" >&2
  exit 1
fi

storage_call_line=$(printf '%s\n' "$cmd_deploy" \
  | grep -n '^  _verify_aap_storage_prerequisites' | head -1 | cut -d: -f1)
cache_load_line=$(printf '%s\n' "$cmd_deploy" \
  | grep -n '^  _load_local_cache$' | head -1 | cut -d: -f1)
olm_install_line=$(printf '%s\n' "$cmd_deploy" \
  | grep -n 'addons/olm/deploy.sh' | head -1 | cut -d: -f1)

if [ -z "$storage_call_line" ] || [ -z "$cache_load_line" ] || [ -z "$olm_install_line" ]; then
  echo "✗ deploy must check storage before cache loading and OLM installation" >&2
  exit 1
fi

if [ "$storage_call_line" -ge "$cache_load_line" ] || [ "$storage_call_line" -ge "$olm_install_line" ]; then
  echo "✗ storage prerequisite check must run before cache loading and OLM installation" >&2
  exit 1
fi

if ! printf '%s\n' "$storage_check" | grep -q 'nfs-local-rwx'; then
  echo "✗ storage prerequisite check must validate nfs-local-rwx" >&2
  exit 1
fi

if ! printf '%s\n' "$storage_check" | grep -q 'file_storage_storage_class'; then
  echo "✗ storage prerequisite check must honor the selected CR storage class" >&2
  exit 1
fi

eval "$storage_check"
SCRIPT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
kubectl() { return 1; }

if output=$(CR=minimal _verify_aap_storage_prerequisites 2>&1); then
  echo "✗ default CR must fail when nfs-local-rwx is unavailable" >&2
  exit 1
fi
if ! printf '%s\n' "$output" | grep -q 'requires the missing nfs-local-rwx StorageClass'; then
  echo "✗ missing storage error must explain the default CR failure" >&2
  exit 1
fi

if ! CR=minimal-noingress _verify_aap_storage_prerequisites; then
  echo "✗ no-ingress CR must not require nfs-local-rwx" >&2
  exit 1
fi

echo "✓ deploy validates selected AAP storage prerequisites before OLM/AAP work"
