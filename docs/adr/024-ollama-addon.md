# ADR-024: Ollama Addon

**Status**: Accepted

**Date**: 2026-09-11

**Authors**: Chad Ferman

## Context

aap-demo supports Automation Orchestrator (AO) as an optional addon (ADR-017) and wires AO
integrations automatically via `addon-wire.sh` (ADR-023). AO supports an `llm_provider`
integration type that connects it to a chat-completions-compatible LLM endpoint, enabling AI-assisted
workflow generation and agent capabilities.

MicroShift VMs in CRC have no GPU and limited public egress. Pointing AO at a cloud LLM
service requires external API keys and introduces a dependency on internet connectivity that
does not match the offline-demo goal of aap-demo. A locally deployed LLM removes both
constraints: no API key, no egress requirement.

[Ollama](https://ollama.com/) runs CPU-only inference and exposes an OpenAI-compatible `/v1`
endpoint. `phi4-mini` (~2.5 GB) fits within the MicroShift VM memory budget and is compact
enough to pull at install time without making the first demo session impractical.

## Decision

Add an `ollama` addon that deploys Ollama with `phi4-mini` pre-pulled to a dedicated
`aap-demo-ollama` namespace and wires it into AO as an `llm_provider` integration.

### Files

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `addons/ollama/ollama.yaml` | All Kubernetes resources for the Ollama deployment |
| Create | `addons/ollama/deploy.sh` | Deploy and delete actions |
| Modify | `includes/addon-wire.sh` | `wire_ollama_*` helpers; Ollama route in allowed-hosts; `aap_demo_wire` call |
| Modify | `aap-demo.sh` | Add `ollama` to `AVAILABLE_ADDONS` and help text |

### Kubernetes resources

| Resource | Name | Notes |
|---|---|---|
| Namespace | `aap-demo-ollama` | `pod-security.kubernetes.io/enforce: privileged` |
| ServiceAccount | `ollama` | In `aap-demo-ollama` |
| ClusterRoleBinding | `aap-demo-ollama-anyuid` | Grants `system:openshift:scc:anyuid` to the SA |
| PVC | `ollama-data` | 20 Gi, `topolvm-provisioner` (RWO), mounted at `/root/.ollama` |
| Deployment | `ollama` | `ollama/ollama:latest`, port 11434, readiness probe on `/api/tags` |
| Service | `ollama` | ClusterIP, port 11434 |
| Route | `ollama` | `ollama.<cluster-apps-domain>`, TLS edge termination |

Resource limits for the Ollama container:

```yaml
requests:
  cpu: "1"
  memory: 2Gi
limits:
  cpu: "4"
  memory: 8Gi
```

`phi4-mini` comfortably fits within 8 Gi for CPU inference while leaving headroom for AAP.

### Cluster domain detection

`deploy.sh` reads the existing AAP route host to derive the cluster apps domain, then
constructs `ollama.<domain>`. Falls back to `ollama.apps.127.0.0.1.nip.io` when AAP is not
yet deployed. This mirrors the pattern used by `mcp-server/deploy.sh`.

### Model pull

After the Deployment reaches rollout, `deploy.sh` posts to the in-cluster ClusterIP
(`http://<svc-ip>:11434/api/pull`) rather than the route hostname. This avoids nip.io
resolution issues in laptop-side shell scripts and mirrors the approach used elsewhere in
aap-demo for in-cluster API calls. The script polls for up to 5 minutes; phi4-mini is
~2.5 GB. If the pull does not complete within that window a warning is printed with a manual
pull command.

### AO wiring

Three new helpers in `addon-wire.sh`:

```bash
wire_ollama_deployed()      # kubectl get deployment ollama -n aap-demo-ollama
wire_ollama_route_host()    # kubectl get route ... -o jsonpath '{.spec.host}'
wire_ollama_url_for_ao()    # https://<route-host>/v1
```

`wire_ao_ollama()` creates or updates:

1. An **LLM Provider** credential named `aap-demo Ollama` with `api_key: "ollama"` (Ollama  # pragma: allowlist secret
   has no authentication; the placeholder satisfies AO's required field).
2. An `llm_provider` integration named `aap-demo Ollama` with `provider_hint: "custom"`,
   `base_url` set to the `/v1` route URL, and `insecure_skip_tls_verify: true`.

The Ollama route hostname is also added to `wire_ao_integration_allowed_hosts_json` so AO's
SSRF allow-list is updated before the integration is created.

`wire_ao_ollama` is called from `aap_demo_wire` after `wire_ao_mcp`. A failure emits a
warning and does not abort the overall wire run.

### AO wiring is optional

If AO is not installed, the addon still deploys and prints the route endpoint; wiring is
skipped silently. Re-running `aap-demo enable ollama` is idempotent — `kubectl apply` and
`wire_ao_ensure_*` are both upsert operations.

## Consequences

### Positive

- Provides an offline-capable LLM endpoint for AO agent workflows and AI-assisted workflow
  generation without cloud API keys or internet egress.
- Follows existing addon patterns exactly — same file layout as `addons/registry/`, same
  AO wiring pattern as `addons/mcp-server/`.
- Idempotent: re-running enable is safe; `OLLAMA_MODEL=<other>` lets operators pull
  additional models without redeploying.

### Negative

- phi4-mini pull is ~2.5 GB and takes several minutes on first enable.
- CPU-only inference is slow for large prompts — acceptable for demo but not production use.
- 20 Gi PVC on `topolvm-provisioner` consumes significant VM disk space.
- AO credentials/integration persist after `aap-demo disable ollama`; they become invalid
  automatically but must be removed manually from the AO UI if unwanted.

### Neutral

- No GPU support is exposed — MicroShift VMs have none.
- Additional models can be pulled but require extra disk space.
- Ollama has no native authentication; the `api_key: "ollama"` placeholder is purely  # pragma: allowlist secret
  structural.

## Alternatives Considered

**Cloud LLM endpoint (OpenAI, Azure OpenAI, AWS Bedrock)**: Requires an external API key and
internet connectivity. Breaks offline demo goals. Rejected.

**llama.cpp directly in a container**: More complex image build, no standard API until wrapped.
Ollama already bundles llama.cpp with an OpenAI-compatible HTTP server. Rejected.

**Different model (Mistral 7B, Llama 3.1 8B)**: Larger download and higher memory pressure on
MicroShift VMs. phi4-mini is sufficient for AO agent use cases within the VM memory budget.
Users can pull additional models post-install via `OLLAMA_MODEL=<name> aap-demo enable ollama`.
Rejected as the default.

**Shared Ollama in `aap-operator` namespace**: Avoids a separate namespace but couples Ollama
lifecycle to AAP, complicates SCC grants, and contradicts the pattern in ADR-008 (addons are
independent). Rejected.

## References

- [`addons/ollama/`](../../addons/ollama/)
- [`includes/addon-wire.sh`](../../includes/addon-wire.sh)
- ADR-008: Addon system
- ADR-011: MCP server addon
- ADR-017: Automation Orchestrator addon
- ADR-023: Addon auto-wiring
