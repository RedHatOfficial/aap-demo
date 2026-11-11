#!/usr/bin/env bash
# Regression test for OVN readiness checks across OpenShift and MicroShift
# topologies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AAP_DEMO_SH="${REPO_ROOT}/aap-demo.sh"

wait_function=$(sed -n '/^_wait_for_ovn_ready()/,/^}$/p' "$AAP_DEMO_SH")
eval "$wait_function"

sleep() { :; }

kubectl() {
  if [ "$1" = "get" ] && [ "$2" = "namespace" ] && [ "$3" = "openshift-ovn-kubernetes" ]; then
    return 0
  fi

  if [ "$1" = "get" ] && [ "$2" = "daemonset" ] && [ "$3" = "ovnkube-master" ] \
    && [[ "$*" != *"jsonpath"* ]]; then
    return "${OVN_MASTER_EXISTS:-1}"
  fi

  if [ "$1" = "get" ] && [ "$2" = "daemonset" ] && [ "$3" = "ovnkube-node" ] \
    && [[ "$*" == *"desiredNumberScheduled"* ]]; then
    printf '1'
    return 0
  fi
  if [ "$1" = "get" ] && [ "$2" = "daemonset" ] && [ "$3" = "ovnkube-node" ] \
    && [[ "$*" == *"numberReady"* ]]; then
    printf '1'
    return 0
  fi

  if [ "$1" = "get" ] && [ "$2" = "daemonset" ] && [ "$3" = "ovnkube-master" ] \
    && [[ "$*" == *"desiredNumberScheduled"* ]]; then
    printf '1'
    return 0
  fi
  if [ "$1" = "get" ] && [ "$2" = "daemonset" ] && [ "$3" = "ovnkube-master" ] \
    && [[ "$*" == *"numberReady"* ]]; then
    printf '1'
    return 0
  fi

  echo "unexpected kubectl call: $*" >&2
  return 1
}

export AAP_OVN_TIMEOUT=5

OVN_MASTER_EXISTS=0
_wait_for_ovn_ready >/dev/null
echo "✓ OVN readiness succeeds when ovnkube-master is absent (OpenShift)"

OVN_MASTER_EXISTS=1
_wait_for_ovn_ready >/dev/null
echo "✓ OVN readiness succeeds when ovnkube-master exists (MicroShift)"
