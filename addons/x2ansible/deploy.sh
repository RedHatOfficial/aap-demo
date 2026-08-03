#!/usr/bin/env bash
# Deploy X2Ansible (RHDH + X2A Backstage plugins) to aap-demo
#
# Follows the upstream deployment flow from x2ansible.github.io/deploy:
#   1. Install Red Hat Developer Hub operator (cluster-scoped, one-time)
#   2. Create x2ansible namespace and apply app manifests
#   3. Configure x2a-credentials secret (LLM + optional AAP integration)
#
# Prerequisites:
#   - aap-demo cluster running with OLM (aap-demo deploy)
#   - registry.redhat.io pull secret (from aap-demo deploy)
#   - AWS Bedrock credentials for LLM (see README.md)
#
# Usage:
#   ./deploy.sh              # Install X2Ansible (prompts for LLM credentials if needed)
#   ./deploy.sh --reconfigure # Regenerate ~/.aap-demo/x2ansible-secrets.yaml
#   ./deploy.sh --delete     # Remove X2Ansible application resources

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${X2ANSIBLE_NAMESPACE:-x2ansible}"
AAP_NAMESPACE="${AAP_NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"
FORCE_RECONFIGURE=false
for _arg in "$@"; do
  [ "$_arg" = "--reconfigure" ] && FORCE_RECONFIGURE=true
