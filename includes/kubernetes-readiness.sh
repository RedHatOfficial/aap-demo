#!/usr/bin/env bash

if [ -n "${_AAP_DEMO_KUBERNETES_READINESS_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_KUBERNETES_READINESS_LOADED=1

aap_demo_wait_deployment() {
  local namespace="$1"
  local deployment="$2"
  local timeout="${3:-10m}"

  if kubectl rollout status "deployment/${deployment}" -n "$namespace" \
    --timeout="$timeout"; then
    return 0
  fi

  echo "ERROR: Deployment ${namespace}/${deployment} did not become ready within ${timeout}." >&2
  kubectl get deployment "$deployment" -n "$namespace" >&2 || true
  kubectl get pods -n "$namespace" \
    -l "app.kubernetes.io/name=${deployment}" -o wide >&2 || true
  kubectl get events -n "$namespace" --sort-by=.lastTimestamp 2>/dev/null \
    | tail -20 >&2 || true
  return 1
}

aap_demo_wait_daemonset() {
  local namespace="$1"
  local daemonset="$2"
  local timeout="${3:-5m}"

  if kubectl rollout status "daemonset/${daemonset}" -n "$namespace" \
    --timeout="$timeout"; then
    return 0
  fi

  echo "ERROR: DaemonSet ${namespace}/${daemonset} did not become ready within ${timeout}." >&2
  kubectl get daemonset "$daemonset" -n "$namespace" >&2 || true
  kubectl get pods -n "$namespace" -o wide >&2 || true
  return 1
}

aap_demo_active_pods_ready() {
  local namespace="$1"
  local selector="${2:-}"
  local args=(-n "$namespace" -o json)
  [ -z "$selector" ] || args+=(-l "$selector")

  kubectl get pods "${args[@]}" 2>/dev/null | jq -e '
    ([.items[]
      | select(.status.phase != "Succeeded")
      | select(
          .status.phase == "Running"
          and any(.status.conditions[]?; .type == "Ready" and .status == "True")
        )
    ] | length)
    ==
    ([.items[] | select(.status.phase != "Succeeded")] | length)
  ' >/dev/null
}
