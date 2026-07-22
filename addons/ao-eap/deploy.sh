#!/usr/bin/env bash
set -euo pipefail

# Deploy Automation Orchestrator Early Access to aap-demo
#
# Automates the full 10-step AO EAP install using aapctl CLI.
# Uses cluster pull secret for registry.redhat.io authentication.
#
# Prerequisites:
#   1. Registry path for AO images (provided by Red Hat contact)
#   2. Cluster pull secret with credentials for the registry
#   3. aap-demo cluster running with OLM installed (aap-demo deploy)
#
# Usage:
#   ./deploy.sh          # Install Automation Orchestrator EAP
#   ./deploy.sh --delete # Remove Automation Orchestrator

NAMESPACE="automation-orchestrator"
# Detect which namespace catalog-operator is actually watching.
# operator-sdk OLM (MicroShift/Linux) watches olm; OpenShift OLM watches openshift-marketplace.
_CATALOG_OP_ARGS=$(kubectl get deployment catalog-operator -n olm \
  -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || echo "")
if echo "$_CATALOG_OP_ARGS" | grep -q '"openshift-marketplace"'; then
  MARKETPLACE_NAMESPACE="openshift-marketplace"
else
  MARKETPLACE_NAMESPACE="olm"
fi
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.crc/machines/crc/kubeconfig}"
STORAGE_CLASS="${AO_STORAGE_CLASS:-topolvm-provisioner}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-$HOME/.aap-demo/pull-secret.txt}"
AAPCTL_BIN="/usr/local/bin/aapctl"
AO_STATE_FILE="${AO_STATE_FILE:-$HOME/.aap-demo/ao-eap-state}"

ACTION="${1:-deploy}"
FORCE="${FORCE:-}"
for _arg in "$@"; do
  [ "$_arg" = "--force" ] && FORCE=1
done
OS="$(uname -s)"

_HAT_IDX=0
hat() {
  _HAT_IDX=$(((_HAT_IDX + 1) % 2))
  case $_HAT_IDX in
    0) printf '⏳' ;;
    1) printf '⌛' ;;
  esac
}

