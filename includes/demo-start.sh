#!/usr/bin/env bash

aap_demo_start_wait() {
  local label="$1"
  shift
  local deadline=$((SECONDS + AAP_START_TIMEOUT))

  echo "Waiting for ${label} (up to ${AAP_START_TIMEOUT}s)..."
  while true; do
    if "$@"; then
      echo "  Ready: ${label}"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      _err "${label} did not become ready within ${AAP_START_TIMEOUT}s"
      return 1
    fi
    sleep 5
  done
}

aap_demo_start_api_ready() {
  kubectl get --raw=/readyz --request-timeout=5s >/dev/null 2>&1
}

aap_demo_start_workloads_ready() {
  local namespace="$1"
  local workloads
  workloads=$(kubectl get deployment,statefulset,daemonset -n "$namespace" \
    -o json --request-timeout=5s) || return 1
  printf '%s\n' "$workloads" | jq -e '
    [.items[] | select(.metadata.deletionTimestamp == null)] as $workloads |
    ($workloads | length > 0)
    and any($workloads[];
      (if .kind == "DaemonSet" then .status.desiredNumberScheduled
       else .spec.replicas // 1 end) > 0)
    and all($workloads[];
      (.status.observedGeneration // 0) >= .metadata.generation
      and if .kind == "DaemonSet" then
        (.status.numberReady // 0) == .status.desiredNumberScheduled
        and (.status.updatedNumberScheduled // 0) == .status.desiredNumberScheduled
      else
        (.status.readyReplicas // 0) == (.spec.replicas // 1)
        and (if .kind == "Deployment" then
          (.status.updatedReplicas // 0) == (.spec.replicas // 1)
          and (.status.availableReplicas // 0) == (.spec.replicas // 1)
        else true end)
      end)
  ' >/dev/null || return 1
  aap_demo_active_pods_ready "$namespace"
}

aap_demo_start_namespace() {
  local namespace="$1"
  if aap_demo_start_wait "workloads in ${namespace}" \
    aap_demo_start_workloads_ready "$namespace"; then
    return 0
  fi

  kubectl get deployment,statefulset,daemonset,pods -n "$namespace" \
    --request-timeout=5s >&2 || true
  kubectl get pods -n "$namespace" -o json --request-timeout=5s \
    | jq -r '.items[] | .metadata.name as $pod |
        .status.conditions[]? |
        select(.type == "PodScheduled" and .status == "False") |
        "\($pod): \(.message)"' >&2 || true
  kubectl get events -n "$namespace" --sort-by=.lastTimestamp \
    --request-timeout=5s | tail -15 >&2 || true
  echo "Check 'aap-demo diagnose'; resolve storage, image-pull or resource shortages, then retry 'aap-demo start'." >&2
  return 1
}

aap_demo_start_aap_complete() {
  local conditions successful running reason failure
  conditions=$(kubectl get aap -n "$NAMESPACE" -o json \
    --request-timeout=5s | jq -er '
      .items | select(length > 0) | .[] |
      [.status.conditions as $c |
        (["Successful", "Running", "Failure"][] as $type |
          ([$c[]? | select(.type == $type) | .status][0] // "-")),
        ([$c[]? | select(.type == "Successful") | .reason][0] // "-")
      ] | @tsv
    ') || return 1
  while IFS=$'\t' read -r successful running failure reason; do
    aap_condition_is_complete "$successful" "$running" "$reason" "$failure" || return 1
  done <<<"$conditions"
}

aap_demo_start_aap_route_ready() {
  local host
  host=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' \
    --request-timeout=5s) || return 1
  [ -n "$host" ] || return 1
  # Local demo ingress uses a self-signed CA, as do the existing wiring probes.
  curl -fkSs --connect-timeout 5 --max-time 10 \
    "https://${host}/api/gateway/v1/ping/" >/dev/null 2>&1
}

aap_demo_resume_demo() {
  local addons="$1"
  local namespaces namespace instances name idle addon
  local -a addon_namespaces=()

  # Only wait for infrastructure actually installed on this cluster.
  namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' \
    --request-timeout=5s) || return 1
  for namespace in openshift-ovn-kubernetes kube-proxy openshift-dns openshift-service-ca \
    openshift-ingress openshift-storage nfs-storage olm openshift-operator-lifecycle-manager; do
    if [[ " $namespaces " == *" $namespace "* ]]; then
      aap_demo_start_namespace "$namespace" || return 1
    fi
  done
  install_ingress_ca_trust || return 1

  instances=$(kubectl get aap -n "$NAMESPACE" -o json --request-timeout=5s \
    | jq -er '.items | select(length > 0) | .[] |
        [.metadata.name, (.spec.idle_aap // false)] | @tsv') || {
    _err "No readable AAP deployment in ${NAMESPACE}; run 'aap-demo deploy' first"
    return 1
  }
  while IFS=$'\t' read -r name idle; do
    if [ "$idle" = true ]; then
      echo "Resuming idle AAP '${name}'..."
      kubectl patch aap "$name" -n "$NAMESPACE" --type=merge \
        -p '{"spec":{"idle_aap":false}}' || return 1
    fi
  done <<<"$instances"

  for addon in $addons; do
    case "$addon" in
      mcp-server) name=aap-mcp-server ;;
      opa) name=opa ;;
      *) continue ;;
    esac
    if ! kubectl get deployment "$name" -n "$NAMESPACE" --request-timeout=5s >/dev/null; then
      _err "Enabled addon '${addon}' is missing; restore it with 'aap-demo enable ${addon}'"
      return 1
    fi
  done
  aap_demo_start_namespace "$NAMESPACE" || return 1
  if ! aap_demo_start_wait "AAP reconciliation" aap_demo_start_aap_complete; then
    kubectl get aap -n "$NAMESPACE" -o yaml --request-timeout=5s >&2 || true
    echo "Run 'aap-demo diagnose' and check the AAP operator logs." >&2
    return 1
  fi
  aap_demo_start_wait "AAP gateway API" aap_demo_start_aap_route_ready || return 1

  for addon in $addons; do
    case "$addon" in
      ao) namespace="${AO_NAMESPACE:-automation-orchestrator}" ;;
      ollama) namespace=aap-demo-ollama ;;
      portal) namespace="${PORTAL_NAMESPACE:-redhat-rhaap-portal}" ;;
      portal-operator) namespace="${PORTAL_OPERATOR_NAMESPACE:-automation-portal}" ;;
      apme-eap) namespace=apme ;;
      # These are checked with AAP, have no persistent workloads, or run on the host.
      *) continue ;;
    esac
    addon_namespaces+=("$namespace")
  done
  if [[ " $addons " == *" ao "* ]]; then
    aap_demo_start_namespace cnpg-system || return 1
  fi
  # macOS Bash 3.2 treats an empty array as unset under nounset.
  for namespace in ${addon_namespaces[@]+"${addon_namespaces[@]}"}; do
    aap_demo_start_namespace "$namespace" || return 1
  done

  if [[ " $addons " == *" fleet "* ]] && [ -d "${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet" ]; then
    # shellcheck source=../addons/fleet/fleet.sh
    source "${SCRIPT_DIR}/addons/fleet/fleet.sh"
    echo "Starting preserved Fleet nodes..."
    fleet_start_all || return 1
  fi

  if ! _aap_demo_run_addon_wire true; then
    _err "Addon integrations could not be restored; check the errors above and retry 'aap-demo wire'"
    return 1
  fi
  # Wiring can roll out addon deployments to update network or integration settings.
  aap_demo_start_namespace "$NAMESPACE" || return 1
  for namespace in ${addon_namespaces[@]+"${addon_namespaces[@]}"}; do
    aap_demo_start_namespace "$namespace" || return 1
  done
}
