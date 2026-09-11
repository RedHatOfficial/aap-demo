# Ollama Addon Design

**Date:** 2026-09-11
**Branch:** feature/ollama-addon
**Status:** Approved

## Overview

Add an `ollama` addon that deploys Ollama (CPU-only) to a dedicated namespace on
MicroShift/CRC, pre-pulls the `phi4-mini` model, and wires it into Automation
Orchestrator as an `llm_provider` integration.

Enabled via: `aap-demo enable ollama`
Removed via: `aap-demo disable ollama`

## Files

```
addons/ollama/
  deploy.sh       # Deploy / delete script
  ollama.yaml     # Kubernetes manifests
```

Two existing files get small additions:

- `includes/addon-wire.sh` — new `wire_ollama_*` helpers + updated allowed-hosts list + updated `aap_demo_wire`
- `aap-demo.sh` — `ollama` added to `AVAILABLE_ADDONS` and help text

## Kubernetes Resources (`ollama.yaml`)

| Resource | Name | Notes |
|---|---|---|
| Namespace | `aap-demo-ollama` | `pod-security.kubernetes.io/enforce: privileged` |
| ServiceAccount | `ollama` | In `aap-demo-ollama` |
| ClusterRoleBinding | `aap-demo-ollama-anyuid` | Grants `system:openshift:scc:anyuid` to the SA |
| PVC | `ollama-data` | 20Gi, `topolvm-provisioner` (RWO), mounted at `/root/.ollama` |
| Deployment | `ollama` | Image `ollama/ollama`, port 11434, CPU-only resource limits |
| Service | `ollama` | ClusterIP, port 11434 |
| Route | `ollama` | `ollama.<cluster-apps-domain>`, TLS edge termination |

### Deployment resource limits

```yaml
resources:
  requests:
    cpu: "1"
    memory: 2Gi
  limits:
    cpu: "4"
    memory: 8Gi
```

`phi4-mini` fits comfortably within 8Gi for CPU inference. Limits are generous enough
that the model won't OOM but conserve headroom for AAP.

### Readiness probe

```yaml
readinessProbe:
  httpGet:
    path: /api/tags
    port: 11434
  initialDelaySeconds: 10
  periodSeconds: 10
```

## deploy.sh Flow

### Deploy (default action)

1. Validate `kubectl cluster-info`
2. `kubectl apply -f ollama.yaml`
3. `kubectl rollout status deployment/ollama -n aap-demo-ollama --timeout=120s`
4. Pull `phi4-mini` model — POST to the in-cluster service URL
   (`http://$(kubectl get svc ollama -n aap-demo-ollama -o jsonpath='{.spec.clusterIP}'):11434/api/pull`)
   using `curl` with a streaming response poll loop. Print progress dots; timeout
   after 5 minutes.
5. Print the route URL, in-cluster service URL, and example `curl` usage.
6. If AO is deployed (checked via `wire_ao_deployed`), source `addon-wire.sh` and
   call `aap_demo_wire` to wire the integration (same pattern as
   `mcp-server/deploy.sh`).

### Delete (`--delete`)

1. `kubectl delete namespace aap-demo-ollama` (removes all namespaced resources)
2. `kubectl delete clusterrolebinding aap-demo-ollama-anyuid`
3. Print confirmation. AO credential/integration are left in place — they become
   invalid automatically when the route disappears and can be cleaned up from the AO
   UI.

## AO Wiring (`addon-wire.sh` additions)

### New helpers

```bash
wire_ollama_deployed()      # kubectl get deployment ollama -n aap-demo-ollama
wire_ollama_route_host()    # kubectl get route ollama -n aap-demo-ollama -o jsonpath='{.spec.host}'
wire_ollama_url_for_ao()    # https://<route-host>/v1  (Ollama's OpenAI-compatible base)
```

### `wire_ao_ollama()`

1. Return early if AO or Ollama is not deployed.
2. Resolve the route URL via `wire_ollama_url_for_ao`.
3. Create (or update) an "LLM Provider" credential named `"aap-demo Ollama"` with
   `api_key: "ollama"` (Ollama has no authentication; placeholder satisfies AO's
   required field).
4. Create (or update) an `llm_provider` integration named `"aap-demo Ollama"` with:
   - `provider_hint: "custom"`
   - `base_url`: the route URL
   - `allow_http: true`, `insecure_skip_tls_verify: true`

Uses the existing `wire_ao_ensure_credential` and `wire_ao_ensure_integration` helpers — no new API call patterns needed.

### `wire_ao_integration_allowed_hosts_json()` update

Add one line to emit the Ollama route host alongside the existing AAP, AO, and MCP hosts:

```bash
h=$(wire_ollama_route_host) && [ -n "$h" ] && printf '%s\n' "$h"
```

This ensures AO's `APP_INTEGRATION_URL_ALLOWED_HOSTS` allow-list includes the Ollama
route before the integration is created (AO rejects private IPs; route hostnames pass
the check).

### `aap_demo_wire()` update

Add after `wire_ao_mcp`:

```bash
wire_ao_ollama || wire_warn "Ollama integration skipped"
```

## `aap-demo.sh` changes

- `AVAILABLE_ADDONS` — append `ollama`
- Short help entry: `enable ollama  Deploy Ollama LLM server with phi4-mini (wires into AO as llm_provider)`

## Cluster domain detection

The route hostname follows the same pattern as the `mcp-server` addon: read the
existing AAP route host to derive the cluster apps domain, then construct
`ollama.<domain>`. Falls back to `ollama.apps.127.0.0.1.nip.io` if AAP is not yet
deployed.

## Constraints and assumptions

- **CPU-only**: MicroShift VMs have no GPU. Ollama runs fine in CPU mode; phi4-mini inference is slow but functional.
- **No auth on Ollama**: Ollama does not support API key auth natively. The
  `api_key: "ollama"` placeholder satisfies AO's required field; actual requests are
  unauthenticated.
- **20Gi PVC**: phi4-mini is ~2.5GB; 20Gi leaves room for additional model pulls without redeploying.
- **AO wiring is optional**: If AO is not installed the addon still deploys and prints
  the endpoint; wiring is skipped silently.
- **Idempotent**: Re-running `aap-demo enable ollama` is safe — `kubectl apply` is
  idempotent and `wire_ao_ensure_*` upserts credentials and integrations.
