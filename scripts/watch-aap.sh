#!/usr/bin/env bash
set -euo pipefail

# Watch AAP deployment status
# Works with any AAP deployment (MINC, CRC, full OpenShift, etc.)
#
# Usage:
#   ./watch-aap.sh [namespace]
#   Default namespace: aap-operator
#
# Environment Variables:
#   SHOW_SERVICES=true    Show services (default: false)
#   SHOW_PVCS=true        Show PVCs (default: false)
#   SHOW_ALL=true         Show all sections (services + PVCs)

NAMESPACE="${1:-aap-operator}"
TIMEOUT=3600 # 60 minutes
INTERVAL=30  # 30 seconds between checks

# Optional display sections (default: off for cleaner output)
SHOW_SERVICES="${SHOW_SERVICES:-false}"
SHOW_PVCS="${SHOW_PVCS:-false}"
if [ "${SHOW_ALL:-false}" = "true" ]; then
  SHOW_SERVICES=true
  SHOW_PVCS=true
fi

echo "Watching AAP deployment in namespace: $NAMESPACE"
echo "Press Ctrl+C to exit"
echo ""

# Track deploy time - once calculated, we cache it
# This avoids issues with lastTransitionTime being updated on every reconciliation
CACHED_DEPLOY_TIME=""
WATCH_START_EPOCH=$(date +%s)

