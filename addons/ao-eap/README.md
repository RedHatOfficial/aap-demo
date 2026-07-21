# Automation Orchestrator Early Access Addon

Deploys Automation Orchestrator Early Access to aap-demo clusters.

## Prerequisites

1. **Registry path** for AO images (provided by your Red Hat contact)
2. **Cluster pull secret** with credentials for the registry
3. **aap-demo cluster** running with OLM installed (`aap-demo deploy`)

## Registry Configuration

The addon prompts for the container registry path on first run. The registry location is provided externally by your Red Hat point of contact.

### Interactive Setup

```bash
./deploy.sh
```

On first run, you'll be prompted for:
- Registry path (e.g., `registry.redhat.io/ansible-automation-platform`)

The configuration is saved to `~/.aap-demo/ao-registry` and reused on subsequent runs.

### Authentication

Registry authentication is handled automatically via your cluster's pull secret:

```bash
# Verify your cluster has registry credentials
kubectl get secret pull-secret -n openshift-config
```

The addon extracts credentials for the configured registry from the cluster's pull secret. Ensure your cluster has access to the registry before running the deployment.

### Environment Variables

For automation or CI/CD, provide the registry path via environment variable:

```bash
export AO_REGISTRY="registry.redhat.io/ansible-automation-platform"
./deploy.sh
```

### Custom Index Image

Override the operator index image if needed:

```bash
export AO_INDEX_IMAGE="registry.example.com/custom/ao-operator-index:v2.6.0"
./deploy.sh
```

## Usage

### Deploy

Deploy Automation Orchestrator to your cluster:

```bash
./deploy.sh
```

### Force Reinstall

Redeploy even if already running:

```bash
./deploy.sh --force
# or
FORCE=1 ./deploy.sh
```

### Remove

Uninstall Automation Orchestrator:

```bash
./deploy.sh --delete
```

## Configuration Files

The addon stores configuration in `~/.aap-demo/`:

- `ao-registry` - Full registry path (mode 600)

### Migration from Legacy Format

Legacy `quay-username` and `quay-token` files are automatically removed when the addon runs, as authentication now uses the cluster pull secret.

## Troubleshooting

### No credentials found for registry

**Error**: `ERROR: No credentials found in cluster pull secret for <registry>`

**Solution**: Ensure your cluster's pull secret has credentials for the registry:

```bash
# Check pull secret
kubectl get secret pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq .

# Expected: Should see auth entry for your registry host
```

If the credentials are missing, add them to your cluster's pull secret. On OpenShift:

```bash
# Add registry credentials to cluster pull secret
oc set data secret/pull-secret -n openshift-config \
  --from-file=.dockerconfigjson=<path-to-auth.json>
```

### Custom Storage Class

Override the default storage class if needed:

```bash
export AO_STORAGE_CLASS="my-storage-class"
./deploy.sh
```

## Architecture

The deployment automates the full 10-step Automation Orchestrator EAP installation:

1. Configure registry (prompt on first run)
2. Validate pull secret credentials
3. Install aapctl CLI
4. Create namespaces and SCCs
5. Create pull secret for CatalogSource
6. Deploy CatalogSource
7. Install operator via Subscription
8. Patch CSV image references
9. Deploy CloudNative-PG operator
10. Create AutomationOrchestrator instance with aapctl

## Documentation

For more details, see:
- ADR: `docs/adr/017-ao-eap-addon.md`
- Upstream: https://github.com/automation-nexus/aapctl