# --- Delete ---
if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing Automation Orchestrator..."

  if command -v aapctl >/dev/null 2>&1; then
    aapctl uninstall automation-orchestrator --force --yes 2>/dev/null || true
  fi

  kubectl delete catalogsource cs-automation-orchestrator \
    -n "$MARKETPLACE_NAMESPACE" 2>/dev/null || true
  kubectl delete secret ao-registry-pull-secret \
    -n "$MARKETPLACE_NAMESPACE" 2>/dev/null || true
  # Strip finalizers so namespace doesn't hang when operator is already gone
  kubectl get automationorchestrators.aap.ansible.com -n "$NAMESPACE" \
    -o name 2>/dev/null \
    | xargs -r -I{} kubectl patch {} -n "$NAMESPACE" \
      --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' \
      2>/dev/null || true

  kubectl delete namespace "$NAMESPACE" --wait=false 2>/dev/null || true
  kubectl delete namespace cloudnative-pg --wait=false 2>/dev/null || true

  # Poll until namespaces are gone (finalizers, CRD cleanup, etc. can delay termination)
  echo "  Waiting for namespaces to terminate..."
  for _i in $(seq 1 60); do
    _ao_ns=$(kubectl get namespace "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    _cnpg_ns=$(kubectl get namespace cloudnative-pg --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    printf "\r  $(hat) automation-orchestrator: %s  cloudnative-pg: %s    " \
      "$([ "$_ao_ns" -eq 0 ] && echo "gone" || echo "terminating")" \
      "$([ "$_cnpg_ns" -eq 0 ] && echo "gone" || echo "terminating")"
    if [ "$_ao_ns" -eq 0 ] && [ "$_cnpg_ns" -eq 0 ]; then
      echo ""
      break
    fi
    if [ "$_i" -eq 60 ]; then
      echo ""
      echo "  ⚠ Namespaces still terminating after 5 minutes — continuing anyway"
      echo "  Check: kubectl get namespace $NAMESPACE cloudnative-pg"
    fi
    sleep 5
  done

  if [ -f "$AO_STATE_FILE" ]; then
    # shellcheck source=/dev/null
    source "$AO_STATE_FILE"
  fi
  CNPG_VERSION="${CNPG_VERSION:-1.25.1}"
  CNPG_MANIFEST="https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_VERSION}/cnpg-${CNPG_VERSION}.yaml"
  kubectl delete -f "$CNPG_MANIFEST" 2>/dev/null || true
  rm -f "$AO_STATE_FILE"

  echo "✓ Automation Orchestrator removed"
  exit 0
fi

# --- Skip if already running (unless --force) ---
if [ -z "$FORCE" ]; then
  _ao_total=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | { grep -v "Completed" || true; } | wc -l | tr -d ' ' || echo "0")
  _ao_running=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | { grep "Running" || true; } | wc -l | tr -d ' ' || echo "0")
  _cs_state=$(kubectl get catalogsource cs-automation-orchestrator \
    -n "$MARKETPLACE_NAMESPACE" \
    -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
  if [ "${_ao_total:-0}" -gt 0 ] && [ "$_ao_running" -eq "$_ao_total" ] && [ "$_cs_state" = "READY" ]; then
    echo "✓ Automation Orchestrator already running ($_ao_running/$_ao_total pods, CatalogSource READY)"
    echo "  Use FORCE=1 or --force to reinstall."
    echo ""
    AO_ROUTE=$(kubectl get routes -n "$NAMESPACE" \
      -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
    [ -n "$AO_ROUTE" ] && echo "  URL:      https://${AO_ROUTE}"
    echo "  Username: admin"
    echo "  Status:   kubectl get pods -n $NAMESPACE"
    exit 0
  fi
fi

# --- Prerequisites ---
if ! command -v gh >/dev/null 2>&1; then
  echo "Installing gh CLI (GitHub CLI — required to download aapctl from private repo)..."
  if [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    brew install gh
  elif command -v dnf >/dev/null 2>&1; then
    echo "  (sudo required to install package — enter your local login password):"
    sudo dnf install -y gh
  elif command -v apt-get >/dev/null 2>&1; then
    echo "  (sudo required to install package — enter your local login password):"
    sudo apt-get install -y gh 2>/dev/null || {
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list
      sudo apt-get update && sudo apt-get install -y gh
    }
  else
    GH_ARCH="$(uname -m)"
    case "$GH_ARCH" in
      x86_64) GH_ARCH="amd64" ;;
      aarch64 | arm64) GH_ARCH="arm64" ;;
    esac
    GH_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    GH_VERSION=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
      | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    GH_TMP="$(mktemp -d)"
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_${GH_OS}_${GH_ARCH}.tar.gz" \
      | tar -xz -C "$GH_TMP"
    echo "  Installing gh to /usr/local/bin/gh (requires sudo — enter your local login password):"
    sudo install -m 755 "$GH_TMP/gh_${GH_VERSION}_${GH_OS}_${GH_ARCH}/bin/gh" /usr/local/bin/gh
    rm -rf "$GH_TMP"
  fi
  echo "✓ gh CLI installed"
fi
if ! gh auth token >/dev/null 2>&1; then
  echo "ERROR: gh CLI not authenticated. Run: gh auth login"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Installing jq (required for secret manipulation)..."
  if [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    brew install jq
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y jq
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y jq
  else
    echo "ERROR: jq not found and cannot auto-install. Install manually: https://jqlang.github.io/jq/download/"
    exit 1
  fi
  echo "✓ jq installed"
fi

# --- Step 1: Index image + pull secret ---
if [ -z "${AO_INDEX_IMAGE:-}" ]; then
  echo ""
  echo "Your Red Hat point of contact will provide the full operator index image reference."
  echo ""
  read -r -p "Index image (full URL with tag): " AO_INDEX_IMAGE
  echo ""

  if [ -z "$AO_INDEX_IMAGE" ]; then
    echo "ERROR: Index image is required."
    exit 1
  fi
fi
echo "✓ Index image: $AO_INDEX_IMAGE"

# Check for pull secret using the registry host from the index image
if [ -f "$PULL_SECRET_FILE" ]; then
  registry_host=$(echo "$AO_INDEX_IMAGE" | cut -d'/' -f1)
  if jq -e --arg host "$registry_host" '.auths[$host]' "$PULL_SECRET_FILE" >/dev/null 2>&1; then
    echo "✓ Using pull secret from $PULL_SECRET_FILE for $registry_host"
  else
    echo "WARNING: Pull secret exists but may not have credentials for $registry_host"
  fi
else
  echo "WARNING: No pull secret found at $PULL_SECRET_FILE"
  echo "  Cluster pull secret will be used if available."
fi

# --- Step 2: Install aapctl ---
if ! command -v aapctl >/dev/null 2>&1; then
  echo "Installing aapctl..."
  ARCH="$(uname -m)"

  case "${OS}-${ARCH}" in
    Darwin-arm64 | Darwin-aarch64)
      OS_NAME="darwin"
      ARCH_NAME="arm64"
      ;;
    Darwin-x86_64)
      OS_NAME="darwin"
      ARCH_NAME="amd64"
      ;;
    Linux-x86_64)
      OS_NAME="linux"
      ARCH_NAME="amd64"
      ;;
    Linux-aarch64 | Linux-arm64)
      OS_NAME="linux"
      ARCH_NAME="arm64"
      ;;
    *)
      echo "ERROR: Unsupported platform: ${OS}-${ARCH}"
      exit 1
      ;;
  esac

  AAPCTL_VERSION="${AAPCTL_VERSION:-}"
  if [ -z "$AAPCTL_VERSION" ]; then
    echo "Fetching latest aapctl version..."
    AAPCTL_VERSION=$(gh api repos/automation-nexus/aapctl/releases/latest --jq '.tag_name' 2>/dev/null || true)
    if [ -z "$AAPCTL_VERSION" ]; then
      echo "ERROR: Could not resolve latest aapctl version. Set AAPCTL_VERSION=vX.Y.Z and retry."
      exit 1
    fi
    echo "  -> ${AAPCTL_VERSION}"
  fi
  VERSION_NUM="${AAPCTL_VERSION#v}"
  BINARY="aapctl_${VERSION_NUM}_${OS_NAME}_${ARCH_NAME}"

  TMP_DIR="$(mktemp -d)"
  gh release download "$AAPCTL_VERSION" \
    --repo automation-nexus/aapctl \
    --pattern "$BINARY" \
    --pattern "checksums.txt" \
    --dir "$TMP_DIR"
  TMP_FILE="$TMP_DIR/$BINARY"
  TMP_SHA="$TMP_DIR/checksums.txt"

  EXPECTED_SHA=$(grep "$BINARY" "$TMP_SHA" | awk '{print $1}') \
    || { echo "ERROR: $BINARY not found in checksums.txt"; rm -rf "$TMP_DIR"; exit 1; }
  if [ "$OS" = "Darwin" ]; then
    ACTUAL_SHA=$(shasum -a 256 "$TMP_FILE" | awk '{print $1}')
  else
    ACTUAL_SHA=$(sha256sum "$TMP_FILE" | awk '{print $1}')
  fi
  if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo "ERROR: aapctl checksum mismatch. Expected: $EXPECTED_SHA, Got: $ACTUAL_SHA"
    rm -rf "$TMP_DIR"
    exit 1
  fi
  echo "  Installing aapctl to ${AAPCTL_BIN} (requires sudo — enter your macOS/local login password):"
  sudo install -m 755 "$TMP_FILE" "$AAPCTL_BIN"
  rm -rf "$TMP_DIR"

  if [ "$OS" = "Darwin" ]; then
    xattr -d com.apple.quarantine "$AAPCTL_BIN" 2>/dev/null || true
  fi

  echo "✓ aapctl installed to $AAPCTL_BIN"
