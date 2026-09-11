# Ollama Addon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `ollama` addon that deploys Ollama with phi4-mini on MicroShift and wires it into Automation Orchestrator as an `llm_provider` integration.

**Architecture:** A self-contained addon directory (`addons/ollama/`) containing a YAML manifest and deploy script, following the exact same pattern as `addons/registry/`. Two existing files are extended: `includes/addon-wire.sh` gets Ollama-aware helpers and is updated to wire the integration when AO is present; `aap-demo.sh` registers the addon name.

**Tech Stack:** Bash, kubectl, curl, `ollama/ollama` container image, OpenShift Routes, MicroShift/CRC.

**Spec:** `docs/superpowers/specs/2026-09-11-ollama-addon-design.md`

## Global Constraints

- Target cluster: MicroShift on CRC — no GPU, CPU-only Ollama inference
- Default model: `phi4-mini` (pulled at deploy time, ~2.5GB)
- Namespace: `aap-demo-ollama`
- PVC storage class: `topolvm-provisioner` (RWO), 20Gi
- Ollama port: 11434; OpenAI-compatible base at `/v1`
- AO integration type: `llm_provider`, `provider_hint: "custom"`
- AO credential type: "LLM Provider", `api_key: "ollama"` (placeholder — Ollama has no auth)
- Route hostname pattern: `ollama.<cluster-apps-domain>` (same domain as AAP route)
- No new shell libraries — use existing `addon-wire.sh` helpers only
- All shell scripts: `set -e`, POSIX-compatible bash, shellcheck-clean
- Follow exact indentation and style of surrounding code when modifying existing files

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `addons/ollama/ollama.yaml` | All k8s resources for the Ollama deployment |
| Create | `addons/ollama/deploy.sh` | Deploy and delete actions |
| Modify | `includes/addon-wire.sh` | Add `wire_ollama_*` helpers, update allowed-hosts list, update `aap_demo_wire` |
| Modify | `aap-demo.sh` | Add `ollama` to `AVAILABLE_ADDONS` and help text |

---

## Task 1: Kubernetes manifests

**Files:**
- Create: `addons/ollama/ollama.yaml`

**Interfaces:**
- Produces: namespace `aap-demo-ollama`, deployment `ollama`, service `ollama` (port 11434), route `ollama` (spec.host = `ollama.<apps-domain>`)

- [ ] **Step 1: Create `addons/ollama/ollama.yaml`**

