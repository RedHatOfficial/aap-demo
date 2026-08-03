# X2Ansible Addon

Deploy [X2Ansible](https://x2ansible.github.io/) (Conversion Hub) on aap-demo using the
official manifests from [x2ansible.github.io/deploy](https://github.com/x2ansible/x2ansible.github.io/tree/main/deploy).

This addon follows the upstream deployment flow:

1. Install the Red Hat Developer Hub (RHDH) operator via OLM
2. Apply `app.yaml` (ConfigMaps, PVC, Backstage CR with X2A dynamic plugins)
3. Configure `x2a-credentials` secret (LLM + optional AAP integration)

## Prerequisites

| Requirement | How to satisfy |
|-------------|----------------|
| aap-demo cluster with OLM | `aap-demo create` then `aap-demo deploy` |
| `registry.redhat.io` pull secret | Created automatically during `aap-demo deploy` |
| AWS Bedrock credentials | Required for LLM conversion features |
| x86_64 cluster (recommended) | RHDH operator images are x86-only; ARM is blocked unless `X2ANSIBLE_FORCE_ARM=true` |

AAP integration is optional for core conversion but recommended — the addon auto-discovers
the AAP gateway URL and generates an OAuth token when AAP is deployed.

## Quick Start

```bash
# Deploy AAP first (if not already running)
aap-demo deploy

# Enable X2Ansible — prompts for LLM credentials on first run
aap-demo enable x2ansible
```

You will be asked to choose an LLM provider and enter credentials:

1. **AWS Bedrock** (recommended) — AWS region, model name, and bearer token API key
2. **OpenAI-compatible** — API endpoint (`OPENAI_API_BASE`) and API key
3. **AWS Bedrock IAM** — access key + secret key (alternative to bearer token)

Credentials are saved to `~/.aap-demo/x2ansible-secrets.yaml` (mode `600`) and applied
as the `x2a-credentials` secret. AAP gateway URL and OAuth token are auto-discovered when
AAP is deployed.

To change LLM credentials later:

```bash
aap-demo config x2ansible
```

## Configuration

### Secrets file

Default path: `~/.aap-demo/x2ansible-secrets.yaml` (created interactively or from env vars).

Override with `X2ANSIBLE_SECRETS_FILE`.

Re-prompt and update the cluster secret:

```bash
aap-demo config x2ansible
```

### Non-interactive / CI

Set credentials via environment variables before `aap-demo enable x2ansible`:

```bash
# AWS Bedrock (matches x2ansible getting-started docs)
export AWS_REGION=us-east-1
export AWS_BEARER_TOKEN_BEDROCK=your-bearer-token
export LLM_MODEL=anthropic.claude-3-7-sonnet-20250219-v1:0

# Or OpenAI-compatible endpoint + API key
export OPENAI_API_BASE=https://api.openai.com/v1
export OPENAI_API_KEY=your-api-key
export LLM_MODEL=gpt-4o

aap-demo enable x2ansible
```

Prefixed `X2ANSIBLE_*` variants are also supported (e.g. `X2ANSIBLE_OPENAI_API_KEY`).

### AAP integration

When AAP is running in `aap-operator`, the addon automatically:

- Sets `AAP_URL` to the AAP gateway route
- Generates an `AAP_OAUTH_TOKEN` via the gateway API
- Sets `AAP_SKIP_SSL_VERIFICATION=true` (self-signed ingress CA on aap-demo)

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `X2ANSIBLE_NAMESPACE` | `x2ansible` | Application namespace |
| `AAP_NAMESPACE` | `aap-operator` | Namespace for AAP route/credential discovery |
| `X2ANSIBLE_RHDH_CHANNEL` | `fast-1.9` | RHDH operator OLM channel |
| `X2ANSIBLE_FORCE_ARM` | unset | Set to `true` to attempt deploy on ARM64 (unsupported) |

## MicroShift adaptations

The upstream docs assume full OpenShift (`openshift-operators`, `openshift-marketplace`).
This addon adapts for aap-demo's MicroShift OLM layout:

- **CatalogSource**: Uses `redhat-operators` from `aap-operator` (not `openshift-marketplace`)
- **OperatorGroup**: Created only when the operator namespace has none (avoids breaking full OpenShift)
- **Operator namespace**: Uses `openshift-operators` when present, otherwise `operators` (operator-sdk OLM)
- **Storage**: Auto-detects default StorageClass (`topolvm-provisioner` on aap-demo)
- **SCCs**: Grants `anyuid` + `privileged` to the `x2ansible` namespace
- **Pull secret**: Copies `redhat-operators-pull-secret` and links it to `default` and `x2a-sa` ServiceAccounts
- **Sign-in**: Guest auth enabled for lab use (no GitHub OAuth required)
- **RHDH only**: Does not install DevSpaces (upstream `operator.yaml` includes it; omitted here for MicroShift)

Re-running `aap-demo enable x2ansible` refreshes AAP URL/OAuth token while preserving LLM credentials.

**Platform note:** `enable x2ansible` and `config x2ansible` are bash-only today (PowerShell addon support not yet implemented).

## Verify deployment

```bash
aap-demo status

kubectl get backstage -n x2ansible
kubectl get pods -n x2ansible
kubectl get route developer-hub -n x2ansible
```

Open the Conversion Hub at `https://<route-host>/x2a`.

## Disable / remove

```bash
aap-demo disable x2ansible
```

This removes the `x2ansible` namespace and cluster-scoped RBAC. The RHDH operator remains
installed (cluster-scoped, shared resource).

## Troubleshooting

### Backstage pod fails to start

```bash
kubectl get secret x2a-credentials -n x2ansible
kubectl logs -n x2ansible deployment/backstage-developer-hub
```

### Operator not installing

```bash
kubectl get subscription -n openshift-operators
kubectl get csv -n openshift-operators | grep rhdh
kubectl get catalogsource redhat-operators -n aap-operator
```

### After editing secrets

```bash
aap-demo config x2ansible
```

This re-prompts for credentials, updates the cluster secret, and restarts Backstage automatically.

## Upstream references

- [Installation guide](https://x2ansible.github.io/platform/installation.html)
- [Deploy README](https://github.com/x2ansible/x2ansible.github.io/tree/main/deploy)
- [Authentication](https://x2ansible.github.io/platform/authentication.html)
- [MCP tools](https://x2ansible.github.io/platform/mcp-server.html)

Manifests in this addon are copied from `x2ansible.github.io/deploy/` and adapted for aap-demo.