else
  echo "✓ aapctl: $(aapctl version 2>/dev/null | head -1 || echo "installed")"
fi

# Clean up any leftover CatalogSource from the other namespace (whichever we're not using)
for _ns in olm openshift-marketplace; do
  [ "$_ns" = "$MARKETPLACE_NAMESPACE" ] && continue
  kubectl delete catalogsource cs-automation-orchestrator -n "$_ns" 2>/dev/null || true
  kubectl delete secret ao-registry-pull-secret -n "$_ns" 2>/dev/null || true
done

# --- Step 3: Namespace + SCCs ---
echo "Creating namespaces..."
kubectl create namespace "$NAMESPACE" 2>/dev/null || true
kubectl create namespace "$MARKETPLACE_NAMESPACE" 2>/dev/null || true
oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${NAMESPACE}" 2>/dev/null || true
oc adm policy add-scc-to-group privileged "system:serviceaccounts:${NAMESPACE}" 2>/dev/null || true
# OLM bundle unpack jobs run in the marketplace namespace and need anyuid for
# images that specify a non-root UID outside the namespace's allocated range
oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${MARKETPLACE_NAMESPACE}" 2>/dev/null || true
oc adm policy add-scc-to-group privileged "system:serviceaccounts:${MARKETPLACE_NAMESPACE}" 2>/dev/null || true
# PodSecurity admission (separate from SCCs) blocks catalog pods if namespace is restricted.
# Relax to privileged so catalog-operator can create the registry-server pod.
kubectl label namespace "$MARKETPLACE_NAMESPACE" \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=baseline \
  pod-security.kubernetes.io/audit=restricted \
  --overwrite 2>/dev/null || true