```yaml
# Ollama LLM server for aap-demo
# CPU-only deployment with phi4-mini model (~2.5GB)
#
# Endpoint: https://ollama.apps.127.0.0.1.nip.io
# OpenAI-compatible: https://ollama.apps.127.0.0.1.nip.io/v1
---
apiVersion: v1
kind: Namespace
metadata:
  name: aap-demo-ollama
  labels:
    app: aap-demo-ollama
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ollama
  namespace: aap-demo-ollama
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aap-demo-ollama-anyuid
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:anyuid
subjects:
  - kind: ServiceAccount
    name: ollama
    namespace: aap-demo-ollama
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-data
  namespace: aap-demo-ollama
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: topolvm-provisioner
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: aap-demo-ollama
  labels:
    app: ollama
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      serviceAccountName: ollama
      containers:
        - name: ollama
          image: docker.io/ollama/ollama:latest
          ports:
            - containerPort: 11434
              name: http
          env:
            - name: OLLAMA_HOST
              value: "0.0.0.0:11434"
          volumeMounts:
            - name: data
              mountPath: /root/.ollama
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
            limits:
              cpu: "4"
              memory: 8Gi
          readinessProbe:
            httpGet:
              path: /api/tags
              port: 11434
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /api/tags
              port: 11434
            initialDelaySeconds: 30
            periodSeconds: 30
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ollama-data
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: aap-demo-ollama
  labels:
    app: ollama
spec:
  selector:
    app: ollama
  ports:
    - port: 11434
      targetPort: 11434
      name: http
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ollama
  namespace: aap-demo-ollama
  labels:
    app: ollama
spec:
  host: ollama.apps.127.0.0.1.nip.io
  to:
    kind: Service
    name: ollama
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

- [ ] **Step 2: Apply manifest and verify resources are created**

```bash
kubectl apply -f addons/ollama/ollama.yaml
kubectl get ns aap-demo-ollama
kubectl get deployment,svc,route,pvc -n aap-demo-ollama
```

Expected: namespace, deployment (0/1 ready initially), service, route, and PVC all listed.

- [ ] **Step 3: Wait for deployment to be ready**

```bash
kubectl rollout status deployment/ollama -n aap-demo-ollama --timeout=120s
```

Expected: `deployment "ollama" successfully rolled out`

- [ ] **Step 4: Verify readiness probe via in-cluster service**

```bash
OLLAMA_SVC_IP=$(kubectl get svc ollama -n aap-demo-ollama -o jsonpath='{.spec.clusterIP}')
curl -s "http://${OLLAMA_SVC_IP}:11434/api/tags"
```

Expected: `{"models":[]}` (no models pulled yet — that's fine)

- [ ] **Step 5: Commit**

```bash
git add addons/ollama/ollama.yaml
git commit -m "feat(ollama): add Kubernetes manifests for Ollama deployment"
```

---

## Task 2: deploy.sh — deploy action

**Files:**
- Create: `addons/ollama/deploy.sh`

**Interfaces:**
- Consumes: `addons/ollama/ollama.yaml`, `includes/infra-crc.sh` (optional, sourced with `|| true`), `includes/addon-wire.sh`
- Produces: running Ollama with phi4-mini pulled; prints route URL and OpenAI-compatible base URL

- [ ] **Step 1: Create `addons/ollama/deploy.sh`**

```bash
#!/usr/bin/env bash
# Deploy Ollama LLM server for aap-demo
#
# Deploys Ollama (CPU-only) with phi4-mini model pre-pulled.
# Accessible via:
#   - Route: https://ollama.apps.<cluster-domain>
#   - OpenAI-compatible: https://ollama.apps.<cluster-domain>/v1
#   - In-cluster: http://ollama.aap-demo-ollama.svc.cluster.local:11434
#
# Usage:
#   ./deploy.sh          # Deploy Ollama and pull phi4-mini
#   ./deploy.sh --delete # Remove Ollama

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_MODEL="${OLLAMA_MODEL:-phi4-mini}"

# shellcheck source=../../includes/infra-crc.sh
source "${SCRIPT_DIR}/../../includes/infra-crc.sh" 2>/dev/null || true

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing Ollama..."
  kubectl delete namespace aap-demo-ollama 2>/dev/null || true
  kubectl delete clusterrolebinding aap-demo-ollama-anyuid 2>/dev/null || true
  echo "✓ Ollama removed"
  exit 0
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl not connected to cluster"
  exit 1
fi

echo "Deploying Ollama (CPU-only)..."

# Detect cluster apps domain from existing AAP route, fall back to nip.io default
_aap_host=$(kubectl get route aap -n "${NAMESPACE:-aap-operator}" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -n "$_aap_host" ]; then
  CLUSTER_DOMAIN="${_aap_host#*.}"
else
  CLUSTER_DOMAIN="apps.127.0.0.1.nip.io"
fi
OLLAMA_ROUTE="ollama.${CLUSTER_DOMAIN}"

# Patch the route hostname if cluster domain differs from the nip.io default in the manifest
sed "s|host: ollama\.apps\.127\.0\.0\.1\.nip\.io|host: ${OLLAMA_ROUTE}|" \
  "${SCRIPT_DIR}/ollama.yaml" | kubectl apply -f -

echo "  Waiting for Ollama deployment to be ready..."
kubectl rollout status deployment/ollama -n aap-demo-ollama --timeout=120s

