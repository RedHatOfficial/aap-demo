# Ansible Lightspeed Addon

Deploys the Ansible Lightspeed intelligent assistant into the AAP namespace,
backed by the local [Ollama](https://ollama.com/) LLM (`qwen2.5:3b`) instead of
a cloud model. The `ansible-lightspeed` operator (installed with AAP)
reconciles an `AnsibleLightspeed` custom resource into the Lightspeed API and
chatbot, wired to Ollama's in-cluster OpenAI-compatible endpoint.

## Usage

```bash
aap-demo enable ollama       # Prerequisite: provides the model endpoint
aap-demo enable lightspeed   # Deploy Lightspeed wired to Ollama
aap-demo disable lightspeed  # Remove Lightspeed
```

The addon automatically:

1. Creates a model-configuration Secret pointing at the in-cluster Ollama
   endpoint (`http://ollama.aap-demo-ollama.svc.cluster.local:11434/v1`,
   `model_type: wca-onprem`, model `qwen2.5:3b`)
2. Creates an `AnsibleLightspeed` CR (`lightspeed.ansible.com/v1alpha1`) with
   one API and one chatbot replica
3. On SNO/full OpenShift, repairs the postgres PVC ownership when the operator's
   init container is skipped (see below)

Access the assistant from the AAP console → Lightspeed intelligent assistant.

## Prerequisites

- `aap-demo enable ollama` (provides the model endpoint)
- The `ansible-lightspeed` operator, installed with AAP 2.7+

## Configuration

Override via environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `LIGHTSPEED_MODEL_URL` | in-cluster Ollama `/v1` | Model endpoint |
| `LIGHTSPEED_MODEL_ID` | `qwen2.5:3b` | Model name |
| `LIGHTSPEED_MODEL_TYPE` | `wca-onprem` | Operator model provider type |
| `LIGHTSPEED_CR_NAME` | `aap-lightspeed` | AnsibleLightspeed CR name |
| `LIGHTSPEED_NAMESPACE` | `aap-operator` | Target namespace |

## SNO / full OpenShift note

On single-node OpenShift the Lightspeed postgres StatefulSet runs with a random
UID (the `anyuid` SCC) and cannot write its root-owned PVC, crash-looping with
`mkdir: cannot create directory '/var/lib/pgsql/data/userdata': Permission
denied`. The operator's `postgres_data_volume_init` init container is gated to
non-OpenShift clusters, so the addon fixes the volume ownership directly with a
one-off privileged pod (`chown -R 26:26`) and restarts postgres. This runs
automatically on `enable` when the permission crash is detected.

## Status

```bash
kubectl get ansiblelightspeed -n aap-operator
kubectl get pods -n aap-operator -l app.kubernetes.io/part-of=aap-lightspeed
```

## Troubleshooting

### Lightspeed API not answering

Confirm the API pod is ready and the route is admitted:

```bash
kubectl get pods -n aap-operator | grep aap-lightspeed
kubectl get route -n aap-operator aap-lightspeed
```

### Model errors / no response from the assistant

Confirm the Lightspeed API can reach Ollama in-cluster:

```bash
kubectl exec -n aap-operator deploy/aap-lightspeed-api -- \
  curl -s http://ollama.aap-demo-ollama.svc.cluster.local:11434/api/tags
```

The output should list `qwen2.5:3b`. If not, verify the Ollama addon is healthy
(`aap-demo enable ollama` is idempotent) and re-run `aap-demo wire`.
