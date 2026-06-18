#!/usr/bin/env bash
# Deploy AAP Self-Service Portal
# ADDON_REQUIRES_AAP=true
#
# Enables the Self-Service Automation Portal component in AAP 2.7+.
# Patches the existing AAP CR to enable portal or creates new portal-enabled CR.
#
# Prerequisites:
#   - AAP operator 2.7+ installed
#   - AAP CR deployed (will be patched to enable portal)
#
# Usage:
#   ./deploy.sh          # Enable portal
#   ./deploy.sh --delete # Disable portal

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Disabling Self-Service Portal..."

  # Patch AAP CR to disable portal
  if kubectl get aap aap -n "$NAMESPACE" &>/dev/null; then
    kubectl patch aap aap -n "$NAMESPACE" --type merge \
      -p '{"spec":{"portal":{"disabled":true}}}' || {
      echo "WARNING: Failed to patch AAP CR. Portal may still be running."
    }
    echo "✓ Portal disabled in AAP CR"
  else
    echo "WARNING: AAP CR 'aap' not found in namespace '$NAMESPACE'"
  fi

  exit 0
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl not connected to cluster"
  exit 1
fi

# Check AAP operator is running
if ! kubectl get csv -n "$NAMESPACE" 2>/dev/null | grep -q "aap-operator"; then
  echo "ERROR: AAP operator not found in namespace '$NAMESPACE'"
  echo "  Deploy AAP first: aap-demo deploy"
  exit 1
fi

# Check AAP CR exists
if ! kubectl get aap aap -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: AAP CR 'aap' not found in namespace '$NAMESPACE'"
  echo "  Deploy AAP first: aap-demo deploy"
  exit 1
fi

echo "Enabling Self-Service Portal..."

# Patch existing AAP CR to enable portal
kubectl patch aap aap -n "$NAMESPACE" --type merge \
  -p '{"spec":{"portal":{"disabled":false}}}' || {
  echo "ERROR: Failed to patch AAP CR"
  exit 1
}

echo ""
echo "✓ Self-Service Portal enabled!"
echo ""
echo "  Portal will be available at:"
echo "    https://aap-${NAMESPACE}.apps.127.0.0.1.nip.io (integrated with AAP UI)"
echo ""
echo "  Status:  kubectl get aap aap -n $NAMESPACE -o jsonpath='{.spec.portal}'"
echo "  Pods:    kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=portal"
echo ""
echo "  Note: Portal components are managed by the AAP operator."
echo "  Full deployment may take 2-5 minutes."
echo ""