done
SECRETS_FILE="${X2ANSIBLE_SECRETS_FILE:-$HOME/.aap-demo/x2ansible-secrets.yaml}"
RHDH_CHANNEL="${X2ANSIBLE_RHDH_CHANNEL:-fast-1.9}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}INFO:${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
error() { echo -e "${RED}ERROR:${NC} $*" >&2; }
die() {
  error "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# Environment detection (aligned with other aap-demo addons)
# ---------------------------------------------------------------------------

detect_catalog_namespace() {
  local ns
  for ns in "$AAP_NAMESPACE" olm openshift-marketplace; do
    if kubectl get catalogsource redhat-operators -n "$ns" &>/dev/null; then
      echo "$ns"
      return 0
    fi
  done
  die "redhat-operators CatalogSource not found. Run 'aap-demo deploy' first."
}

resolve_operator_namespace() {
  # Full OpenShift uses openshift-operators; operator-sdk OLM on MicroShift uses operators.
  if kubectl get namespace openshift-operators &>/dev/null; then
    echo "openshift-operators"
  elif kubectl get namespace operators &>/dev/null; then
    echo "operators"
  else
    echo "operators"
  fi
}

detect_default_storage_class() {
  local sc
  sc=$(kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | awk '{print $1}')
  if [ -n "$sc" ]; then
    echo "$sc"
    return 0
  fi
  for sc in topolvm-provisioner crc-csi-hostpath-provisioner lvms-vg1; do
    if kubectl get sc "$sc" &>/dev/null; then
      echo "$sc"
      return 0
    fi
  done
  die "No suitable StorageClass found. Expected topolvm-provisioner on aap-demo."
}

detect_cluster_arch() {
  kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo "unknown"
}

discover_aap_config() {
  AAP_ROUTE=""
  AAP_PASSWORD=""
  AAP_OAUTH_TOKEN=""

  AAP_ROUTE=$(kubectl get route -n "$AAP_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
  if [ -z "$AAP_ROUTE" ]; then
    warn "AAP route not found in $AAP_NAMESPACE — AAP integration will use placeholders"
    return 0
  fi

  local aap_cr
  aap_cr=$(kubectl get aap -n "$AAP_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$aap_cr" ]; then
    AAP_PASSWORD=$(kubectl get secret -n "$AAP_NAMESPACE" "${aap_cr}-admin-password" \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
  fi
  if [ -z "$AAP_PASSWORD" ]; then
    for secret_name in aap-admin-password myaap-admin-password; do
      AAP_PASSWORD=$(kubectl get secret -n "$AAP_NAMESPACE" "$secret_name" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
      [ -n "$AAP_PASSWORD" ] && break
    done
  fi

  if [ -n "$AAP_PASSWORD" ]; then
    info "Generating AAP OAuth token for X2Ansible publish integration..."
    local curl_response
    curl_response=$(curl -sk -u "admin:${AAP_PASSWORD}" \
      "https://${AAP_ROUTE}/api/gateway/v1/tokens/" \
      -X POST -H "Content-Type: application/json" \
      -d '{"description":"x2ansible","scope":"write"}' 2>&1 || true)
    AAP_OAUTH_TOKEN=$(echo "$curl_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
    if [ -z "$AAP_OAUTH_TOKEN" ]; then
      warn "Could not auto-generate AAP OAuth token (gateway may still be starting)"
    else
      info "AAP OAuth token generated"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Operator installation (upstream deploy/operator.yaml — RHDH only)
# ---------------------------------------------------------------------------

install_rhdh_operator() {
  local catalog_ns operator_ns
  catalog_ns=$(detect_catalog_namespace)
  operator_ns=$(resolve_operator_namespace)

  info "Installing RHDH operator (catalog: $catalog_ns, operator ns: $operator_ns)..."

  kubectl create namespace "$operator_ns" 2>/dev/null || true

  # Catalog unpack jobs and operator pods need elevated SCCs on MicroShift
  oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${operator_ns}" 2>/dev/null || true
  oc adm policy add-scc-to-group privileged "system:serviceaccounts:${operator_ns}" 2>/dev/null || true

  copy_pull_secret "$AAP_NAMESPACE" "$operator_ns" || true
  link_pull_secret_to_serviceaccount "$operator_ns" "default"

  local og_count
  og_count=$(kubectl get operatorgroup -n "$operator_ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "${og_count:-0}" -eq 0 ]; then
    sed "s|__OPERATOR_NAMESPACE__|${operator_ns}|g" \
      "${SCRIPT_DIR}/operator-group.yaml" | kubectl apply -f -
  else
    info "OperatorGroup already present in $operator_ns — skipping create"
  fi

  sed -e "s|__OPERATOR_NAMESPACE__|${operator_ns}|g" \
    -e "s|__CATALOG_NAMESPACE__|${catalog_ns}|g" \
    -e "s|channel: \"fast-1.9\"|channel: \"${RHDH_CHANNEL}\"|" \
    "${SCRIPT_DIR}/operator-subscription.yaml" | kubectl apply -f -

  info "Waiting for RHDH operator CSV..."
  local csv_name="" i
  for i in $(seq 1 60); do
    csv_name=$(kubectl get csv -n "$operator_ns" 2>/dev/null | awk '/^rhdh-operator\./ {print $1; exit}')
    if [ -n "$csv_name" ]; then
      break
    fi
    printf "\r  Waiting for CSV... (%s/60)" "$i"
    sleep 10
  done
  echo ""

  if [ -z "$csv_name" ]; then
    die "RHDH operator CSV not found after 10 minutes. Check: kubectl get subscription -n $operator_ns"
  fi

  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "csv/${csv_name}" \
    -n "$operator_ns" --timeout=600s 2>/dev/null || {
    warn "CSV $csv_name not yet Succeeded — continuing (may still reconcile)"
  }
  info "RHDH operator ready: $csv_name"
}

operator_is_installed() {
  local operator_ns
  operator_ns=$(resolve_operator_namespace)
  kubectl get csv -n "$operator_ns" 2>/dev/null | grep -q '^rhdh-operator\.'
}

copy_pull_secret() {
  local src_ns="$1"
  local dst_ns="$2"
  if ! kubectl get secret redhat-operators-pull-secret -n "$src_ns" &>/dev/null; then
    warn "Pull secret 'redhat-operators-pull-secret' not found in $src_ns"
    warn "Image pulls may fail. Run 'aap-demo deploy' first."
    return 1
  fi
  kubectl get secret redhat-operators-pull-secret -n "$src_ns" -o json \
    | python3 -c "import json,sys; d=json.load(sys.stdin); d['metadata'].pop('uid',None); d['metadata'].pop('resourceVersion',None); d['metadata'].pop('creationTimestamp',None); d['metadata']['namespace']='${dst_ns}'; print(json.dumps(d))" \
    | kubectl apply -f -
}

link_pull_secret_to_serviceaccount() {
  local ns="$1"
  local sa="$2"

  if ! kubectl get secret redhat-operators-pull-secret -n "$ns" &>/dev/null; then
    return 0
  fi
  if ! kubectl get serviceaccount "$sa" -n "$ns" &>/dev/null; then
    return 0
  fi

  local existing_secrets
  existing_secrets=$(kubectl get serviceaccount "$sa" -n "$ns" \
    -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
  if echo "$existing_secrets" | grep -qw "redhat-operators-pull-secret"; then
    return 0
  fi

  local patch_json
  patch_json=$(echo "$existing_secrets redhat-operators-pull-secret" | xargs -n1 | sort -u \
    | jq -R -s 'split("\n") | map(select(length > 0)) | map({name: .}) | {imagePullSecrets: .}')
  kubectl patch serviceaccount "$sa" -n "$ns" -p "$patch_json" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Application deployment (upstream deploy/app.yaml)
# ---------------------------------------------------------------------------

setup_namespace() {
  kubectl create namespace "$NAMESPACE" 2>/dev/null || true
  oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${NAMESPACE}" 2>/dev/null || true
  oc adm policy add-scc-to-group privileged "system:serviceaccounts:${NAMESPACE}" 2>/dev/null || true
  kubectl label namespace "$NAMESPACE" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged \
    --overwrite 2>/dev/null || true
  copy_pull_secret "$AAP_NAMESPACE" "$NAMESPACE" || true
  link_pull_secret_to_serviceaccount "$NAMESPACE" "default"
  link_pull_secret_to_serviceaccount "$NAMESPACE" "x2a-sa"
}

apply_app_manifests() {
  local storage_class
  storage_class=$(detect_default_storage_class)
  info "Applying app manifests (storageClass: $storage_class)..."

  sed -e "s|__STORAGE_CLASS__|${storage_class}|g" \
    -e "s|__NAMESPACE__|${NAMESPACE}|g" \
    "${SCRIPT_DIR}/app.yaml" \
    | kubectl apply -n "$NAMESPACE" -f -
}

# ---------------------------------------------------------------------------
# Secrets: interactive LLM credential setup (matches x2ansible docs)
# ---------------------------------------------------------------------------

is_interactive() {
  [ -t 0 ] && [ "${CI:-}" != "true" ]
}

secret_field_value() {
  local key="$1"
  [ -f "$SECRETS_FILE" ] || return 1
  python3 - "$SECRETS_FILE" "$key" <<'PY'
import sys, re
path, key = sys.argv[1], sys.argv[2]
val = ""
in_stringdata = False
for line in open(path, encoding="utf-8"):
    if line.strip() == "stringData:":
        in_stringdata = True
        continue
    if not in_stringdata:
        continue
    m = re.match(rf"^\s+{re.escape(key)}:\s*(.*)$", line)
    if m:
        raw = m.group(1).strip()
        if raw.startswith('"') and raw.endswith('"'):
            val = raw[1:-1]
        else:
            val = raw
        break
print(val)
PY
}

secrets_llm_is_configured() {
  local bearer openai_key access_key
  bearer=$(secret_field_value "AWS_BEARER_TOKEN_BEDROCK" 2>/dev/null || true)
  openai_key=$(secret_field_value "OPENAI_API_KEY" 2>/dev/null || true)
  access_key=$(secret_field_value "AWS_ACCESS_KEY_ID" 2>/dev/null || true)

  if [ -n "$bearer" ] && [ "$bearer" != "REPLACE-WITH-YOUR-AWS-BEARER-TOKEN" ]; then
    return 0
  fi
  if [ -n "$openai_key" ] && [ "$openai_key" != "not-needed" ] && [ "$openai_key" != "REPLACE-WITH-YOUR-OPENAI-API-KEY" ]; then
    return 0
  fi
  if [ -n "$access_key" ] && [ "$access_key" != "REPLACE-WITH-YOUR-AWS-ACCESS-KEY" ]; then
    local secret_key
    secret_key=$(secret_field_value "AWS_SECRET_ACCESS_KEY" 2>/dev/null || true)
    [ -n "$secret_key" ] && [ "$secret_key" != "REPLACE-WITH-YOUR-AWS-SECRET-KEY" ] && return 0
  fi
  return 1
}

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local reply=""
  if [ -n "$default" ]; then
    read -r -p "${prompt} [${default}]: " reply
    echo "${reply:-$default}"
  else
    read -r -p "${prompt}: " reply
    echo "$reply"
  fi
}

prompt_secret() {
  local prompt="$1"
  local reply=""
  read -r -s -p "${prompt}: " reply
  echo "" >&2
  echo "$reply"
}

llm_from_environment() {
  LLM_PROVIDER=""
  LLM_MODEL="${X2ANSIBLE_LLM_MODEL:-${LLM_MODEL:-}}"
  AWS_REGION="${X2ANSIBLE_AWS_REGION:-${AWS_REGION:-}}"
  AWS_BEARER_TOKEN_BEDROCK="${X2ANSIBLE_AWS_BEARER_TOKEN_BEDROCK:-${AWS_BEARER_TOKEN_BEDROCK:-}}"
  AWS_ACCESS_KEY_ID="${X2ANSIBLE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
  AWS_SECRET_ACCESS_KEY="${X2ANSIBLE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
  OPENAI_API_BASE="${X2ANSIBLE_OPENAI_API_BASE:-${OPENAI_API_BASE:-}}"
  OPENAI_API_KEY="${X2ANSIBLE_OPENAI_API_KEY:-${OPENAI_API_KEY:-}}"

  if [ -n "$AWS_BEARER_TOKEN_BEDROCK" ]; then
    LLM_PROVIDER="bedrock"
    LLM_MODEL="${LLM_MODEL:-anthropic.claude-3-7-sonnet-20250219-v1:0}"
    AWS_REGION="${AWS_REGION:-us-east-1}"
    return 0
  fi
  if [ -n "$OPENAI_API_KEY" ]; then
    LLM_PROVIDER="openai"
    LLM_MODEL="${LLM_MODEL:-gpt-4o}"
    OPENAI_API_BASE="${OPENAI_API_BASE:-https://api.openai.com/v1}"
    return 0
  fi
  if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
    LLM_PROVIDER="bedrock-iam"
    LLM_MODEL="${LLM_MODEL:-anthropic.claude-3-7-sonnet-20250219-v1:0}"
    AWS_REGION="${AWS_REGION:-us-east-1}"
    return 0
  fi
  return 1
}

prompt_llm_credentials() {
  local choice provider

  echo ""
  echo "LLM credentials are required for X2Ansible conversion."
  echo "See: https://x2ansible.github.io/getting-started/usage.html"
  echo ""
  echo "Choose LLM provider:"
  echo "  1) AWS Bedrock — region + API key (bearer token) [recommended]"
  echo "  2) OpenAI-compatible — API endpoint + API key"
  echo "  3) AWS Bedrock — IAM access key + secret key"
  echo ""
  choice=$(prompt_with_default "Provider" "1")

  case "$choice" in
    2 | openai | OpenAI)
      provider="openai"
      ;;
    3 | iam | IAM)
      provider="bedrock-iam"
      ;;
    *)
      provider="bedrock"
      ;;
  esac

  case "$provider" in
    bedrock)
      LLM_PROVIDER="bedrock"
      AWS_REGION=$(prompt_with_default "AWS region" "us-east-1")
      LLM_MODEL=$(prompt_with_default "LLM model" "anthropic.claude-3-7-sonnet-20250219-v1:0")
      AWS_BEARER_TOKEN_BEDROCK=$(prompt_secret "AWS Bedrock API key (bearer token)")
      if [ -z "$AWS_BEARER_TOKEN_BEDROCK" ]; then
        die "AWS Bedrock API key is required."
      fi
      ;;
    openai)
      LLM_PROVIDER="openai"
      OPENAI_API_BASE=$(prompt_with_default "API endpoint (OPENAI_API_BASE)" "https://api.openai.com/v1")
      LLM_MODEL=$(prompt_with_default "LLM model" "gpt-4o")
      OPENAI_API_KEY=$(prompt_secret "API key (OPENAI_API_KEY)")
      if [ -z "$OPENAI_API_KEY" ]; then
        die "API key is required."
      fi
      ;;
    bedrock-iam)
      LLM_PROVIDER="bedrock-iam"
      AWS_REGION=$(prompt_with_default "AWS region" "us-east-1")
      LLM_MODEL=$(prompt_with_default "LLM model" "anthropic.claude-3-7-sonnet-20250219-v1:0")
      AWS_ACCESS_KEY_ID=$(prompt_secret "AWS access key ID")
      AWS_SECRET_ACCESS_KEY=$(prompt_secret "AWS secret access key")
      if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        die "AWS access key ID and secret access key are required."
      fi
      ;;
  esac
}

load_llm_from_secrets_file() {
  LLM_MODEL=$(secret_field_value "LLM_MODEL")
  AWS_REGION=$(secret_field_value "AWS_REGION")
  AWS_BEARER_TOKEN_BEDROCK=$(secret_field_value "AWS_BEARER_TOKEN_BEDROCK")
  AWS_ACCESS_KEY_ID=$(secret_field_value "AWS_ACCESS_KEY_ID")
  AWS_SECRET_ACCESS_KEY=$(secret_field_value "AWS_SECRET_ACCESS_KEY")
  OPENAI_API_BASE=$(secret_field_value "OPENAI_API_BASE")
  OPENAI_API_KEY=$(secret_field_value "OPENAI_API_KEY")

  if [ -n "$AWS_BEARER_TOKEN_BEDROCK" ] && [ "$AWS_BEARER_TOKEN_BEDROCK" != "REPLACE-WITH-YOUR-AWS-BEARER-TOKEN" ]; then
    LLM_PROVIDER="bedrock"
  elif [ -n "$OPENAI_API_KEY" ] && [ "$OPENAI_API_KEY" != "REPLACE-WITH-YOUR-OPENAI-API-KEY" ]; then
    LLM_PROVIDER="openai"
  elif [ -n "$AWS_ACCESS_KEY_ID" ] && [ "$AWS_ACCESS_KEY_ID" != "REPLACE-WITH-YOUR-AWS-ACCESS-KEY" ]; then
    LLM_PROVIDER="bedrock-iam"
  else
    return 1
  fi
}

build_secret_fields() {
  discover_aap_config

  local aap_url="https://your-aap-instance.com"
  local aap_token="REPLACE-WITH-YOUR-AAP-TOKEN"
  if [ -n "${AAP_ROUTE:-}" ]; then
    aap_url="https://${AAP_ROUTE}"
  fi
  if [ -n "${AAP_OAUTH_TOKEN:-}" ]; then
    aap_token="$AAP_OAUTH_TOKEN"
  fi

  SECRET_FIELDS=(
    "LLM_MODEL=${LLM_MODEL}"
    "AAP_URL=${aap_url}"
    "AAP_ORG_NAME=${X2ANSIBLE_AAP_ORG_NAME:-Default}"
    "AAP_OAUTH_TOKEN=${aap_token}"
    "AAP_SKIP_SSL_VERIFICATION=${X2ANSIBLE_AAP_SKIP_SSL_VERIFICATION:-true}"
  )

  case "${LLM_PROVIDER}" in
    bedrock)
      SECRET_FIELDS+=(
        "AWS_REGION=${AWS_REGION}"
        "AWS_BEARER_TOKEN_BEDROCK=${AWS_BEARER_TOKEN_BEDROCK}"
      )
      ;;
    bedrock-iam)
      SECRET_FIELDS+=(
        "AWS_REGION=${AWS_REGION}"
        "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"
        "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}"
      )
      ;;
    openai)
      SECRET_FIELDS+=(
        "OPENAI_API_BASE=${OPENAI_API_BASE}"
        "OPENAI_API_KEY=${OPENAI_API_KEY}"
      )
      ;;
  esac
}

