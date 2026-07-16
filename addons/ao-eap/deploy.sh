#!/usr/bin/env bash
set -euo pipefail

# Deploy Automation Orchestrator Early Access to aap-demo
#
# Automates the full 10-step AO EAP install using aapctl CLI.
# Requires Quay credentials from your Red Hat point of contact.
#
# Prerequisites:
#   1. ~/.aap-demo/quay-username  (your quay.io username)
#   2. ~/.aap-demo/quay-token     (your quay.io encrypted password, chmod 600)
#   3. aap-demo cluster running with OLM installed (aap-demo deploy)
#
# Usage:
#   ./deploy.sh          # Install Automation Orchestrator EAP
#   ./deploy.sh --delete # Remove Automation Orchestrator

NAMESPACE="automation-orchestrator"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.crc/machines/crc/kubeconfig}"
STORAGE_CLASS="${AO_STORAGE_CLASS:-topolvm-provisioner}"
QUAY_USERNAME_FILE="${QUAY_USERNAME_FILE:-$HOME/.aap-demo/quay-username}"
QUAY_TOKEN_FILE="${QUAY_TOKEN_FILE:-$HOME/.aap-demo/quay-token}"
AAPCTL_BIN="/usr/local/bin/aapctl"

ACTION="${1:-deploy}"

# --- Delete ---
if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing Automation Orchestrator..."

  if command -v aapctl >/dev/null 2>&1; then
    aapctl uninstall automation-orchestrator --force 2>/dev/null || true
  fi

  kubectl delete catalogsource cs-automation-orchestrator \
    -n openshift-marketplace 2>/dev/null || true
  kubectl delete secret quay-aap-viewer \
    -n openshift-marketplace 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" 2>/dev/null || true

  echo "✓ Automation Orchestrator removed"
  exit 0
fi

# --- Step 1: Check credentials ---
if [ ! -f "$QUAY_USERNAME_FILE" ] || [ ! -f "$QUAY_TOKEN_FILE" ]; then
  echo "Quay credentials required for Automation Orchestrator Early Access."
  echo ""
  echo "Your Red Hat point of contact will grant access to quay.io/aap."
  echo "Once granted, save your credentials:"
  echo ""
  echo "  echo \"your-quay-username\" > ~/.aap-demo/quay-username"
  echo "  echo \"your-quay-token\"    > ~/.aap-demo/quay-token"
  echo "  chmod 600 ~/.aap-demo/quay-token"
  echo ""
  echo "Then re-run: aap-demo enable ao-eap"
  exit 0
fi

QUAY_USERNAME="$(cat "$QUAY_USERNAME_FILE")"
QUAY_TOKEN="$(cat "$QUAY_TOKEN_FILE")"
echo "✓ Quay credentials found"

# --- Step 2: Install aapctl ---
if ! command -v aapctl >/dev/null 2>&1; then
  echo "Installing aapctl..."
  OS="$(uname -s)"
  ARCH="$(uname -m)"

  case "${OS}-${ARCH}" in
    Darwin-arm64)  BINARY="aapctl-darwin-arm64" ;;
    Darwin-x86_64) BINARY="aapctl-darwin-amd64" ;;
    Linux-x86_64)  BINARY="aapctl-linux-amd64" ;;
    Linux-aarch64) BINARY="aapctl-linux-arm64" ;;
    *)
      echo "ERROR: Unsupported platform: ${OS}-${ARCH}"
      exit 1
      ;;
  esac

  LATEST_URL="https://github.com/automation-nexus/aapctl/releases/latest/download/${BINARY}"
  TMP_FILE="$(mktemp)"
  curl -fsSL "$LATEST_URL" -o "$TMP_FILE"
  sudo install -m 755 "$TMP_FILE" "$AAPCTL_BIN"
  rm -f "$TMP_FILE"

  if [ "$OS" = "Darwin" ]; then
    xattr -d com.apple.quarantine "$AAPCTL_BIN" 2>/dev/null || true
  fi

  echo "✓ aapctl installed to $AAPCTL_BIN"
else
  echo "✓ aapctl: $(aapctl version 2>/dev/null | head -1 || echo "installed")"
fi

# --- Step 3: Namespace + SCCs ---
echo "Creating namespace $NAMESPACE..."
kubectl create namespace "$NAMESPACE" 2>/dev/null || true
oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${NAMESPACE}" 2>/dev/null || true
oc adm policy add-scc-to-group privileged "system:serviceaccounts:${NAMESPACE}" 2>/dev/null || true
echo "✓ Namespace ready"

# --- Step 4: Pull secret + CatalogSource ---
echo "Creating pull secret and CatalogSource..."
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: quay-aap-viewer
  namespace: openshift-marketplace
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: '{"auths":{"quay.io":{"username":"${QUAY_USERNAME}","password":"${QUAY_TOKEN}"}}}'
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: cs-automation-orchestrator
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/aap/ansible-automation-platform/automation-orchestrator-operator-index@sha256:99fdac7b8712e66ece76f9d48342489b214133037582d7ac81717a4b60c6fd1a
  displayName: Automation Orchestrator
  secrets:
  - quay-aap-viewer
EOF

