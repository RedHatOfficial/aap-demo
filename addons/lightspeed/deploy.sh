#!/usr/bin/env bash
# Deploy Ansible Lightspeed (intelligent assistant) for aap-demo, backed by the
# local Ollama LLM (qwen2.5:3b) instead of a cloud model.
#
# Creates the model configuration Secret pointing at the in-cluster Ollama
# OpenAI-compatible endpoint, then an AnsibleLightspeed CR that the
# ansible-lightspeed operator reconciles into the Lightspeed API + chatbot.
#
# Prerequisites:
#   - aap-demo enable ollama   (provides the model endpoint)
#   - AAP operator installed   (ansible-lightspeed operator runs in aap-operator)
#
# Usage:
#   ./deploy.sh           # Deploy Lightspeed wired to Ollama
#   ./deploy.sh --delete  # Remove Lightspeed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="${LIGHTSPEED_NAMESPACE:-aap-operator}"
CR_NAME="${LIGHTSPEED_CR_NAME:-aap-lightspeed}"
MODEL_SECRET="${LIGHTSPEED_MODEL_SECRET:-aap-lightspeed-model-config}"
# In-cluster Ollama OpenAI-compatible endpoint (no TLS, no auth on the svc).
MODEL_URL="${LIGHTSPEED_MODEL_URL:-http://ollama.aap-demo-ollama.svc.cluster.local:11434/v1}"
MODEL_ID="${LIGHTSPEED_MODEL_ID:-qwen2.5:3b}"
# Ollama ignores the key but the operator requires a non-empty value.
MODEL_API_KEY="${LIGHTSPEED_MODEL_API_KEY:-ollama}"
MODEL_TYPE="${LIGHTSPEED_MODEL_TYPE:-wca-onprem}"

_err() { printf 'ERROR: %s\n' "$*" >&2; }
_log() { printf '  %s\n' "$*"; }

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing Ansible Lightspeed..."
  kubectl delete ansiblelightspeed "$CR_NAME" -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete secret "$MODEL_SECRET" -n "$NAMESPACE" 2>/dev/null || true
  echo "✓ Ansible Lightspeed removed"
  exit 0
fi

# --- preflight ---------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || { _err "kubectl not found"; exit 1; }

if ! kubectl get crd ansiblelightspeeds.lightspeed.ansible.com >/dev/null 2>&1; then
  _err "AnsibleLightspeed CRD not found — is the ansible-lightspeed operator installed?"
  exit 1
fi

if ! kubectl get svc ollama -n aap-demo-ollama >/dev/null 2>&1; then
  _err "Ollama service not found. Run: aap-demo enable ollama"
  exit 1
fi

# --- model configuration secret ----------------------------------------------
_log "▸ Creating model configuration secret ($MODEL_SECRET)"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${MODEL_SECRET}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: aap-demo
type: Opaque
stringData:
  model_url: "${MODEL_URL}"
  model_api_key: "${MODEL_API_KEY}"
  model_id: "${MODEL_ID}"
  model_type: "${MODEL_TYPE}"
  # wca-onprem (on-prem OpenAI-compatible, e.g. Ollama) requires a username;
  # Ollama ignores it but the operator validates its presence.
  username: "ollama"
  model_verify_ssl: "false"
  model_enable_anonymization: "false"
EOF

