#!/usr/bin/env bash
# Scale down non-AAP components to free resources
#
# Presents an interactive checklist of discovered namespaces and lets the user
# choose which to scale down. Never touches the AAP namespace.
#
# Usage:
#   ./deploy.sh          # Interactive scale down
#   ./deploy.sh --delete # Restore original replica counts

set -euo pipefail

ACTION="${1:-deploy}"
AAP_NAMESPACE="${NAMESPACE:-aap-operator}"
STATE_FILE="${HOME}/.aap-demo/scale-down-state"
AAP_DEMO_CONFIG="${AAP_DEMO_CONFIG:-$HOME/.aap-demo/config}"

_BOLD='\033[1m'
_GREEN='\033[0;32m'
_YELLOW='\033[0;33m'
_NC='\033[0m'

# OpenShift platform namespaces
PLATFORM_NAMESPACES=(
  openshift-monitoring
  openshift-console
  openshift-insights
  openshift-image-registry
  openshift-marketplace
  openshift-multus
  openshift-network-diagnostics
  openshift-network-console
  openshift-cluster-samples-operator
  openshift-machine-api
  openshift-cluster-machine-approver
  openshift-kube-storage-version-migrator
)

_addon_namespace() {
  case "$1" in
    ao-eap) echo "automation-orchestrator" ;;
    apme-eap) echo "apme" ;;
    portal) echo "redhat-rhaap-portal" ;;
    *) echo "" ;;
  esac
}

_get_enabled_addons() {
  if [ -f "$AAP_DEMO_CONFIG" ]; then
    grep '^ADDONS=' "$AAP_DEMO_CONFIG" 2>/dev/null | cut -d= -f2 | tr ',' ' ' || true
  fi
}

_count_running() {
  local ns="$1"
  local deploys stats total=0
  deploys=$(kubectl get deployments -n "$ns" --no-headers -o custom-columns='REPLICAS:.spec.replicas' 2>/dev/null | awk '$1>0' | wc -l | tr -d ' ')
  stats=$(kubectl get statefulsets -n "$ns" --no-headers -o custom-columns='REPLICAS:.spec.replicas' 2>/dev/null | awk '$1>0' | wc -l | tr -d ' ')
  total=$((deploys + stats))
  echo "$total"
}

_state_has_entry() {
  local ns="$1" kind="$2" name="$3"
  [ -f "$STATE_FILE" ] && grep -qF "${ns}|${kind}|${name}|" "$STATE_FILE"
}

_scale_namespace() {
  local ns="$1"
  local name replicas

  if [ "$ns" = "$AAP_NAMESPACE" ]; then
    return
  fi

  if ! kubectl get namespace "$ns" &>/dev/null; then
    return
  fi

  # Scale deployments
  while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    replicas=$(echo "$line" | awk '{print $2}')
    [ -z "$name" ] && continue
    [ "$replicas" = "0" ] && continue
    _state_has_entry "$ns" "deployment" "$name" && continue

    echo "${ns}|deployment|${name}|${replicas}" >>"$STATE_FILE"
    echo "  ${ns}: deployment/${name} ${replicas} → 0"
    kubectl scale deployment "${name}" -n "${ns}" --replicas=0 2>/dev/null || true
  done <<<"$(kubectl get deployments -n "$ns" --no-headers -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas' 2>/dev/null)"

  # Scale statefulsets
  while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    replicas=$(echo "$line" | awk '{print $2}')
    [ -z "$name" ] && continue
    [ "$replicas" = "0" ] && continue
    _state_has_entry "$ns" "statefulset" "$name" && continue

    echo "${ns}|statefulset|${name}|${replicas}" >>"$STATE_FILE"
    echo "  ${ns}: statefulset/${name} ${replicas} → 0"
    kubectl scale statefulset "${name}" -n "${ns}" --replicas=0 2>/dev/null || true
  done <<<"$(kubectl get statefulsets -n "$ns" --no-headers -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas' 2>/dev/null)"
}

# --- Restore ---
if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Restoring scaled-down components..."

  if [ ! -f "$STATE_FILE" ]; then
    echo "  No scale-down state found — nothing to restore"
    exit 0
  fi

  while IFS='|' read -r ns kind name replicas; do
    [ -z "$ns" ] && continue
    echo "  ${ns}: ${kind}/${name} → ${replicas}"
    kubectl scale "${kind}" "${name}" -n "${ns}" --replicas="${replicas}" 2>/dev/null || true
  done <"$STATE_FILE"

  rm -f "$STATE_FILE"
  echo "✓ Components restored"
  exit 0
fi

# --- Deploy (scale down) ---