echo "Waiting for CatalogSource pod..."
for i in $(seq 1 30); do
  PHASE=$(kubectl get pods -n openshift-marketplace \
    -l olm.catalogSource=cs-automation-orchestrator \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  if [ "$PHASE" = "Running" ]; then
    echo "✓ CatalogSource ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "WARNING: CatalogSource pod not Running after 5 minutes. Continuing..."
  fi
  sleep 10
done

# --- Step 5: First-pass install (operator only, no CR) ---
echo "Installing Automation Orchestrator operator (first pass)..."
aapctl install automation-orchestrator \
  --no-wait \
  --set automation-orchestrator-cr.enabled=false \
  --kubeconfig "$KUBECONFIG_PATH" \
  --set automation-orchestrator-operator.namespace="$NAMESPACE" \
  --set automation-orchestrator-operator.catalogSource=cs-automation-orchestrator \
  --set automation-orchestrator-operator.channel=candidate \
  --set cloudnative-pg-operator.enabled=true \
  --set cluster-cr.storageClass="$STORAGE_CLASS"

# --- Step 6: Wait for CSV, patch image references ---
echo "Waiting for CSV..."
CSV_NAME=""
for i in $(seq 1 30); do
  CSV_NAME=$(kubectl get csv -n "$NAMESPACE" -o name 2>/dev/null \
    | grep "automation-orchestrator-operator" | head -1 || echo "")
  if [ -n "$CSV_NAME" ]; then
    echo "✓ CSV: $CSV_NAME"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: CSV not found after 5 minutes. Check: kubectl get csv -n $NAMESPACE"
    exit 1
  fi
  sleep 10
done

echo "Patching CSV image references..."
CSV_JSON=$(kubectl get "$CSV_NAME" -n "$NAMESPACE" -o json)
echo "$CSV_JSON" \
  | sed 's|registry.redhat.io/ansible-automation-platform|quay.io/aap/ansible-automation-platform|g' \
  | kubectl apply -f - 2>&1 | grep -v "^Warning:" || true
echo "✓ CSV patched"

# --- Step 7: Copy secret to namespace, link to operator SA, restart ---
echo "Linking pull secret to operator..."
kubectl get secret quay-aap-viewer -n openshift-marketplace -o json \
  | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid,
             .metadata.creationTimestamp, .metadata.annotations,
             .metadata.managedFields)' \
  | kubectl apply -n "$NAMESPACE" -f -

kubectl patch serviceaccount automation-orchestrator-operator-controller-manager \
  -n "$NAMESPACE" --type=merge \
  -p '{"imagePullSecrets":[{"name":"quay-aap-viewer"}]}' 2>/dev/null || true

kubectl -n "$NAMESPACE" rollout restart \
  deployment/automation-orchestrator-operator-controller-manager

echo "Waiting for operator pod..."
kubectl rollout status deployment/automation-orchestrator-operator-controller-manager \
  -n "$NAMESPACE" --timeout=5m
echo "✓ Operator running"

# --- Step 8: Second-pass install (full, with CR) ---
echo "Running full install (second pass)..."
aapctl install automation-orchestrator \
  --kubeconfig "$KUBECONFIG_PATH" \
  --set automation-orchestrator-operator.namespace="$NAMESPACE" \
  --set automation-orchestrator-operator.catalogSource=cs-automation-orchestrator \
  --set automation-orchestrator-operator.channel=candidate \
  --set cloudnative-pg-operator.enabled=true \
  --set cluster-cr.storageClass="$STORAGE_CLASS"

# --- Step 9: Patch CR with pull secret, restart ---
echo "Patching AutomationOrchestrator CR..."
AO_CR=$(kubectl get automationorchestrator -n "$NAMESPACE" -o name 2>/dev/null | head -1 || echo "")
if [ -n "$AO_CR" ]; then
  kubectl patch "$AO_CR" -n "$NAMESPACE" --type=merge \
    -p '{"spec":{"imagePullSecrets":[{"name":"quay-aap-viewer"}]}}'
fi

kubectl -n "$NAMESPACE" rollout restart \
  deployment/automation-orchestrator-operator-controller-manager

# --- Step 10: Wait for pods, show credentials + route ---
echo "Waiting for all pods to be ready (may take 10+ minutes)..."
kubectl wait pods \
  --all \
  -n "$NAMESPACE" \
  --for=condition=Ready \
  --timeout=20m 2>/dev/null || true

echo ""

PASS_SECRET=$(kubectl get secret -n "$NAMESPACE" \
  -o name 2>/dev/null | grep -i "admin-password" | head -1 || echo "")
ADMIN_PASSWORD=""
if [ -n "$PASS_SECRET" ]; then
  ADMIN_PASSWORD=$(kubectl get "$PASS_SECRET" -n "$NAMESPACE" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
fi

AO_ROUTE=$(kubectl get routes -n "$NAMESPACE" \
  -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

echo "✓ Automation Orchestrator deployed!"
echo ""
if [ -n "$AO_ROUTE" ]; then
  echo "  URL:      https://${AO_ROUTE}"
fi
echo "  Username: admin"
if [ -n "$ADMIN_PASSWORD" ]; then
  echo "  Password: ${ADMIN_PASSWORD}"
else
  echo "  Password: kubectl get secret -n $NAMESPACE | grep admin-password"
fi
echo ""
echo "  Status:   kubectl get pods -n $NAMESPACE"