# --- AnsibleLightspeed CR ------------------------------------------------------
_log "▸ Creating AnsibleLightspeed CR ($CR_NAME)"
kubectl apply -f - <<EOF
apiVersion: lightspeed.ansible.com/v1alpha1
kind: AnsibleLightspeed
metadata:
  name: ${CR_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: aap-demo
spec:
  admin_user: admin
  model_config_secret_name: ${MODEL_SECRET}
  api:
    replicas: 1
  chatbot_api:
    replicas: 1
EOF

# On SNO/full OpenShift the postgres PVC is provisioned root-owned and the
# anyuid SCC alone does not make it writable — the postgres container fails with
# "mkdir: cannot create directory '/var/lib/pgsql/data/userdata': Permission
# denied". The operator's postgres_data_volume_init init container is gated to
# non-OpenShift, so fix the volume ownership directly with a one-off privileged
# pod, then restart postgres so it starts clean.
_fix_postgres_pvc() {
  local pvc="postgres-15-${CR_NAME}-postgres-15-0" fixpod="${CR_NAME}-pgdata-fix"
  # Only needed when the postgres pod exists and is crash-looping on permissions.
  if ! kubectl get pod -n "$NAMESPACE" "${CR_NAME}-postgres-15-0" >/dev/null 2>&1; then
    return 0
  fi
  # The postgres pod needs a moment to start and crash before the permission
  # error appears in its log. Poll briefly for it instead of checking once.
  local _attempt
  for _attempt in $(seq 1 24); do
    if kubectl logs -n "$NAMESPACE" "${CR_NAME}-postgres-15-0" --tail=5 2>/dev/null \
        | grep -q "Permission denied"; then
      break
    fi
    # If the pod is already Running and past the crash, no fix is needed.
    if kubectl get pod -n "$NAMESPACE" "${CR_NAME}-postgres-15-0" \
        -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
      return 0
    fi
    sleep 5
  done
  if ! kubectl logs -n "$NAMESPACE" "${CR_NAME}-postgres-15-0" --tail=5 2>/dev/null \
      | grep -q "Permission denied"; then
    return 0
  fi
  _log "▸ Fixing postgres PVC ownership (SNO root-owned volume)"
  kubectl delete pod -n "$NAMESPACE" "$fixpod" >/dev/null 2>&1 || true
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${fixpod}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: aap-demo
spec:
  securityContext:
    runAsUser: 0
  containers:
  - name: fix
    image: registry.redhat.io/rhel9/postgresql-15:1
    securityContext:
      runAsUser: 0
    command: ["/bin/sh","-c"]
    args:
      - mkdir -p /var/lib/pgsql/data/userdata &&
        chown -R 26:26 /var/lib/pgsql/data &&
        chmod 700 /var/lib/pgsql/data/userdata
    volumeMounts:
    - name: data
      mountPath: /var/lib/pgsql/data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${pvc}
  restartPolicy: Never
EOF
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded \
    "pod/${fixpod}" -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  kubectl delete pod -n "$NAMESPACE" "$fixpod" >/dev/null 2>&1 || true
  kubectl delete pod -n "$NAMESPACE" "${CR_NAME}-postgres-15-0" >/dev/null 2>&1 || true
}

_fix_postgres_pvc

_log "▸ Waiting for Lightspeed API deployment..."
_deploy_found=false
_rollout_ok=false
for _ in $(seq 1 60); do
  if kubectl get deploy -n "$NAMESPACE" "${CR_NAME}-api" >/dev/null 2>&1; then
    _deploy_found=true
    if kubectl rollout status "deploy/${CR_NAME}-api" -n "$NAMESPACE" --timeout=5m; then
      _rollout_ok=true
    fi
    break
  fi
  sleep 5
done

if [ "$_deploy_found" != true ]; then
  _err "Lightspeed API deployment ${CR_NAME}-api never appeared in namespace ${NAMESPACE}"
  exit 1
fi
if [ "$_rollout_ok" != true ]; then
  _err "Lightspeed API deployment ${CR_NAME}-api failed to roll out"
  kubectl rollout status "deploy/${CR_NAME}-api" -n "$NAMESPACE" --timeout=10s 2>&1 >&2 || true
  exit 1
fi

echo ""
echo "✓ Ansible Lightspeed deployed"
echo "  Model:    ${MODEL_ID} via ${MODEL_URL}"
echo "  CR:       ${CR_NAME} (namespace ${NAMESPACE})"
echo "  Access:   AAP console → Lightspeed intelligent assistant"