# Only useful on full OpenShift
PRESET=$(crc config get preset 2>/dev/null | awk '{print $NF}' || echo "")
if [ "$PRESET" = "microshift" ]; then
  echo "scale-down is for full OpenShift only (MicroShift doesn't have these components)"
  exit 0
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl not connected to cluster"
  exit 1
fi

# ---------------------------------------------------------------------------
# Build list of available namespaces to scale down
# ---------------------------------------------------------------------------
declare -a AVAILABLE_NS=()
declare -a AVAILABLE_LABELS=()

for ns in "${PLATFORM_NAMESPACES[@]}"; do
  if [ "$ns" = "$AAP_NAMESPACE" ]; then continue; fi
  if kubectl get namespace "$ns" &>/dev/null; then
    running=$(_count_running "$ns")
    if [ "$running" -gt 0 ]; then
      AVAILABLE_NS+=("$ns")
      AVAILABLE_LABELS+=("$ns  ($running running)")
    fi
  fi
done

ENABLED_ADDONS=$(_get_enabled_addons)
for addon in $ENABLED_ADDONS; do
  addon_ns="$(_addon_namespace "$addon")"
  if [ -n "$addon_ns" ] && [ "$addon_ns" != "$AAP_NAMESPACE" ]; then
    if kubectl get namespace "$addon_ns" &>/dev/null; then
      running=$(_count_running "$addon_ns")
      if [ "$running" -gt 0 ]; then
        AVAILABLE_NS+=("$addon_ns")
        AVAILABLE_LABELS+=("$addon_ns  [$addon addon] ($running running)")
      fi
    fi
  fi
done

if [ ${#AVAILABLE_NS[@]} -eq 0 ]; then
  echo "No namespaces with running workloads found to scale down."
  exit 0
fi

# ---------------------------------------------------------------------------
# Interactive selection
# ---------------------------------------------------------------------------
echo ""
printf "${_BOLD}Select namespaces to scale down:${_NC}\n"
printf "  (AAP namespace '${AAP_NAMESPACE}' is always excluded)\n"
echo ""

declare -a SELECTED=()
for i in "${!AVAILABLE_LABELS[@]}"; do
  SELECTED+=("true")
done

if [ -t 0 ]; then
  for i in "${!AVAILABLE_LABELS[@]}"; do
    printf "  %d) [x] %s\n" "$((i + 1))" "${AVAILABLE_LABELS[$i]}"
  done
  echo ""
  printf "  Enter numbers to toggle (space-separated), ${_BOLD}a${_NC} for all, ${_BOLD}n${_NC} for none, or press Enter to confirm: "
  read -r _selection </dev/tty

  if [ -n "$_selection" ]; then
    case "$_selection" in
      a | A | all)
        ;;
      n | N | none)
        for i in "${!SELECTED[@]}"; do
          SELECTED[$i]="false"
        done
        ;;
      *)
        IFS=' ' read -ra _sel_nums <<<"$_selection"
        for num in "${_sel_nums[@]}"; do
          if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#AVAILABLE_NS[@]}" ]; then
            idx=$((num - 1))
            if [ "${SELECTED[$idx]}" = "true" ]; then
              SELECTED[$idx]="false"
            else
              SELECTED[$idx]="true"
            fi
          fi
        done
        ;;
    esac
  fi
else
  # Non-interactive: require explicit opt-in to avoid scaling everything silently
  for i in "${!SELECTED[@]}"; do
    SELECTED[$i]="false"
  done
  if [ "${SCALE_DOWN_CONFIRM:-}" != "yes" ]; then
    echo "Non-interactive mode: no namespaces selected."
    echo "Run interactively, or set SCALE_DOWN_CONFIRM=yes to scale all discovered namespaces."
    exit 0
  fi
  for i in "${!SELECTED[@]}"; do
    SELECTED[$i]="true"
  done
fi

# Collect selected namespaces
declare -a TARGET_NS=()
for i in "${!AVAILABLE_NS[@]}"; do
  if [ "${SELECTED[$i]}" = "true" ]; then
    TARGET_NS+=("${AVAILABLE_NS[$i]}")
  fi
done

if [ ${#TARGET_NS[@]} -eq 0 ]; then
  echo "No namespaces selected — nothing to do."
  exit 0
fi

# ---------------------------------------------------------------------------
# Scale down selected namespaces
# ---------------------------------------------------------------------------
echo ""
echo "Scaling down ${#TARGET_NS[@]} namespace(s)..."
echo ""

mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"

for ns in "${TARGET_NS[@]}"; do
  _scale_namespace "$ns"
done

echo ""
echo "✓ Selected components scaled down"
echo "  Restore with: aap-demo disable scale-down"
echo "  To idle AAP itself: aap-demo idle true"