echo "✓ Namespaces ready"

# --- Step 4: Pull secret + CatalogSource ---
echo "Creating pull secret and CatalogSource..."
# Create pull secret from the local pull-secret file if available
if [ -f "$PULL_SECRET_FILE" ]; then
  kubectl create secret generic ao-registry-pull-secret \
    --from-file=.dockerconfigjson="$PULL_SECRET_FILE" \
    --type=kubernetes.io/dockerconfigjson \
    -n "$MARKETPLACE_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "WARNING: No pull secret file found, using cluster default"
fi

kubectl apply -f - <<EOF
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: cs-automation-orchestrator
  namespace: ${MARKETPLACE_NAMESPACE}
spec:
  sourceType: grpc
  image: ${AO_INDEX_IMAGE}
  displayName: Automation Orchestrator
  secrets:
  - ao-registry-pull-secret
EOF

echo "Waiting for CatalogSource pod..."
for i in $(seq 1 30); do
  PHASE=$(kubectl get pods -n "$MARKETPLACE_NAMESPACE" \
    -l olm.catalogSource=cs-automation-orchestrator \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  CS_STATE=$(kubectl get catalogsource cs-automation-orchestrator \
    -n "$MARKETPLACE_NAMESPACE" \
    -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "unknown")
  if [ "$PHASE" = "Running" ] && [ "$CS_STATE" = "READY" ]; then
    echo "✓ CatalogSource ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo ""
    echo "ERROR: CatalogSource pod not Running after 5 minutes."
    echo "  CatalogSource status:"
    kubectl describe catalogsource cs-automation-orchestrator -n "$MARKETPLACE_NAMESPACE" 2>/dev/null | tail -20
    echo "  Pods in $MARKETPLACE_NAMESPACE:"
    kubectl get pods -n "$MARKETPLACE_NAMESPACE" 2>/dev/null
    echo ""
    echo "  Hint: check pull secret and image digest are still valid."
    echo "        kubectl get events -n $MARKETPLACE_NAMESPACE --sort-by=.lastTimestamp | tail -20"
    exit 1
  fi
  POD_STATUS="${PHASE:-pending}"
  printf "\r  $(hat) catalog pod: %-10s | CatalogSource: %-10s    " "${POD_STATUS}" "${CS_STATE}"
  sleep 10
done
echo ""

# --- Step 4b: Install CloudNativePG operator ---
# aapctl hardcodes "certified-operators" as the CNPG catalog source, which
# doesn't exist on MicroShift and the AO index doesn't bundle CNPG.
# Install directly from upstream release manifest instead.
CNPG_VERSION="${CNPG_VERSION:-1.25.1}"

if kubectl get crd clusters.postgresql.cnpg.io &>/dev/null; then
  echo "✓ CloudNativePG CRDs already registered"
  mkdir -p "$(dirname "$AO_STATE_FILE")"
  grep -q "^CNPG_VERSION=" "$AO_STATE_FILE" 2>/dev/null || echo "CNPG_VERSION=${CNPG_VERSION}" >>"$AO_STATE_FILE"
else
  echo "Installing CloudNativePG operator v${CNPG_VERSION}..."
  CNPG_MANIFEST="https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_VERSION}/cnpg-${CNPG_VERSION}.yaml"
  if ! kubectl apply --server-side -f "$CNPG_MANIFEST" 2>&1 | tail -5; then
    echo "ERROR: Failed to install CloudNativePG from ${CNPG_MANIFEST}"
    exit 1
  fi
  mkdir -p "$(dirname "$AO_STATE_FILE")"
  echo "CNPG_VERSION=${CNPG_VERSION}" >"$AO_STATE_FILE"
  oc adm policy add-scc-to-group anyuid "system:serviceaccounts:cnpg-system" 2>/dev/null || true
  oc adm policy add-scc-to-group privileged "system:serviceaccounts:cnpg-system" 2>/dev/null || true

  echo "Waiting for CloudNativePG operator..."
  kubectl rollout status deployment/cnpg-controller-manager \
    -n cnpg-system --timeout=5m
  echo "✓ CloudNativePG operator running"
fi

# --- Step 4c: Create PostgreSQL cluster ---
echo "Creating PostgreSQL cluster for Automation Orchestrator..."

# If a PVC from a prior install exists, delete the cluster and PVC so postgres
# reinitializes from scratch. This ensures the AO admin password in the
# initial-admin-password secret matches what the migration job writes to the DB.
if kubectl get pvc orchestrator-postgres-1 -n "$NAMESPACE" &>/dev/null; then
  echo "  Existing postgres data found — deleting cluster and PVC for fresh init..."
  kubectl delete cluster orchestrator-postgres -n "$NAMESPACE" 2>/dev/null || true
  # Wait for CNPG pods to terminate so the pvc-protection finalizer is released
  kubectl wait --for=delete cluster/orchestrator-postgres -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  kubectl delete pvc orchestrator-postgres-1 -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
fi

PG_PASSWORD="$(head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"

kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: orchestrator-postgres-secret
  namespace: ${NAMESPACE}
stringData:
  database: orchestrator
  host: orchestrator-postgres-rw.${NAMESPACE}.svc
  password: ${PG_PASSWORD}
  port: "5432"
  username: orchestrator
type: kubernetes.io/basic-auth
---
apiVersion: v1
kind: Secret
metadata:
  name: temporal-postgres-secret
  namespace: ${NAMESPACE}
stringData:
  database: temporal
  host: orchestrator-postgres-rw.${NAMESPACE}.svc
  password: ${PG_PASSWORD}
  port: "5432"
  username: orchestrator
type: kubernetes.io/basic-auth
---
apiVersion: v1
kind: Secret
metadata:
  name: temporal-visibility-postgres-secret
  namespace: ${NAMESPACE}
stringData:
  database: temporal_visibility
  host: orchestrator-postgres-rw.${NAMESPACE}.svc
  password: ${PG_PASSWORD}
  port: "5432"
  username: orchestrator
type: kubernetes.io/basic-auth
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: orchestrator-postgres
  namespace: ${NAMESPACE}
spec:
  bootstrap:
    initdb:
      owner: orchestrator
      secret:
        name: orchestrator-postgres-secret
  imageName: ghcr.io/cloudnative-pg/postgresql:15
  instances: 1
  postgresql:
    parameters:
      max_connections: "200"
  storage:
    storageClass: ${STORAGE_CLASS}
    size: 5Gi
EOF

echo "Waiting for PostgreSQL cluster to be ready..."
for i in $(seq 1 60); do
  READY=$(kubectl get cluster orchestrator-postgres -n "$NAMESPACE" \
    -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
  if [ "$READY" = "1" ]; then
    echo "✓ PostgreSQL cluster ready"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: PostgreSQL cluster not ready after 10 minutes. Continuing..."
  fi
  printf "\r  $(hat) readyInstances: %-4s    " "${READY}"
  sleep 10
done
echo ""

kubectl apply -f - <<EOF
---
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: orchestrator
  namespace: ${NAMESPACE}
spec:
  cluster:
    name: orchestrator-postgres
  name: orchestrator
  owner: orchestrator
---
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: temporal
  namespace: ${NAMESPACE}
spec:
  cluster:
    name: orchestrator-postgres
  name: temporal
  owner: orchestrator
---
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: temporal-visibility
  namespace: ${NAMESPACE}
spec:
  cluster:
    name: orchestrator-postgres
  name: temporal_visibility
  owner: orchestrator
EOF
echo "✓ PostgreSQL databases created"

# --- Step 5: Create AO operator subscription ---
# aapctl hardcodes "redhat-operators" as the catalog source for the AO
# Subscription and ignores --set overrides. Pre-create the OperatorGroup
# and Subscription ourselves pointing to cs-automation-orchestrator.
# aapctl will skip these in step 8 since they already exist.
echo "Creating AO operator subscription..."
kubectl delete subscription automation-orchestrator-operator -n "$NAMESPACE" --wait=false 2>/dev/null || true
kubectl get installplan -n "$NAMESPACE" -o name 2>/dev/null \
  | xargs -r kubectl delete -n "$NAMESPACE" --wait=false 2>/dev/null || true
# CSV delete can hang forever if the OLM csv-cleanup finalizer is stuck
# (common after --force when the namespace was briefly terminating). Delete
# without waiting, then strip finalizers if it doesn't clear quickly.
kubectl get csv -n "$NAMESPACE" -o name 2>/dev/null \
  | grep "automation-orchestrator" \
  | xargs -r kubectl delete -n "$NAMESPACE" --wait=false 2>/dev/null || true
for _csv_wait in $(seq 1 12); do
  _stuck_csv=$(kubectl get csv -n "$NAMESPACE" -o name 2>/dev/null \
    | grep "automation-orchestrator" || true)
  [ -z "$_stuck_csv" ] && break
  if [ "$_csv_wait" -ge 6 ]; then
    echo "  Clearing stuck CSV finalizers..."
    echo "$_stuck_csv" | while read -r _csv; do
      kubectl patch "$_csv" -n "$NAMESPACE" --type=json \
        -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    done
  fi
  sleep 5
done
kubectl apply -f - <<EOF
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: automation-orchestrator-operator
  namespace: ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: automation-orchestrator-operator
  namespace: ${NAMESPACE}
spec:
  channel: early-access
  installPlanApproval: Automatic
  name: automation-orchestrator-operator
  source: cs-automation-orchestrator
  sourceNamespace: ${MARKETPLACE_NAMESPACE}
EOF

# --- Step 6: Wait for CSV, patch image references ---
echo "Waiting for CSV..."
CSV_NAME=""
for i in $(seq 1 30); do
  # Ignore CSVs that are still terminating from the stale-state cleanup above
  CSV_NAME=$(kubectl get csv -n "$NAMESPACE" -o json 2>/dev/null \
    | python3 -c '
import json, sys
items = json.load(sys.stdin).get("items", [])
for item in items:
  name = item.get("metadata", {}).get("name", "")
  if "automation-orchestrator-operator" not in name:
    continue
  if item.get("metadata", {}).get("deletionTimestamp"):
    continue
  print(f"clusterserviceversion.operators.coreos.com/{name}")
  break
' 2>/dev/null || echo "")
  if [ -n "$CSV_NAME" ]; then
    echo "✓ CSV: $CSV_NAME"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo ""
    echo "ERROR: CSV not found after 5 minutes."
    echo "  Subscription status:"
    kubectl get subscription automation-orchestrator-operator -n "$NAMESPACE" \
      -o jsonpath='{.status}' 2>/dev/null | python3 -m json.tool 2>/dev/null \
      || kubectl get subscription automation-orchestrator-operator -n "$NAMESPACE" 2>/dev/null
    echo "  InstallPlans:"
    kubectl get installplan -n "$NAMESPACE" 2>/dev/null
    echo ""
    echo "  Check: kubectl get csv -n $NAMESPACE"
    exit 1
  fi
  SUB_STATE=$(kubectl get subscription automation-orchestrator-operator \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
  IP_COUNT=$(kubectl get installplan -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  printf "\r  $(hat) subscription: %-15s | installplans: %-3s    " "${SUB_STATE}" "${IP_COUNT}"
  sleep 10
done
echo ""

# Images are already on registry.redhat.io — no CSV patching needed
echo "✓ CSV ready (images on registry.redhat.io)"

# --- Step 7: Copy secret to namespace, link to operator SA, restart ---
# Wait for operator deployment to be created by OLM (CSV appears before deployment exists)
echo "Waiting for operator deployment..."
for i in $(seq 1 30); do
  if kubectl get deployment automation-orchestrator-operator-controller-manager \
    -n "$NAMESPACE" &>/dev/null; then
    echo "✓ Operator deployment found"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: Operator deployment not created after 5 minutes."
    kubectl get csv -n "$NAMESPACE"
    exit 1
  fi
  printf "\r  $(hat) waiting for operator deployment...    "
  sleep 10
done
echo ""

echo "Linking pull secret to operator..."
kubectl get secret ao-registry-pull-secret -n "$MARKETPLACE_NAMESPACE" -o json \
  | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid,
             .metadata.creationTimestamp, .metadata.annotations,
             .metadata.managedFields)' \
  | kubectl apply -n "$NAMESPACE" -f -

kubectl patch serviceaccount automation-orchestrator-operator-controller-manager \
  -n "$NAMESPACE" --type=merge \
  -p '{"imagePullSecrets":[{"name":"ao-registry-pull-secret"}]}' 2>/dev/null || true

kubectl patch serviceaccount default \
  -n "$NAMESPACE" --type=merge \
  -p '{"imagePullSecrets":[{"name":"ao-registry-pull-secret"}]}' 2>/dev/null || true

kubectl -n "$NAMESPACE" rollout restart \
  deployment/automation-orchestrator-operator-controller-manager

echo "Waiting for operator pod..."
kubectl rollout status deployment/automation-orchestrator-operator-controller-manager \
  -n "$NAMESPACE" --timeout=5m
echo "✓ Operator running"

# --- Step 8: Second-pass install (full, with CR) — apply without waiting, then monitor pods ---
# Delete the initial admin password secret so the operator generates a fresh one.
# If it's left over from a previous install the operator skips generation, leaving
# a stale value that no longer matches the newly-initialized AO database.
kubectl delete secret automation-orchestrator-initial-admin-password \
  -n "$NAMESPACE" 2>/dev/null || true
echo "Running full install (second pass)..."
aapctl install automation-orchestrator \
  --kubeconfig "$KUBECONFIG_PATH" \
  --set automation-orchestrator-operator.namespace="$NAMESPACE" \
  --set cloudnative-pg-operator.enabled=false \
  --no-wait

# --- Step 9: Patch CR with pull secret, restart ---
echo "Patching AutomationOrchestrator CR..."
AO_CR=$(kubectl get automationorchestrator -n "$NAMESPACE" -o name 2>/dev/null | head -1 || echo "")
if [ -n "$AO_CR" ]; then
  kubectl patch "$AO_CR" -n "$NAMESPACE" --type=merge \
    -p '{"spec":{"imagePullSecrets":[{"name":"ao-registry-pull-secret"}]}}'
fi

kubectl -n "$NAMESPACE" rollout restart \
  deployment/automation-orchestrator-operator-controller-manager
echo "Waiting for operator to restart and reconcile..."
kubectl -n "$NAMESPACE" rollout status \
  deployment/automation-orchestrator-operator-controller-manager --timeout=5m

# --- Step 10: Wait for pods, show credentials + route ---
echo "Waiting for all pods to be ready (may take 10+ minutes)..."
# After --no-wait install the operator pod may be the only Running pod; wait for AO
# application pods to be scheduled before entering the progress loop.
_settle=0
while [ "$_settle" -lt 120 ]; do
  _ao_total=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | { grep -v "Completed" || true; } | wc -l | tr -d ' ')
  [ "${_ao_total:-0}" -gt 2 ] && break
  printf "\r  Waiting for AO pods to be scheduled... (%ds)    " "$_settle"
  sleep 10
  _settle=$((_settle + 10))
done
echo ""
_AO_TIMEOUT=1200 # 20 minutes
_AO_START=$(date +%s)
while true; do
  _ao_total=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | { grep -v "Completed" || true; } | wc -l | tr -d ' ')
  _ao_running=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | { grep "Running" || true; } | wc -l | tr -d ' ')
  _ao_problem=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | { grep -E "CrashLoopBackOff|Error|ImagePullBackOff" || true; } | wc -l | tr -d ' ')
  _AO_ELAPSED=$(($(date +%s) - _AO_START))
  printf "\r  Pods: %s/%s running" "$_ao_running" "$_ao_total"
  [ "${_ao_problem:-0}" -gt 0 ] && printf "  (%s problem)" "$_ao_problem"
  printf " (%ds elapsed)    " "$_AO_ELAPSED"
  if [ "${_ao_total:-0}" -gt 0 ] && [ "${_ao_running:-0}" -eq "${_ao_total:-0}" ]; then
    echo ""
    break
  fi
  if [ "$_AO_ELAPSED" -ge "$_AO_TIMEOUT" ]; then
    echo ""
    echo "  ⚠ Pods not all ready after 20 minutes — continuing anyway"
    echo "  Check: kubectl get pods -n $NAMESPACE"
    break
  fi
  sleep 10
