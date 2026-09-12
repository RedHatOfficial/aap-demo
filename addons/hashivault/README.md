# HashiVault Addon (`hashivault`)

Deploys **HashiCorp Vault** on aap-demo clusters for secret management demonstration with Ansible Automation Platform (AAP).

- **Command:** `aap-demo enable hashivault`
- **Namespace:** `aap-operator` (same as AAP)
- **Requires:** `aap-demo deploy` (AAP + cluster ready)
- **Deployment:** HashiCorp Vault Helm chart (dev mode)

## Quick Start

```bash
aap-demo deploy                # Deploy AAP first
aap-demo enable hashivault     # Deploy vault + configure AAP integration
aap-demo status                # Show vault URL and credentials
```

Force reinstall:

```bash
FORCE=1 aap-demo enable hashivault
```

Remove addon:

```bash
aap-demo disable hashivault
```

Remove addon and purge state data:

```bash
aap-demo disable hashivault --purge-data
```

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| `aap-demo deploy` | AAP must be deployed and ready |
| `helm` | Helm 3.10+ required for chart deployment |
| `kubectl` | Cluster access configured |
| `jq` | JSON parsing for AAP API |

## How It Works

The addon:

1. **Deploys Vault** via HashiCorp Helm chart in dev mode (auto-unsealed, in-memory storage)
2. **Initializes KV v2 secrets engine** at path `secret/`
3. **Creates test secrets** for demonstration (`secret/demo`)
4. **Configures AAP integration** (organization, project, credentials, job templates) - _Coming in Phase 4_
5. **Creates demo job templates** showcasing runtime secret injection - _Coming in Phase 5_

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VAULT_CHART_VERSION` | `0.28.0` | HashiCorp Vault Helm chart version |
| `VAULT_VERSION` | `1.17.2` | Vault container image version |
| `AAP_DEMO_REPO` | `https://github.com/RedHatOfficial/aap-demo.git` | Playbook repository |
| `AAP_DEMO_BRANCH` | `main` | Playbook branch |
| `FORCE` | unset | Set to `1` to force reinstall |
| `PURGE_DATA` | unset | Set to `1` to remove vault state on disable |
| `NAMESPACE` | `aap-operator` | Deployment namespace |

## Demo Workflow (Planned)

### Step 1: Enable Addon

```bash
aap-demo enable hashivault
```

### Step 2: Test Vault Connection

Navigate to AAP UI → Templates → Launch "HashiVault | Test Connection"

### Step 3: Read Secret

Launch "HashiVault | Read Secret" to see initial secret values

### Step 4: Update Secret

Launch "HashiVault | Update Secret" to modify the api_key

### Step 5: Verify Runtime Injection

Launch "HashiVault | Verify Runtime Injection" to see updated values

**Key Concept:** Secret changed without rebuilding execution environment!

## Vault UI Access

After enabling the addon, access the Vault web UI:

```bash
# Get vault route URL
kubectl get route vault -n aap-operator -o jsonpath='{.spec.host}'

# Example: https://vault-aap-operator.apps-crc.testing
# Root Token: root
```

## Vault CLI Access

```bash
# Check vault status
kubectl exec -n aap-operator vault-0 -- vault status

# Read demo secret
kubectl exec -n aap-operator vault-0 -- vault kv get secret/demo

# List secrets
kubectl exec -n aap-operator vault-0 -- vault kv list secret/
```

## State Management

Vault configuration is persisted to `~/.aap-demo/hashivault/`:

- **root-token** - Vault root token (for demos)
- **config** - Vault URL and namespace configuration

State is preserved across `enable`/`disable` cycles. Use `--purge-data` to remove:

```bash
aap-demo disable hashivault --purge-data
```

## Production Deployment Notes

⚠️ **WARNING**: This addon deploys Vault in **dev mode** for demonstration purposes:

- **Auto-unsealed** (no seal keys required)
- **In-memory storage** (data lost on pod restart)
- **Single root token authentication** (no proper auth methods)
- **No TLS** (communication in plain HTTP within cluster)
- **Not suitable for production use**

For production Vault deployment:

- Use persistent storage (PVC-backed)
- Implement auto-unseal (cloud KMS, Transit, or Shamir)
- Use proper auth methods (AppRole, Kubernetes, LDAP, OIDC)
- Enable audit logging
- Use TLS for all connections
- Follow [HashiCorp Vault Production Hardening Guide](https://developer.hashicorp.com/vault/tutorials/operations/production-hardening)

## Troubleshooting

### Vault pod not starting

Check pod status and events:

```bash
kubectl get pod vault-0 -n aap-operator
kubectl describe pod vault-0 -n aap-operator
kubectl logs vault-0 -n aap-operator
```

### Helm chart installation failed

Verify Helm repository:

```bash
helm repo list | grep hashicorp
helm search repo hashicorp/vault
```

### AAP not accessible

Verify AAP is deployed and ready:

```bash
kubectl get aap aap -n aap-operator
kubectl get route aap -n aap-operator
```

### Vault sealed after pod restart

This is expected in dev mode. Vault dev mode uses in-memory storage, so data is lost on restart. The addon automatically re-initializes secrets on enable.

## Development Status

**Current Phase:** Foundation (Phase 1-3 Complete)

- ✅ Directory structure created
- ✅ Vault Helm deployment implemented
- ✅ Vault initialization and test secret creation
- ✅ Playbooks created (4 demo playbooks)
- ✅ State management (save/load configuration)
- ✅ Cleanup logic (disable with --purge-data)
- ⏳ AAP integration (organization, project, credentials) - **Phase 4**
- ⏳ Job template creation via AAP API - **Phase 5**
- ⏳ Comprehensive README - **Phase 6**

## Files

```
addons/hashivault/
├── deploy.sh                           # Main deployment script
├── README.md                           # This file
├── lib/
│   └── vault-helpers.sh                # Shared vault utility functions
└── playbooks/
    ├── test-vault-connection.yml       # Health check playbook
    ├── read-secret-demo.yml            # Read secret demonstration
    ├── update-secret-demo.yml          # Update secret demonstration
    └── verify-runtime-injection.yml    # Verify runtime injection
```

## Next Steps

To complete the implementation:

1. **Phase 4 (AAP Integration):** Implement AAP API calls to create organization, project, inventory, custom credential type, and credential instance
2. **Phase 5 (Job Templates):** Implement job template creation via AAP API
3. **Phase 6 (Documentation):** Expand README with complete demo workflow, screenshots, troubleshooting
4. **Phase 7 (Testing):** Add integration tests and verify end-to-end workflow

## Contributing

This addon follows the established patterns from:

- **OPA addon** - AAP API integration patterns
- **AO addon** - State management and error handling patterns
- **Portal addon** - Helm deployment patterns
