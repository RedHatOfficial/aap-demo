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
