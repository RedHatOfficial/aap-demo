# EDA Playground Addon

Deploys [EDA Playground](https://github.com/BBGrimmett2/EDA-Playground) to your aap-demo cluster.

## What is EDA Playground?

EDA Playground is an interactive web-based tool for testing and experimenting with Event-Driven Ansible
integrations and webhook payloads. It provides:

- **Interactive webhook testing** - Send test webhooks to EDA Controller
- **Integration explorer** - Browse and test various event source integrations
- **Payload builder** - Construct and validate webhook payloads
- **Real-time testing** - See how EDA processes different event formats

## Prerequisites

- `aap-demo` cluster running (`aap-demo create`)
- `kubectl` connected to cluster

## Usage

### Deploy

```bash
# From the addon directory
./deploy.sh

# Or using aap-demo
aap-demo enable eda-playground
```

### Delete

```bash
# From the addon directory
./deploy.sh --delete

# Or using aap-demo
aap-demo disable eda-playground
```

## Access

After deployment, EDA Playground will be available at:

```
https://eda-playground.apps.127.0.0.1.nip.io
```

## Configuration

The deployment uses:

- **Image**: `ghcr.io/bbgrimmett2/eda-playground:latest`
- **Namespace**: `eda-playground`
- **Resources**: 100m CPU / 128Mi RAM (requests), 500m CPU / 512Mi RAM (limits)
- **Self-signed certs**: Enabled via `ALLOW_SELF_SIGNED_CERTS=true`

### Image Source and Maintenance

! **Important**: The EDA Playground image (`ghcr.io/bbgrimmett2/eda-playground:latest`) is hosted
on the addon author's personal GitHub Container Registry. This is not an official Red Hat image.

- **Source Repository**: https://github.com/BBGrimmett2/EDA-Playground
- **Container Registry**: https://github.com/BBGrimmett2/EDA-Playground/pkgs/container/eda-playground
- **Image Tag**: `latest` (automatically pulls newest version)
- **Maintenance**: Maintained by @BBGrimmett2

**Production Considerations**:

- For production use, consider pinning to a specific image digest rather than `latest`
- Monitor the source repository for updates and security patches
- The image can be mirrored to an internal registry for air-gapped environments

**Example - Pin to digest**:

```yaml
# In deployment.yaml, replace:
image: ghcr.io/bbgrimmett2/eda-playground:latest
# With:
image: ghcr.io/bbgrimmett2/eda-playground@sha256:abc123...
```

### Custom Integrations

You can add custom integration definitions by updating the `eda-playground-integrations` ConfigMap:

```bash
kubectl edit configmap eda-playground-integrations -n eda-playground
```

Custom integration files will be mounted at `/app/integrations/custom/` in the container.

## Troubleshooting

### Check deployment status

```bash
kubectl get pods -n eda-playground
kubectl describe deployment eda-playground -n eda-playground
```

### View logs

```bash
kubectl logs -n eda-playground -l app=eda-playground
```

### Common issues

#### Pod fails to start with SCC errors

- The deployment requires `anyuid` SCC which is automatically granted during deployment
- Verify: `oc get scc anyuid -o jsonpath='{.groups}' | grep eda-playground`

#### Image pull failures

- The image is public on GHCR, no authentication needed
- Check image availability: `https://github.com/BBGrimmett2/EDA-Playground/pkgs/container/eda-playground`

## Source

- GitHub: https://github.com/BBGrimmett2/EDA-Playground
- Container Registry: ghcr.io/bbgrimmett2/eda-playground