write_secrets_file() {
  build_secret_fields
  mkdir -p "$(dirname "$SECRETS_FILE")"
  chmod 700 "$(dirname "$SECRETS_FILE")"

  python3 - "$SECRETS_FILE" "${SECRET_FIELDS[@]}" <<'PY'
import json, os, sys

path = sys.argv[1]
pairs = [p.split("=", 1) for p in sys.argv[2:] if "=" in p]
fields = {k: v for k, v in pairs}

lines = [
    "---",
    "kind: Secret",
    "apiVersion: v1",
    "metadata:",
    "  name: x2a-credentials",
    "type: Opaque",
    "stringData:",
]
for key, value in fields.items():
    lines.append(f"  {key}: {json.dumps(value)}")

content = "\n".join(lines) + "\n"
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, content.encode("utf-8"))
os.close(fd)
PY

  info "Wrote credentials to $SECRETS_FILE"
}

configure_secrets_file() {
  if [ "$FORCE_RECONFIGURE" = true ]; then
    rm -f "$SECRETS_FILE"
  elif [ -f "$SECRETS_FILE" ] && secrets_llm_is_configured; then
    load_llm_from_secrets_file || die "Could not read LLM credentials from $SECRETS_FILE"
    write_secrets_file
    info "Using existing LLM credentials; refreshed AAP integration from cluster"
    return 0
  fi

  if llm_from_environment; then
    info "Using LLM credentials from environment variables"
    write_secrets_file
    return 0
  fi

  if is_interactive; then
    prompt_llm_credentials
    write_secrets_file
    return 0
  fi

  cat <<EOF >&2

ERROR: LLM credentials are not configured.

Interactive mode (recommended):
  aap-demo enable x2ansible

Non-interactive — set environment variables, then re-run:
  # AWS Bedrock (matches x2ansible docs)
  export AWS_REGION=us-east-1
  export AWS_BEARER_TOKEN_BEDROCK=your-bearer-token
  export LLM_MODEL=anthropic.claude-3-7-sonnet-20250219-v1:0

  # Or OpenAI-compatible endpoint + API key
  export OPENAI_API_BASE=https://api.openai.com/v1
  export OPENAI_API_KEY=your-api-key
  export LLM_MODEL=gpt-4o

  aap-demo enable x2ansible

Or edit $SECRETS_FILE manually (see addons/x2ansible/README.md).

EOF
  exit 1
}

