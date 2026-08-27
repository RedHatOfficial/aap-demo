# Addon verification checks

Run after `aap-demo enable <addon>` on each host. All commands assume default namespace
`aap-operator` unless noted. Use `oc` interchangeably with `kubectl`.

Pass criteria: command succeeds (exit 0) and output shows expected resources.

---

## setup-pah

Requires `~/.aap-demo/galaxy-token` before enable.

```bash
# Token file exists on host
test -f ~/.aap-demo/galaxy-token && echo "galaxy-token: ok"

# AAP hub remotes configured (requires admin API — use gateway route)
GATEWAY=$(kubectl get route gateway -n aap-operator -o jsonpath='{.spec.host}')
ADMIN_PW=$(kubectl get secret aap-admin-password -n aap-operator -o jsonpath='{.data.password}' | base64 -d)
TOKEN=$(curl -sk -X POST "https://${GATEWAY}/api/gateway/v1/tokens/" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PW}\"}" | jq -r '.token')
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "https://${GATEWAY}/api/galaxy/_ui/v1/imports/" | jq '.count // .results | length'
```

**Pass:** enable exits 0; remotes API responds without error.

---

## mcp-server

```bash
kubectl get ansiblemcpserver -n aap-operator
kubectl get pods -n aap-operator -l app.kubernetes.io/name=aap-mcp-server
```

**Pass:** AnsibleMCPServer CR exists; MCP pod Running.

---

## portal

```bash
kubectl get pods -n redhat-rhaap-portal
kubectl get route -n redhat-rhaap-portal
kubectl get deployment -n redhat-rhaap-portal
```

**Pass:** Portal deployment available; route has a host under `*.nip.io`.

Windows (optional): `aap-demo status` may list portal namespace if addon enabled.

---

## ao (Automation Orchestrator)

```bash
kubectl get namespace automation-orchestrator
kubectl get pods -n automation-orchestrator
kubectl get routes -n automation-orchestrator
kubectl get automationorchestrator -n automation-orchestrator
```

**Pass:** AO operator and UI pods Running; route exists.

Admin password secret:

```bash
kubectl get secret -n automation-orchestrator -o name | grep -i admin-password
```

---

## apme-eap

Long install (~10–20 min). Verify apme namespace:

```bash
kubectl get pods -n apme
kubectl get route -n apme
kubectl get deployment -n apme
```

**Pass:** Portal hub / apme pods Running; route resolvable.

If `setup-pah` was enabled first, portal should show PAH catalog sync flags (see
`addons/apme-eap/README.md`).

---

## product-demos

```bash
# Base org exists via API
GATEWAY=$(kubectl get route gateway -n aap-operator -o jsonpath='{.spec.host}')
ADMIN_PW=$(kubectl get secret aap-admin-password -n aap-operator -o jsonpath='{.data.password}' | base64 -d)
TOKEN=$(curl -sk -X POST "https://${GATEWAY}/api/gateway/v1/tokens/" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PW}\"}" | jq -r '.token')
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "https://${GATEWAY}/api/controller/v2/organizations/?name=Ansible%20Product%20Demos%20(APD)" | jq '.count'
```

**Pass:** enable exits 0; organization count ≥ 1; no failed domains in deploy output.

Expected install templates (Default org):

- `APD | Install Linux Demos`
- `APD | Install Windows Demos`
- `APD | Install Network Demos`
- `APD | Install Cloud Demos`
- `APD | Install OpenShift Demos`

---

## product-demo-satellite

Requires live Satellite server. Set env on host before enable (from config):

```bash
export SATELLITE_URL="https://satellite.example.com"
# credentials via host-local files or env — never commit
aap-demo enable product-demo-satellite
```

Verify Satellite template exists:

```bash
# After enable — check controller API for SATELLITE templates
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "https://${GATEWAY}/api/controller/v2/job_templates/?name__icontains=SATELLITE" | jq '.count'
```

**Pass:** enable exits 0; Satellite demo templates present.

**Skip:** If Satellite unreachable, record `skipped` with reason (non-strict mode).

---

## local-cache

Run **last** — saves images via CRC SSH (~30 GB, long runtime).

```bash
# After enable (save action)
PRESET=$(crc config get preset 2>/dev/null | awk '{print $NF}' || echo microshift)
ls -la ~/.aap-demo/local-cache/"${PRESET}"/*.tar 2>/dev/null | head -5
du -sh ~/.aap-demo/local-cache/"${PRESET}" 2>/dev/null
```

**Pass:** Cache directory contains `.tar` files; `du` shows non-trivial size.

On next destroy/deploy cycle, verify auto-load:

```bash
grep -q local-cache ~/.aap-demo/config && echo "local-cache registered in ADDONS"
```

**Note:** `enable local-cache load` is for one-shot load without config change; full test uses
`enable local-cache` (save + register).

---

## Post-addon diagnose

After each addon:

```bash
aap-demo diagnose 2>&1 | tee /tmp/aap-diagnose-last.txt
grep -c '✗' /tmp/aap-diagnose-last.txt || true
```

**Pass:** zero `✗` failure lines (warnings `⚠` acceptable unless `--strict`).