done

echo ""

PASS_SECRET=$(kubectl get secret -n "$NAMESPACE" \
  -o name 2>/dev/null | grep -i "admin-password" | head -1 || echo "")

echo "Waiting for route..."
AO_ROUTE=""
for i in $(seq 1 30); do
  AO_ROUTE=$(kubectl get routes -n "$NAMESPACE" \
    -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  if [ -n "$AO_ROUTE" ]; then
    echo "✓ Route ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "WARNING: Route not available after 5 minutes"
  fi
  printf "\r  $(hat) waiting for route...    "
  sleep 10
done
echo ""

echo "✓ Automation Orchestrator deployed!"
echo ""
if [ -n "$AO_ROUTE" ]; then
  echo "  URL:      https://${AO_ROUTE}"
else
  echo "  URL:      kubectl get routes -n ${NAMESPACE} -o jsonpath='{.items[0].spec.host}'"
fi
echo "  Username: admin"
if [ -n "$PASS_SECRET" ]; then
  if [ "${CI:-}" != "true" ]; then
    AO_PASSWORD=$(kubectl get "$PASS_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    [ -n "$AO_PASSWORD" ] \
      && echo "  Password: ${AO_PASSWORD}" \
      || echo "  Password: kubectl get $PASS_SECRET -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
  else
    echo "  Password: kubectl get $PASS_SECRET -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
  fi
else
  echo "  Password: kubectl get secret -n $NAMESPACE | grep admin-password"
fi