while true; do
  clear

  # Calculate elapsed time
  CR_CREATED=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null || true)
  if [ -n "$CR_CREATED" ]; then
    if [[ "$(uname)" == "Darwin" ]]; then
      CR_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$CR_CREATED" +%s 2>/dev/null || echo "0")
    else
      CR_EPOCH=$(date -d "$CR_CREATED" +%s 2>/dev/null || echo "0")
    fi
    NOW_EPOCH=$(date +%s)
    ELAPSED=$((NOW_EPOCH - CR_EPOCH))
  else
    ELAPSED=0
  fi

  # Get cluster context info
  CLUSTER_NAME=$(kubectl config current-context 2>/dev/null || echo "unknown")
  CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown")

  echo "=== AAP Deployment Status ($ELAPSED s / $TIMEOUT s) ==="
  echo "Cluster: $CLUSTER_NAME | Server: $CLUSTER_SERVER"
  echo "Namespace: $NAMESPACE"
  echo ""

  echo "Ansible Automation Platforms:"
  kubectl get aap -n "$NAMESPACE" 2>/dev/null || echo "  No AAP CR found in namespace $NAMESPACE"
  echo ""

  echo "AAP CR Conditions:"
  kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[*].status.conditions}' 2>/dev/null \
    | jq -r '.[] | "  \(.type): \(.status) - \(.message)"' 2>/dev/null || echo "  No status yet"
  echo ""

  echo "Pods:"
  kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "  No pods found"
  echo ""

  if [ "$SHOW_PVCS" = "true" ]; then
    echo "PersistentVolumeClaims:"
    kubectl get pvc -n "$NAMESPACE" 2>/dev/null || echo "  No PVCs found"
    echo ""
  fi

  if [ "$SHOW_SERVICES" = "true" ]; then
    echo "Services:"
    kubectl get svc -n "$NAMESPACE" 2>/dev/null || echo "  No services found"
    echo ""
  fi

  echo "Routes:"
  kubectl get route -n "$NAMESPACE" 2>/dev/null || echo "  No routes found"
  echo ""

  # Check if deployment is complete
  # Get pod counts - store output first to avoid pipeline issues
  POD_OUTPUT=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null || true)
  if [ -n "$POD_OUTPUT" ]; then
    NOT_RUNNING_COUNT=$(printf '%s' "$POD_OUTPUT" | { grep -v -E 'Running|Completed' || true; } | wc -l | tr -d '[:space:]')
    RUNNING_COUNT=$(printf '%s' "$POD_OUTPUT" | { grep -E 'Running|Completed' || true; } | wc -l | tr -d '[:space:]')
  else
    NOT_RUNNING_COUNT=0
    RUNNING_COUNT=0
  fi
  AAP_SUCCESSFUL_RAW=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[*].status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || echo "")
  AAP_SUCCESSFUL=$(echo "$AAP_SUCCESSFUL_RAW" | grep -q "True" && echo "true" || echo "false")

  # Check Running condition message - "Awaiting next reconciliation" means operator is idle
  # Running: True with "Awaiting next reconciliation" = idle (ready)
  # Running: True with other message (e.g., "Reconciling AAP") = actively working
  AAP_RUNNING_MSG=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[*].status.conditions[?(@.type=="Running")].message}' 2>/dev/null || echo "")
  AAP_IDLE=$(echo "$AAP_RUNNING_MSG" | grep -qi "awaiting" && echo "true" || echo "false")

  echo "Completion Check: NOT_RUNNING=$NOT_RUNNING_COUNT, RUNNING_PODS=$RUNNING_COUNT, AAP_SUCCESSFUL=$AAP_SUCCESSFUL, AAP_IDLE=$AAP_IDLE"

  # Deployment is complete when:
  # - All pods are Running/Completed (NOT_RUNNING=0)
  # - At least some pods exist (RUNNING_PODS > 0)
  # - Successful condition is True
  # - Running condition message contains "Awaiting" (operator is idle, not reconciling)
  if [ "$NOT_RUNNING_COUNT" -eq 0 ] 2>/dev/null && [ "$RUNNING_COUNT" -gt 0 ] 2>/dev/null && [ "$AAP_SUCCESSFUL" = "true" ] && [ "$AAP_IDLE" = "true" ]; then
    # Get the AAP route URL
    AAP_ROUTE=$(kubectl get route -n "$NAMESPACE" -o jsonpath='{.items[?(@.metadata.name=="aap")].spec.host}' 2>/dev/null || true)
    if [ -z "$AAP_ROUTE" ]; then
      # Fallback: try to find any route with 'aap' in the name
      AAP_ROUTE=$(kubectl get route -n "$NAMESPACE" --no-headers 2>/dev/null | awk '/aap/ {print $2}' | head -1 || true)
    fi

    # Get admin password from secret (query AAP CR for secret name, fallback to common names)
    ADMIN_PASSWORD=""
    ADMIN_SECRET=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].status.adminPasswordSecret}' 2>/dev/null || true)
    if [ -n "$ADMIN_SECRET" ]; then
      ADMIN_PASSWORD=$(kubectl get secret -n "$NAMESPACE" "$ADMIN_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi
    # Fallback to common secret names if CR didn't specify or secret not found
    # Priority: auto-generated secrets first, then custom-admin-password as last resort
    if [ -z "$ADMIN_PASSWORD" ]; then
      for secret_name in aap-admin-password aap-controller-admin-password custom-admin-password; do
        ADMIN_PASSWORD=$(kubectl get secret -n "$NAMESPACE" "$secret_name" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
        if [ -n "$ADMIN_PASSWORD" ]; then
          break
        fi
      done
    fi

    # Get CSV name (operator version)
    CSV_NAME=$(kubectl get csv -n "$NAMESPACE" -o jsonpath='{.items[?(@.metadata.name)].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^aap-operator' | head -1 || true)

    # Detect deployment method
    DEPLOY_METHOD="Unknown"
    if kubectl get catalogsource -n openshift-marketplace 2>/dev/null | grep -q "redhat-operators"; then
      DEPLOY_METHOD="Latest Catalog (redhat-operators)"
    elif kubectl get catalogsource -n openshift-marketplace 2>/dev/null | grep -q "aap-cloud-index"; then
      DEPLOY_METHOD="Latest Catalog (cloud-index)"
    elif kubectl get catalogsource -n "$NAMESPACE" 2>/dev/null | grep -q "aap-cloud-index"; then
      DEPLOY_METHOD="Latest Catalog (cloud-index)"
    fi

    # Calculate deployment time (only once, then cache it)
    # We measure from when we started watching to first successful completion
    # This avoids issues with lastTransitionTime being updated on every reconciliation
    if [ -z "$CACHED_DEPLOY_TIME" ]; then
      NOW_EPOCH=$(date +%s)
      DEPLOY_SECONDS=$((NOW_EPOCH - WATCH_START_EPOCH))
      # If deployment completed almost instantly (< 5s), it was already deployed
      if [ "$DEPLOY_SECONDS" -lt 5 ]; then
        CACHED_DEPLOY_TIME="(already deployed)"
      else
        DEPLOY_MINUTES=$((DEPLOY_SECONDS / 60))
        DEPLOY_SECS=$((DEPLOY_SECONDS % 60))
        CACHED_DEPLOY_TIME="${DEPLOY_MINUTES}m ${DEPLOY_SECS}s"
      fi
    fi
    DEPLOY_TIME="$CACHED_DEPLOY_TIME"

    echo ""
    echo "================================================================"
    echo "  AAP on OpenShift Deployment Complete"
    echo "================================================================"
    echo ""
    if [ -n "$DEPLOY_TIME" ]; then
      echo "  Deploy Time:     ${DEPLOY_TIME}"
    fi
    echo "  Deploy Method:   ${DEPLOY_METHOD}"
    if [ -n "$CSV_NAME" ]; then
      echo "  Operator CSV:    ${CSV_NAME}"
    fi
    echo ""
    if [ -n "$AAP_ROUTE" ]; then
      echo "  AAP URL: https://${AAP_ROUTE}"
    else
      echo "  AAP URL: (route not found - check 'kubectl get route -n $NAMESPACE')"
    fi
    echo ""
    echo "  Login Credentials:"
    echo "    Username: admin"
    if [ -n "$ADMIN_PASSWORD" ]; then
      echo "    Password: ${ADMIN_PASSWORD}"
    else
      echo "    Password: (check secret: kubectl get secret -n $NAMESPACE aap-admin-password -o jsonpath='{.data.password}' | base64 -d)"
    fi
    echo ""
    echo "================================================================"
    echo ""
    break
  fi

  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo ""
    echo "✗  Deployment timeout reached ($TIMEOUT s)"
    echo "Run 'kubectl get pods -n $NAMESPACE' to check current status"
    break
  fi

  echo "Waiting $INTERVAL seconds before next check..."
  sleep $INTERVAL
done
