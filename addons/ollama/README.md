# Ollama Addon

Deploys [Ollama](https://ollama.com/) (CPU-only) to a dedicated `aap-demo-ollama` namespace,
pre-pulls the `qwen2.5:3b` model, and wires it into Automation Orchestrator as an
`llm_provider` integration with `qwen2.5:3b` set as the default model.

## Usage

```bash
aap-demo enable ollama     # Deploy Ollama + pull qwen2.5:3b + wire into AO
aap-demo disable ollama    # Remove Ollama (AO integration becomes invalid)
```

The addon automatically:

1. Deploys the `ollama/ollama` container with a 20Gi PVC for model storage
2. Pulls `qwen2.5:3b` (~2GB) from the Ollama registry at deploy time
3. Wires Ollama into Automation Orchestrator as an `llm_provider` integration
   (named `aap-demo Ollama`) using the OpenAI-compatible `/v1` endpoint
4. Sets `qwen2.5:3b` as the default model on the AO integration

## Model selection

`qwen2.5:3b` is the default because it correctly generates OpenAI-format tool calls
and completes responses within AO's per-attempt timeout on CPU-only hardware.

| Model | Tool calls | CPU speed | Notes |
|-------|-----------|-----------|-------|
| `qwen2.5:3b` | ✓ correct JSON | fast (~10s) | **Default** |
| `qwen3.5:4b` | ✓ correct JSON | slow (~30s) | Hits AO timeout (thinking mode) |
| `phi4-mini` | ✗ broken format | fast | Outputs `<\|tool_call\|>` as text |

## Endpoints

| Access | URL |
|--------|-----|
| Route | `https://ollama.apps.<cluster-domain>` |
| OpenAI-compatible | `https://ollama.apps.<cluster-domain>/v1` |
| In-cluster | `http://ollama.aap-demo-ollama.svc.cluster.local:11434` |

## Test inference

```bash
curl -sk https://ollama.apps.127.0.0.1.nip.io/api/generate \
  -d '{"model":"qwen2.5:3b","prompt":"Hello","stream":false}'
```

## Pull additional models

```bash
OLLAMA_MODEL=mistral:7b aap-demo enable ollama
```

Re-running `aap-demo enable ollama` with a different `OLLAMA_MODEL` is safe — it is idempotent.
The new model will be set as the AO default on re-wire.

## Resource usage

- **CPU**: requests 1 core, limit 4 cores (CPU-only inference — no GPU in MicroShift VMs)
- **Memory**: requests 2Gi, limit 8Gi
- **Storage**: 20Gi RWO PVC on `topolvm-provisioner`

## Status

```bash
kubectl get deployment,pvc -n aap-demo-ollama
kubectl logs -n aap-demo-ollama -l app=ollama --tail=20
```
