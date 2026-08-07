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

You will be asked to choose an LLM provider and enter credentials, then configure
GitHub OAuth for sign-in and repository access:

1. **AWS Bedrock** (recommended) — AWS region, model name, and bearer token API key
2. **OpenAI-compatible** — API endpoint (`OPENAI_API_BASE`) and API key
3. **AWS Bedrock IAM** — access key + secret key (alternative to bearer token)
4. **GitHub OAuth** — Client ID and Client Secret from a GitHub OAuth App

The enable flow prints the exact **Authorization callback URL** to register at
[github.com/settings/developers](https://github.com/settings/developers).

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

# GitHub OAuth (required — matches upstream x2ansible deploy)
export AUTH_GITHUB_CLIENT_ID=your-github-client-id
export AUTH_GITHUB_CLIENT_SECRET=your-github-client-secret

aap-demo enable x2ansible
```

Register the GitHub OAuth app callback URL shown during `enable`, or predict it as:
`https://backstage-developer-hub-<namespace>.<cluster-apps-domain>/api/auth/github/handler/frame`
(e.g. `https://backstage-developer-hub-x2ansible.apps.127.0.0.1.nip.io/api/auth/github/handler/frame` on aap-demo).

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
| `AUTH_GITHUB_CLIENT_ID` | — | GitHub OAuth Client ID (or set in secrets file) |
| `AUTH_GITHUB_CLIENT_SECRET` | — | GitHub OAuth Client Secret (or set in secrets file) |
| `X2ANSIBLE_AUTH_GITHUB_CLIENT_ID` | — | Prefixed alias for `AUTH_GITHUB_CLIENT_ID` |
| `X2ANSIBLE_AUTH_GITHUB_CLIENT_SECRET` | — | Prefixed alias for `AUTH_GITHUB_CLIENT_SECRET` |

## MicroShift adaptations

The upstream docs assume full OpenShift (`openshift-operators`, `openshift-marketplace`).
This addon adapts for aap-demo's MicroShift OLM layout:

- **CatalogSource**: Uses `redhat-operators` from `aap-operator` (not `openshift-marketplace`). When the operator installs into `operators` (operator-sdk OLM), the catalog is mirrored there because bare OLM only resolves subscriptions against catalogs in the subscription namespace.
- **OperatorGroup**: Created only when the operator namespace has none (avoids breaking full OpenShift)
- **Operator namespace**: Uses `openshift-operators` when present, otherwise `operators` (operator-sdk OLM)
- **Storage**: Auto-detects default StorageClass (`topolvm-provisioner` on aap-demo)
- **SCCs**: Grants `anyuid` + `privileged` to the `x2ansible` namespace
- **Pull secret**: Copies `redhat-operators-pull-secret` and links it to `default` and `x2a-sa` ServiceAccounts
- **Sign-in**: GitHub OAuth (matches upstream `deploy/app.yaml`; guest auth is not used)
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
kubectl get configmap backstage-appconfig-developer-hub -n x2ansible -o yaml | grep baseUrl
```

On MicroShift, the RHDH operator may leave `backend.baseUrl` empty in
`backstage-appconfig-developer-hub`. Re-run `aap-demo enable x2ansible` (with the
updated addon) to patch it automatically, or check that `app-config-rhdh` contains
`app.baseUrl` and `backend.baseUrl`.

### Operator not installing

```bash
kubectl get subscription -n operators
kubectl get csv -n operators | grep rhdh
kubectl get catalogsource redhat-operators -n operators
kubectl get catalogsource redhat-operators -n aap-operator
```

If the subscription shows `NoCatalogSourcesFound` or `ResolutionFailed`, confirm the
`operators` namespace has a healthy `redhat-operators` CatalogSource (re-run
`aap-demo enable x2ansible` after updating the addon).

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