# Pull model via in-cluster ClusterIP (avoids nip.io resolution issues in scripts)
OLLAMA_SVC_IP=$(kubectl get svc ollama -n aap-demo-ollama \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

if [ -n "$OLLAMA_SVC_IP" ]; then
  echo "  Pulling model: ${OLLAMA_MODEL}..."
  echo "  (This may take several minutes — model is ~2.5GB)"

  _pull_done=false
  for _i in $(seq 1 60); do
    _resp=$(curl -s --max-time 10 -X POST \
      "http://${OLLAMA_SVC_IP}:11434/api/pull" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${OLLAMA_MODEL}\",\"stream\":false}" 2>/dev/null || true)
    if echo "$_resp" | grep -q '"status":"success"'; then
      _pull_done=true
      echo "  ✓ Model ${OLLAMA_MODEL} ready"
      break
    elif echo "$_resp" | grep -q '"error"'; then
      echo "  ⚠ Pull error: $(echo "$_resp" | grep -o '"error":"[^"]*"' | head -1)"
      break
    fi
    printf "."
    sleep 5
  done
  echo ""
  if [ "$_pull_done" = false ]; then
    echo "  ⚠ Model pull did not complete within 5 minutes"
    echo "  Pull manually: curl -X POST http://${OLLAMA_SVC_IP}:11434/api/pull"
    echo "    -d '{\"name\":\"${OLLAMA_MODEL}\",\"stream\":false}'"
  fi
else
  echo "  ⚠ Could not determine service ClusterIP — skipping model pull"
  echo "  Pull manually after deploy: aap-demo enable ollama  (re-run is safe)"
fi

echo ""
echo "✓ Ollama deployed!"
echo ""
echo "  Route:         https://${OLLAMA_ROUTE}"
echo "  OpenAI base:   https://${OLLAMA_ROUTE}/v1"
echo "  In-cluster:    http://ollama.aap-demo-ollama.svc.cluster.local:11434"
echo "  Model:         ${OLLAMA_MODEL}"
echo ""
echo "  Test inference:"
echo "    curl https://${OLLAMA_ROUTE}/api/generate \\"
echo "      -d '{\"model\":\"${OLLAMA_MODEL}\",\"prompt\":\"Hello\",\"stream\":false}'"
echo ""
echo "  List models:   curl https://${OLLAMA_ROUTE}/api/tags"
echo ""
echo "  Pull additional model:"
echo "    OLLAMA_MODEL=mistral:7b aap-demo enable ollama"
echo ""

# Wire into AO if present
if [ "${AAP_DEMO_WIRE_AFTER_DEPLOY:-0}" != "0" ]; then
  # shellcheck source=../../includes/addon-wire.sh
  source "${SCRIPT_DIR}/../../includes/addon-wire.sh"
  aap_demo_wire || true
fi
```

- [ ] **Step 2: Make executable and do a dry-run syntax check**

```bash
chmod +x addons/ollama/deploy.sh
bash -n addons/ollama/deploy.sh
```

Expected: no output (syntax OK)

- [ ] **Step 3: Run deploy and verify end-to-end**

```bash
./addons/ollama/deploy.sh
```

Expected:
- "✓ Ollama deployed!" printed
- "✓ Model phi4-mini ready" printed (or pull-in-progress dots for a few minutes)

- [ ] **Step 4: Verify model is available**

```bash
OLLAMA_SVC_IP=$(kubectl get svc ollama -n aap-demo-ollama -o jsonpath='{.spec.clusterIP}')
curl -s "http://${OLLAMA_SVC_IP}:11434/api/tags" | python3 -m json.tool
```

Expected: JSON with `"models"` list containing `phi4-mini`

- [ ] **Step 5: Verify route is reachable**

```bash
curl -sk "https://ollama.apps.127.0.0.1.nip.io/api/tags"
```

Expected: same model list JSON

- [ ] **Step 6: Commit**

```bash
git add addons/ollama/deploy.sh
git commit -m "feat(ollama): add deploy.sh with model pull and route detection"
```

---

## Task 3: deploy.sh — delete action verification

**Files:**
- Modify: `addons/ollama/deploy.sh` (already written — just verify the delete path)

**Interfaces:**
- Consumes: running `aap-demo-ollama` namespace
- Produces: namespace and ClusterRoleBinding deleted

- [ ] **Step 1: Run delete and verify removal**

```bash
./addons/ollama/deploy.sh --delete
kubectl get namespace aap-demo-ollama 2>/dev/null && echo "STILL EXISTS" || echo "Removed OK"
kubectl get clusterrolebinding aap-demo-ollama-anyuid 2>/dev/null && echo "STILL EXISTS" || echo "Removed OK"
```

Expected: both print "Removed OK"

- [ ] **Step 2: Redeploy to restore the addon for subsequent tasks**

```bash
./addons/ollama/deploy.sh
```

Expected: clean redeploy, "✓ Ollama deployed!" with phi4-mini pulled again (it will pull from Ollama registry since the PVC was deleted with the namespace)

- [ ] **Step 3: Commit (no code changes, this was verification only)**

No commit needed — Task 2 commit covered the delete implementation.

---

## Task 4: AO wiring helpers in addon-wire.sh

**Files:**
- Modify: `includes/addon-wire.sh`

**Interfaces:**
- Consumes: `wire_ao_deployed`, `wire_ao_ensure_credential`, `wire_ao_ensure_integration` (all already defined in `addon-wire.sh`)
- Produces:
  - `wire_ollama_deployed()` → 0/1 exit code
  - `wire_ollama_route_host()` → prints hostname string
  - `wire_ollama_url_for_ao()` → prints `https://<host>/v1`
  - `wire_ao_ollama()` → creates AO credential + integration for Ollama
  - Updated `wire_ao_integration_allowed_hosts_json` — emits Ollama route host
  - Updated `aap_demo_wire` — calls `wire_ao_ollama`

- [ ] **Step 1: Add Ollama detection helpers to `addon-wire.sh`**

Find the block containing `wire_mcp_deployed()` (around line 77). Add the following block immediately after `wire_mcp_deployed()` and its related helpers. Use the same style — one blank line between functions, no extra comments beyond the function name.

```bash
wire_ollama_deployed() {
  kubectl get deployment ollama -n aap-demo-ollama &>/dev/null 2>&1
}

wire_ollama_route_host() {
  kubectl get route ollama -n aap-demo-ollama \
    -o jsonpath='{.spec.host}' 2>/dev/null
}

wire_ollama_url_for_ao() {
  local route
  route=$(wire_ollama_route_host)
  [ -n "$route" ] && printf 'https://%s/v1\n' "$route"
}
```

- [ ] **Step 2: Verify new helpers work against the live cluster**

```bash
source includes/addon-wire.sh
wire_ollama_deployed && echo "deployed" || echo "not deployed"
wire_ollama_route_host
wire_ollama_url_for_ao
```

Expected:
```
deployed
ollama.apps.127.0.0.1.nip.io
https://ollama.apps.127.0.0.1.nip.io/v1
```

- [ ] **Step 3: Add Ollama route to `wire_ao_integration_allowed_hosts_json`**

Locate the `wire_ao_integration_allowed_hosts_json()` function in `addon-wire.sh`. It currently ends with:

```bash
    h=$(wire_mcp_route_host) && [ -n "$h" ] && printf '%s\n' "$h"
  } | awk 'NF && !seen[$0]++' | jq -R . | jq -s -c .
```

Add the Ollama line **before** the closing `}`:

```bash
    h=$(wire_mcp_route_host) && [ -n "$h" ] && printf '%s\n' "$h"
    h=$(wire_ollama_route_host) && [ -n "$h" ] && printf '%s\n' "$h"
  } | awk 'NF && !seen[$0]++' | jq -R . | jq -s -c .
```

- [ ] **Step 4: Add `wire_ao_ollama()` function**

Add this function immediately after `wire_ao_mcp()` (around line 762), before `aap_demo_wire()`:

```bash
wire_ao_ollama() {
  local ollama_url cred_id

  if ! wire_ollama_deployed || ! wire_ao_deployed; then
    return 0
  fi

  ollama_url=$(wire_ollama_url_for_ao)
  if [ -z "$ollama_url" ]; then
    wire_warn "Could not determine Ollama route URL for AO integration"
    return 1
  fi

  wire_log "Wiring Automation Orchestrator → Ollama LLM provider..."

  cred_id=$(wire_ao_ensure_credential \
    "aap-demo Ollama" \
    "LLM Provider" \
    "$(jq -n '{api_key: "ollama"}')" \
  ) || return 1

  wire_ao_ensure_integration "aap-demo Ollama" \
    "llm_provider" "$ollama_url" "$cred_id" false \
    "custom" || return 1
}
```

**Note:** `wire_ao_ensure_integration` takes 5 positional arguments as currently defined. Check the existing signature at `wire_ao_ensure_integration()` in `addon-wire.sh` — it is:

```bash
wire_ao_ensure_integration() {
  local name="$1"
  local integration_type="$2"
  local base_url="$3"
  local credential_id="$4"
  local discover_tools="${5:-false}"
```

The `provider_hint` is part of the integration configuration, not a positional parameter to `wire_ao_ensure_integration`. We need to override the configuration payload for `llm_provider` integrations. The existing `wire_ao_integration_config_json` produces the config body. For `llm_provider`, AO requires an additional `provider_hint` field. Patch this by overriding `wire_ao_integration_config_json` output inline in `wire_ao_ollama`:

```bash
wire_ao_ollama() {
  local ollama_url cred_id config_json

  if ! wire_ollama_deployed || ! wire_ao_deployed; then
    return 0
  fi

  ollama_url=$(wire_ollama_url_for_ao)
  if [ -z "$ollama_url" ]; then
    wire_warn "Could not determine Ollama route URL for AO integration"
    return 1
  fi

  wire_log "Wiring Automation Orchestrator → Ollama LLM provider..."

  cred_id=$(wire_ao_ensure_credential \
    "aap-demo Ollama" \
    "LLM Provider" \
    "$(jq -n '{api_key: "ollama"}')" \
  ) || return 1

  # llm_provider requires provider_hint — build config directly instead of
  # using wire_ao_integration_config_json which doesn't know about this field.
  config_json=$(jq -n \
    --arg url "$ollama_url" \
    '{
      integration_type: "llm_provider",
      provider_hint: "custom",
      base_url: $url,
      allow_http: true,
      insecure_skip_tls_verify: true
    }')

  local name="aap-demo Ollama"
  local integration_id
  integration_id=$(wire_ao_find_integration_by_name "$name")

  if [ -n "$integration_id" ]; then
    wire_log "  Updating existing Ollama integration..."
    wire_ao_api PATCH "/integrations/${integration_id}" \
      "$(jq -n \
          --arg name "$name" \
          --argjson config "$config_json" \
          --arg cred "$cred_id" \
          '{name: $name, configuration: $config, management_credential_id: $cred}'
      )" >/dev/null 2>&1 || true
  else
    wire_log "  Creating Ollama integration..."
    wire_ao_api POST "/integrations" \
      "$(jq -n \
          --arg name "$name" \
          --argjson config "$config_json" \
          --arg cred "$cred_id" \
          '{name: $name, integration_type: "llm_provider", configuration: $config, management_credential_id: $cred}'
      )" >/dev/null 2>&1 || true
  fi

  wire_log "  ✓ Ollama wired as LLM provider"
}
```

- [ ] **Step 5: Add `wire_ao_ollama` call in `aap_demo_wire()`**

Locate the `aap_demo_wire()` function. It currently ends with:

```bash
  if wire_ao_deployed; then
    wire_ao_wait_for_route || return 1
    wire_ao_aap || return 1
    wire_ao_mcp || return 1
  fi
```

Add the Ollama call on a new line after `wire_ao_mcp`:

```bash
  if wire_ao_deployed; then
    wire_ao_wait_for_route || return 1
    wire_ao_aap || return 1
    wire_ao_mcp || return 1
    wire_ao_ollama || wire_warn "Ollama AO wiring skipped"
  fi
```

- [ ] **Step 6: Verify syntax**

```bash
bash -n includes/addon-wire.sh
```

Expected: no output

- [ ] **Step 7: Run wiring and verify integration appears in AO**

```bash
bash -c 'source includes/addon-wire.sh && aap_demo_wire'
```

Expected output includes:
```
Wiring Automation Orchestrator → Ollama LLM provider...
  ✓ Ollama wired as LLM provider
```

Then verify in AO API:

```bash
AO_ROUTE=$(kubectl get route -n automation-orchestrator -o jsonpath='{.items[0].spec.host}')
AO_PASS=$(kubectl get secret automation-orchestrator-initial-admin-password \
  -n automation-orchestrator -o jsonpath='{.data.password}' | base64 -d)
TOKEN=$(curl -sk -X POST "https://${AO_ROUTE}/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"${AO_PASS}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
curl -sk "https://${AO_ROUTE}/api/v1/integrations?limit=100" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for x in d.get('resources', []):
    if 'Ollama' in x.get('name', ''):
        print('Found:', x['name'], '|', x['integration_type'], '|', x['validation_status'])
"
```

Expected: `Found: aap-demo Ollama | llm_provider | available`

- [ ] **Step 8: Commit**

```bash
git add includes/addon-wire.sh
git commit -m "feat(ollama): add AO wiring helpers and llm_provider integration"
```

---

## Task 5: Register addon in aap-demo.sh

**Files:**
- Modify: `aap-demo.sh`

**Interfaces:**
- Produces: `ollama` recognized by `aap-demo enable`, `aap-demo disable`, `aap-demo status`

- [ ] **Step 1: Add `ollama` to `AVAILABLE_ADDONS`**

Locate line 2671 in `aap-demo.sh`:

```bash
AVAILABLE_ADDONS="mcp-server portal setup-pah ao apme-eap local-cache product-demos product-demo-satellite"
```

Change to:

```bash
AVAILABLE_ADDONS="mcp-server portal setup-pah ao apme-eap local-cache product-demos product-demo-satellite ollama"
```

- [ ] **Step 2: Add help text entry**

Locate the short help block (around line 408–413) that reads:

```
  enable mcp-server Enable MCP server for AI assistants (required by ao)
  enable setup-pah Configure Private Automation Hub remotes and credentials
  enable ao       Install Automation Orchestrator (enables mcp-server automatically)
  enable local-cache Cache container images locally (~30GB) to speed up deploys
```

Add one line after `enable local-cache`:

```
  enable ollama   Deploy Ollama LLM server with phi4-mini (wires into AO as llm_provider)
```

- [ ] **Step 3: Add full help text entry**

Locate the full help block (around line 458–462):

```
    enable [addon]  Enable an addon (mcp-server, portal, setup-pah, local-cache)
    disable [addon] Disable an addon
```

Update the addon list in the description:

```
    enable [addon]  Enable an addon (mcp-server, portal, setup-pah, ao, local-cache, ollama)
    disable [addon] Disable an addon
```

- [ ] **Step 4: Verify syntax**

```bash
bash -n aap-demo.sh
```

Expected: no output

- [ ] **Step 5: Verify addon is listed**

```bash
./aap-demo.sh enable
```

Expected: `ollama` appears in the available addon list with status `(enabled)` (since it was deployed in Task 2).

- [ ] **Step 6: Test full enable/disable round-trip**

```bash
# Disable first (removes namespace)
./aap-demo.sh disable ollama
kubectl get namespace aap-demo-ollama 2>/dev/null && echo "STILL EXISTS" || echo "OK"

# Re-enable
./aap-demo.sh enable ollama
kubectl get deployment ollama -n aap-demo-ollama
```

Expected: namespace gone after disable; deployment running after re-enable.

- [ ] **Step 7: Final end-to-end AO integration check**

```bash
# After enable, AO wiring runs automatically (AAP_DEMO_WIRE_AFTER_DEPLOY=0 for non-ao addons,
# so wiring runs via _aap_demo_run_addon_wire false from cmd_enable)
# Check AO has the integration
AO_ROUTE=$(kubectl get route -n automation-orchestrator -o jsonpath='{.items[0].spec.host}')
AO_PASS=$(kubectl get secret automation-orchestrator-initial-admin-password \
  -n automation-orchestrator -o jsonpath='{.data.password}' | base64 -d)
TOKEN=$(curl -sk -X POST "https://${AO_ROUTE}/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"${AO_PASS}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
curl -sk "https://${AO_ROUTE}/api/v1/integrations?limit=100" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for x in d.get('resources', []):
    print(x['name'], '|', x['integration_type'], '|', x['validation_status'])
"
```

Expected output includes: `aap-demo Ollama | llm_provider | available`

- [ ] **Step 8: Commit**

```bash
git add aap-demo.sh
git commit -m "feat(ollama): register ollama addon in AVAILABLE_ADDONS and help text"
```

---

## Task 6: README

**Files:**
- Create: `addons/ollama/README.md`

**Interfaces:** None (documentation only)

- [ ] **Step 1: Create `addons/ollama/README.md`**

```markdown
# Ollama Addon

Deploys [Ollama](https://ollama.com/) (CPU-only) to a dedicated `aap-demo-ollama` namespace,
pre-pulls the `phi4-mini` model, and wires it into Automation Orchestrator as an
`llm_provider` integration.

## Usage

```bash
aap-demo enable ollama     # Deploy Ollama + pull phi4-mini + wire into AO
aap-demo disable ollama    # Remove Ollama (AO integration becomes invalid)
```

The addon automatically:

1. Deploys the `ollama/ollama` container with a 20Gi PVC for model storage
2. Pulls `phi4-mini` (~2.5GB) from the Ollama registry at deploy time
3. Wires Ollama into Automation Orchestrator as an `llm_provider` integration
   (named `aap-demo Ollama`) using the OpenAI-compatible `/v1` endpoint

## Endpoints

| Access | URL |
|--------|-----|
| Route | `https://ollama.apps.<cluster-domain>` |
| OpenAI-compatible | `https://ollama.apps.<cluster-domain>/v1` |
| In-cluster | `http://ollama.aap-demo-ollama.svc.cluster.local:11434` |

## Test inference

```bash
curl -sk https://ollama.apps.127.0.0.1.nip.io/api/generate \
  -d '{"model":"phi4-mini","prompt":"Hello","stream":false}'
```

## Pull additional models

```bash
OLLAMA_MODEL=mistral:7b aap-demo enable ollama
```

Re-running `aap-demo enable ollama` with a different `OLLAMA_MODEL` is safe — it is idempotent.

## Resource usage

- **CPU**: requests 1 core, limit 4 cores (CPU-only inference — no GPU in MicroShift VMs)
- **Memory**: requests 2Gi, limit 8Gi
- **Storage**: 20Gi RWO PVC on `topolvm-provisioner`

## Status

```bash
kubectl get deployment,pvc -n aap-demo-ollama
kubectl logs -n aap-demo-ollama -l app=ollama --tail=20
```
```

- [ ] **Step 2: Commit**

```bash
git add addons/ollama/README.md
git commit -m "docs(ollama): add README for ollama addon"
```