apply_secrets() {
  if ! secrets_llm_is_configured; then
    die "LLM credentials are not configured in $SECRETS_FILE"
  fi

  if [ -z "${LLM_PROVIDER:-}" ]; then
    load_llm_from_secrets_file || die "Could not read LLM credentials from $SECRETS_FILE"
  fi

  build_secret_fields
  local -a kubectl_args=(kubectl create secret generic x2a-credentials -n "$NAMESPACE")
  local pair key value
  for pair in "${SECRET_FIELDS[@]}"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    kubectl_args+=(--from-literal="${key}=${value}")
  done
  "${kubectl_args[@]}" --dry-run=client -o yaml | kubectl apply -f -
}

restart_backstage() {
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    return 0
  fi
  kubectl delete pod -n "$NAMESPACE" -l app.kubernetes.io/name=developer-hub --ignore-not-found=true 2>/dev/null || true
  info "Restarted Backstage pod to load new configuration"
}

wait_for_backstage() {
  info "Waiting for Developer Hub / Backstage to become ready..."
  local i phase route_host
  for i in $(seq 1 60); do
    phase=$(kubectl get backstage developer-hub -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Deployed")].status}' 2>/dev/null || true)
    route_host=$(kubectl get route developer-hub -n "$NAMESPACE" \
      -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ "$phase" = "True" ] && [ -n "$route_host" ]; then
      echo ""
      return 0
    fi
    printf "\r  Waiting for Backstage... (%s/60)" "$i"
    sleep 15
  done
  echo ""
  warn "Backstage may still be starting. Check: kubectl get backstage,pods,route -n $NAMESPACE"
}

show_access_info() {
  local route_host
  route_host=$(kubectl get route developer-hub -n "$NAMESPACE" \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)

  info ""
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "X2Ansible deployed!"
  info ""
  if [ -n "$route_host" ]; then
    info "Developer Hub URL: https://${route_host}"
    info "Conversion Hub:    https://${route_host}/x2a"
  else
    info "Route not ready yet. Check: kubectl get route developer-hub -n $NAMESPACE"
  fi
  info ""
  info "Secrets file: $SECRETS_FILE"
  info "Update LLM credentials: aap-demo config x2ansible"
  info ""
  info "Verify:"
  info "  kubectl get backstage -n $NAMESPACE"
  info "  kubectl get pods -n $NAMESPACE"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ---------------------------------------------------------------------------
# Deploy / delete
# ---------------------------------------------------------------------------

deploy() {
  if ! kubectl cluster-info &>/dev/null; then
    die "kubectl not connected to a cluster. Run 'aap-demo create' first."
  fi

  if ! kubectl get crd subscriptions.operators.coreos.com &>/dev/null; then
    die "OLM not installed. Run 'aap-demo deploy' first."
  fi

  # Collect LLM credentials before installing operators (fail fast, better UX)
  configure_secrets_file

  local arch
  arch=$(detect_cluster_arch)
  if [[ "$arch" == "arm64" ]] || [[ "$arch" == "aarch64" ]]; then
    warn "ARM64 cluster detected. RHDH operator images are x86_64-only."
    warn "X2Ansible via RHDH operator may not work on ARM — use an x86_64 cluster for full support."
    if [ "${X2ANSIBLE_FORCE_ARM:-}" != "true" ]; then
      die "Set X2ANSIBLE_FORCE_ARM=true to attempt deployment anyway."
    fi
  fi

  if ! operator_is_installed; then
    install_rhdh_operator
  else
    info "RHDH operator already installed"
  fi

  setup_namespace
  apply_app_manifests
  link_pull_secret_to_serviceaccount "$NAMESPACE" "x2a-sa"
  apply_secrets
  restart_backstage
  wait_for_backstage
  show_access_info
}

cleanup() {
  info "Removing X2Ansible from namespace $NAMESPACE..."

  kubectl delete backstage developer-hub -n "$NAMESPACE" --ignore-not-found=true --timeout=120s 2>/dev/null || true
  kubectl delete configmap dynamic-plugins app-config-rhdh -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  kubectl delete pvc dynamic-plugins-root -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  kubectl delete secret x2a-credentials -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  kubectl delete sa,role,rolebinding -l app.kubernetes.io/part-of=backstage -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  kubectl delete sa x2a-sa role x2a-role rolebinding x2a-rolebinding -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  kubectl delete clusterrolebinding x2a-cluster-rolebinding --ignore-not-found=true 2>/dev/null || true
  kubectl delete clusterrole x2a-cluster-role --ignore-not-found=true 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --timeout=120s 2>/dev/null || true

  info "X2Ansible application removed (RHDH operator left installed — cluster-scoped)"
  info "To remove secrets file: rm -f $SECRETS_FILE"
}

case "$ACTION" in
  deploy | --deploy)
    deploy
    ;;
  --reconfigure)
    FORCE_RECONFIGURE=true
    configure_secrets_file
    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
      apply_secrets
      restart_backstage
    else
      info "Namespace $NAMESPACE not found — run './deploy.sh' to deploy."
    fi
    ;;
  --delete | delete | remove)
    cleanup
    ;;
  *)
    echo "Usage: $0 [deploy|--reconfigure|--delete]"
    echo "  deploy         - Install X2Ansible (RHDH operator + X2A plugins)"
    echo "  --reconfigure  - Re-prompt for LLM credentials and update the cluster secret"
    echo "  --delete       - Remove X2Ansible application resources"
    exit 1
    ;;
esac
