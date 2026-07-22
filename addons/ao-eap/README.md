# Automation Orchestrator Early Access Addon

Deploys Automation Orchestrator Early Access to aap-demo clusters.

## Prerequisites

1. **Index image reference** for the AO operator (provided by your Red Hat contact)
2. **Cluster pull secret** with credentials for the registry
3. **aap-demo cluster** running with OLM installed (`aap-demo deploy`)
4. **GitHub CLI authenticated** (`gh auth login`) — required to download `aapctl`

## Configuration

The addon prompts for the index image on every run. The registry host is derived automatically from the image URL, so only one value is needed.

### Interactive Setup

```bash
./deploy.sh
```

You will be prompted for one value from your Red Hat contact:

- **Index image** (full image URL with tag)
  - Example prompt: `Index image (full URL with tag): `
  - Enter the complete operator index image reference
  - Always prompted to prevent accidental reuse of stale image references

The index image can also be provided via the `AO_INDEX_IMAGE` environment variable to skip the prompt.

### Authentication

Registry authentication is handled automatically via your cluster's pull secret.

#### OpenShift Clusters

On OpenShift, verify the global pull secret exists:

```bash
kubectl get secret pull-secret -n openshift-config
```

If you need to add registry credentials to an existing OpenShift cluster:

```bash
# Download your pull secret from https://console.redhat.com/openshift/downloads#tool-pull-secret
oc set data secret/pull-secret -n openshift-config \
  --from-file=.dockerconfigjson=~/Downloads/pull-secret.json
```

#### MicroShift Clusters

MicroShift uses CRI-O's pull secret configuration. Configure it before starting MicroShift:

```bash
# 1. Download your pull secret from Red Hat
#    https://console.redhat.com/openshift/downloads#tool-pull-secret

# 2. Copy to CRI-O configuration directory
sudo cp ~/Downloads/pull-secret.json /etc/crio/openshift-pull-secret
sudo chmod 600 /etc/crio/openshift-pull-secret

# 3. Restart services
sudo systemctl restart crio
sudo systemctl restart microshift
```

#### CRC (CodeReady Containers)

Configure the pull secret when creating or recreating your CRC cluster:

```bash
crc stop
crc config set pull-secret-file ~/Downloads/pull-secret.json
crc start
```

#### Getting Your Pull Secret

1. Log in to the Red Hat Hybrid Cloud Console
2. Visit: https://console.redhat.com/openshift/downloads#tool-pull-secret
3. Click "Download pull secret"
4. Save to a secure location (e.g., `~/.aap-demo/pull-secret.json`)

The pull secret contains credentials for multiple Red Hat registries including `registry.redhat.io`.

### Environment Variables

For automation or CI/CD, provide the index image via environment variable to skip the prompt:

```bash
export AO_INDEX_IMAGE="<index-image-provided-by-red-hat>"
./deploy.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `AO_INDEX_IMAGE` | _(prompted every run)_ | Full index image URL with tag |
| `PULL_SECRET_FILE` | `~/.aap-demo/pull-secret.txt` | Path to dockerconfigjson pull secret |


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
