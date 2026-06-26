# Portal Addon - Ansible Automation Portal (Helm)

Production-ready deployment of Ansible Automation Portal via OpenShift Helm chart.

## Overview

Portal provides a self-service web interface for running AAP job templates without needing to understand playbooks or automation workflows. Built on Red Hat Developer Hub (RHDH) with AAP-specific plugins.

**Architecture:**

- RHDH base application (catalog, templates, plugins)
- AAP plugins for job template synchronization and execution
- OAuth integration with AAP for authentication
- Built-in PostgreSQL database (can use external)

**Comparison with portal-vm:**

| Feature | portal (Helm) | portal-vm (QEMU) |
|---------|--------------|------------------|
| Platform | OpenShift | macOS only |
| Deployment | Production-ready | Dev/test only |
| Performance | Native | Slow (x86 emulation on ARM) |
| Architecture | x86_64 cluster | x86_64 appliance |
| Use case | Long-term deployment | Quick local testing |

## Prerequisites

### AAP Requirements

- AAP 2.6+ deployed in OpenShift (via `aap-demo deploy`)
- Admin user with permissions to:
  - Create organizations
  - Create OAuth applications
  - Generate API tokens
  - Modify platform settings

### OpenShift Requirements

- OpenShift Container Platform or OpenShift Local
- Permissions to:
  - Create Helm releases
  - Create secrets
  - Create routes
- `oc` CLI installed and logged in

### Local Tools

- Helm 3.10+ installed ([install guide](https://helm.sh/docs/intro/install/))
- `jq` for JSON parsing (`brew install jq` on macOS)
- `kubectl` or `oc` CLI configured

### Registry Access

- Red Hat account with access to `registry.redhat.io`
- Registry credentials (username + password or token)
- Or existing pull secret in OpenShift cluster

### Architecture

- **x86_64 cluster required** (portal container images are x86 only)
- If local machine is ARM (Apple Silicon):
  - Deployment still works if cluster is x86
  - Use `portal-vm` addon for local ARM testing instead

## Installation

### Quick Start

```bash
# Enable portal addon
aap-demo enable portal

# Follow prompts for registry credentials if needed
```

### What Happens During Install

1. **Prerequisites check:** Verifies AAP, Helm, oc, architecture
2. **AAP configuration:**
   - Selects/creates organization for template sync
   - Creates OAuth application (placeholder redirect URI)
   - Enables external OAuth token creation
   - Generates API token for catalog access
3. **Registry setup:**
   - Tries existing pull secrets first
   - Prompts for credentials if not found
   - Creates namespace-scoped secret in `redhat-rhaap-portal`
4. **Namespace setup:**
   - Creates `redhat-rhaap-portal` namespace
   - Grants SCCs and copies pull secret from AAP namespace
5. **Helm deployment:**
   - Adds OpenShift Helm Charts repo
   - Installs `redhat-rhaap-portal` chart into `redhat-rhaap-portal` namespace
   - Configures cluster base URL, OCI plugins, org name
6. **Post-install:**
   - Waits for deployment ready (up to 10 minutes)
   - Updates OAuth redirect URI with real portal route

### Manual Registry Credentials Setup

If you want to configure credentials before running enable:

```bash
# Option 1: Use existing cluster pull secret
# (portal addon will auto-detect)

# Option 2: Set environment variables
export REGISTRY_USERNAME="your-username"
export REGISTRY_PASSWORD="your-password-or-token"
aap-demo enable portal

# Option 3: Let addon prompt you during install
# (recommended for first-time users)
```

## Usage

### Check Status

```bash
aap-demo status portal
```

Shows:

- Portal URL
- Deployment status

### Access Portal

```bash
# Get URL
aap-demo status portal

# Open in browser (example output)
https://redhat-rhaap-portal-redhat-rhaap-portal.apps.127.0.0.1.nip.io
```

1. Click "Sign In"
2. Redirects to AAP OAuth login
3. Enter AAP credentials (admin / <aap-admin-password>)
4. Returns to portal catalog
5. Browse AAP job templates as self-service automation

### Get AAP Admin Password

```bash
kubectl get secret aap-admin-password -n aap-operator \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### Disable Portal

```bash
aap-demo disable portal
```

Cleanup:

- Helm release uninstalled from `redhat-rhaap-portal` namespace
- `redhat-rhaap-portal` namespace deleted
- OAuth application deleted from AAP
- Registry secret removed
- Local config directory deleted

If upgrading from an older install that placed portal resources in `aap-operator`,
re-run `aap-demo enable portal` to migrate automatically.

## Configuration

### Helm Values

Portal addon uses these default values (see `deploy.sh`):

```yaml
global:
  clusterRouterBase: <auto-detected-from-cluster>
  pluginMode: oci                      # OCI container delivery (recommended)
  imageTagInfo: "2.2"                  # Must match chart app version (e.g. 2.2.1 chart → 2.2 plugins)

upstream:
  backstage:
    appConfig:
      catalog:
        providers:
          rhaap:
            orgs: "<aap-org-name>"     # Auto-selected from AAP
```

### Customization

To customize Helm values:

1. Edit `~/.aap-demo/portal/values.yaml` after first install
2. Re-run `aap-demo enable portal` to upgrade with new values

**Common customizations:**

```yaml
# Use external PostgreSQL database
upstream:
  backstage:
    appConfig:
      backend:
        database:
          client: pg
          connection:
            host: postgres.example.com
            port: 5432
            user: portal
            password: <password>

# Custom support portal URL
upstream:
  backstage:
    extraEnvVars:
      - name: CUSTOMER_SUPPORT_URL
        value: https://access.redhat.com/support

# Resource limits
upstream:
  backstage:
    resources:
      limits:
        cpu: 2
        memory: 4Gi
      requests:
        cpu: 500m
        memory: 1Gi
```

## Troubleshooting

### Deployment Stuck in Pending

**Symptom:** `kubectl get pods -n redhat-rhaap-portal` shows backstage pod pending.

**Causes:**

1. **Registry pull failure:** Verify credentials in secret

   ```bash
   kubectl get secret redhat-rhaap-portal-dynamic-plugins-registry-auth \
     -n redhat-rhaap-portal -o jsonpath='{.data.auth\.json}' | base64 -d | jq
   ```

2. **Resource constraints:** Check node resources

   ```bash
   kubectl describe pod <backstage-pod> -n redhat-rhaap-portal
   ```

**Fix:** Ensure registry credentials valid, cluster has resources.

### OAuth Login Fails

**Symptom:** "Invalid redirect URI" error during sign-in, or browser redirects to
an unreachable `*.svc.cluster.local` / `*.svc` URL ("page can't be displayed").

**Cause:** The portal OAuth flow sends the browser to `AAP_HOST_URL` for AAP
login. That value comes from the `secrets-rhaap-portal` secret key `aap-host-url`.
If it points at an in-cluster service (for example `http://aap.aap-operator.svc`)
instead of the external AAP route, the browser cannot resolve the hostname.

Updating the secret alone is not enough — portal pods read env vars at startup,
so they must be restarted after the secret changes.

**Fix (recommended):** Re-run enable (updates secret, restarts portal, fixes OAuth redirect):

```bash
aap-demo enable portal
```

**Fix (manual):**

```bash
AAP_ROUTE=$(kubectl get route aap -n aap-operator -o jsonpath='{.spec.host}')

kubectl create secret generic secrets-rhaap-portal \
  -n redhat-rhaap-portal \
  --from-literal=aap-host-url="https://$AAP_ROUTE" \
  --from-literal=oauth-client-id="$(kubectl get secret secrets-rhaap-portal -n redhat-rhaap-portal -o jsonpath='{.data.oauth-client-id}' | base64 -d)" \
  --from-literal=oauth-client-secret="$(kubectl get secret secrets-rhaap-portal -n redhat-rhaap-portal -o jsonpath='{.data.oauth-client-secret}' | base64 -d)" \
  --from-literal=aap-token="$(kubectl get secret secrets-rhaap-portal -n redhat-rhaap-portal -o jsonpath='{.data.aap-token}' | base64 -d)" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/redhat-rhaap-portal -n redhat-rhaap-portal
kubectl rollout status deployment/redhat-rhaap-portal -n redhat-rhaap-portal
```

Verify the running pod has the external URL (not `.svc`):

```bash
kubectl exec deploy/redhat-rhaap-portal -c backstage-backend -n redhat-rhaap-portal -- \
  printenv AAP_HOST_URL
# Expected: https://aap-aap-operator.apps.127.0.0.1.nip.io
```

**OAuth redirect URI mismatch** (separate issue — invalid redirect URI after login):

```bash
# Get portal route (Helm release name, not release-name-backstage)
PORTAL_ROUTE=$(kubectl get route redhat-rhaap-portal \
  -n redhat-rhaap-portal -o jsonpath='{.spec.host}')

# Get OAuth app ID
OAUTH_APP_ID=$(cat ~/.aap-demo/portal/oauth_app_id)

# Get AAP credentials
AAP_ROUTE=$(kubectl get route aap -n aap-operator -o jsonpath='{.spec.host}')
ADMIN_PASS=$(kubectl get secret aap-admin-password -n aap-operator \
  -o jsonpath='{.data.password}' | base64 -d)

# Update redirect URI (rhaap provider uses /api/auth/rhaap/handler/frame)
curl -k -u "admin:$ADMIN_PASS" \
  -X PATCH "https://$AAP_ROUTE/api/gateway/v1/applications/$OAUTH_APP_ID/" \
  -H "Content-Type: application/json" \
  -d "{\"redirect_uris\": \"https://$PORTAL_ROUTE/api/auth/rhaap/handler/frame\"}"
```

### Login Failed: "fetch failed" on Token Exchange

**Symptom:** AAP login page works, but portal shows
`Login failed; caused by Error: Failed to send POST request: fetch failed`.

**Cause:** After OAuth, the portal backend POSTs to `{AAP_HOST_URL}/o/token/`.
On CRC/MicroShift, CoreDNS rewrites route hostnames to in-cluster Services on
port 80. If `AAP_HOST_URL` uses `https://`, the backend tries TLS on port 443
where nothing is listening → timeout → fetch failed.

**Fix:** Re-run `aap-demo enable portal`. On MicroShift the addon sets
`AAP_HOST_URL` to `http://<aap-route>` (not `https://`). Browsers still reach
AAP over HTTPS via ingress; only the pod→service token exchange uses HTTP.

Verify:

```bash
kubectl exec deploy/redhat-rhaap-portal -c backstage-backend -n redhat-rhaap-portal -- \
  printenv AAP_HOST_URL
# MicroShift/CRC expected: http://aap-aap-operator.apps.127.0.0.1.nip.io
```

### No Job Templates in Catalog

**Symptom:** Portal catalog is empty.

**Causes:**

1. **Wrong organization:** Portal syncing from organization with no job templates
2. **API token invalid:** Backend can't access AAP catalog

**Fix:**

```bash
# Check which org is configured
cat ~/.aap-demo/portal/values.yaml | grep orgs

# Verify job templates exist in AAP
AAP_ROUTE=$(kubectl get route aap -n aap-operator -o jsonpath='{.spec.host}')
curl -k -u "admin:<password>" \
  "https://$AAP_ROUTE/api/gateway/v1/job_templates/"

# Check portal logs
kubectl logs deploy/redhat-rhaap-portal -c backstage-backend -n redhat-rhaap-portal --tail=100
```

### ARM Architecture Warning

**Symptom:** "Portal requires x86_64 architecture" warning during enable.

**Explanation:**

- Local machine is ARM (Apple Silicon)
- Portal images are x86_64 only
- Cluster architecture matters, not local machine

**Options:**

1. **If cluster is x86:** Ignore warning, proceed with install
2. **If cluster is ARM (MicroShift on Apple Silicon):**
   - Use `aap-demo enable portal-vm` instead
   - Or provision x86 OpenShift cluster

**Verify cluster architecture:**

```bash
kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}'
```

### Helm Chart Not Found

**Symptom:** "Error: chart not found" during install.

**Fix:**

```bash
# Add OpenShift Helm Charts repo manually
helm repo add openshift-helm-charts https://charts.openshift.io/
helm repo update

# Verify chart available
helm search repo redhat-rhaap-portal
```

### Portal Slow or Unresponsive

**Symptom:** Portal UI sluggish, pages timeout.

**Causes:**

1. **Resource limits:** Backstage pod underpowered
2. **Network latency:** AAP API calls slow

**Fix:**

```bash
# Check pod resources
kubectl top pod -l app.kubernetes.io/instance=redhat-rhaap-portal,app.kubernetes.io/component=backstage -n redhat-rhaap-portal

# Increase resource limits in values.yaml (see Configuration section)
# Then re-run: aap-demo enable portal
```

## Advanced

### Kubernetes Resources

The `redhat-rhaap-portal` Helm chart creates resources named after the release
(not `release-name-backstage`):

| Resource | Name |
|----------|------|
| Deployment | `redhat-rhaap-portal` |
| Route | `redhat-rhaap-portal` |
| Service | `redhat-rhaap-portal` |
| PostgreSQL StatefulSet | `redhat-rhaap-portal-postgresql` |

Route host format: `redhat-rhaap-portal-<namespace>.apps.<cluster-domain>`
(e.g. `redhat-rhaap-portal-redhat-rhaap-portal.apps.127.0.0.1.nip.io`)

Portal installs into the dedicated `redhat-rhaap-portal` namespace (override with
`PORTAL_NAMESPACE`). AAP remains in `aap-operator` (override with `AAP_NAMESPACE`).

### Inspecting Helm Release

```bash
# List Helm releases
helm list -n redhat-rhaap-portal

# Get release values
helm get values redhat-rhaap-portal -n redhat-rhaap-portal

# Get release manifest
helm get manifest redhat-rhaap-portal -n redhat-rhaap-portal
```

### Manual Helm Upgrade

```bash
# Edit values
vim ~/.aap-demo/portal/values.yaml

# Upgrade release
helm upgrade redhat-rhaap-portal openshift-helm-charts/redhat-rhaap-portal \
  -n redhat-rhaap-portal \
  -f ~/.aap-demo/portal/values.yaml
```

### Debugging OAuth Flow

```bash
# Get OAuth app details
AAP_ROUTE=$(kubectl get route aap -n aap-operator -o jsonpath='{.spec.host}')
ADMIN_PASS=$(kubectl get secret aap-admin-password -n aap-operator \
  -o jsonpath='{.data.password}' | base64 -d)

curl -k -u "admin:$ADMIN_PASS" \
  "https://$AAP_ROUTE/api/gateway/v1/applications/" | jq

# Check portal OAuth config in pod
kubectl exec -it deploy/redhat-rhaap-portal -c backstage-backend -n redhat-rhaap-portal -- \
  env | grep -i oauth
```

### Logs

```bash
# Portal application logs
kubectl logs deploy/redhat-rhaap-portal -c backstage-backend -n redhat-rhaap-portal --tail=100 -f

# PostgreSQL logs (if using built-in database)
kubectl logs -l app.kubernetes.io/name=postgresql -n redhat-rhaap-portal --tail=100

# All portal components
kubectl logs -l app.kubernetes.io/instance=redhat-rhaap-portal -n redhat-rhaap-portal --tail=50
```

## References

- [AAP Extend 2.7 Docs](https://access.redhat.com/documentation/en-us/red_hat_ansible_automation_platform/2.7/html/extending_automation/index) - Official portal installation guide (pages 128-145)
- [Portal Lifecycle](https://access.redhat.com/support/policy/updates/ansible-automation-platform) - Version compatibility matrix
- [RHDH Documentation](https://developers.redhat.com/rhdh/overview) - Red Hat Developer Hub overview
- [Helm Documentation](https://helm.sh/docs/) - Helm command reference
- [ADR-004](../../docs/adr/ADR-004-portal-helm-addon.md) - Portal Helm addon architecture decision

## See Also

- `addons/portal-vm/` - QEMU-based portal appliance for macOS local testing
- `aap-demo.sh` - Main aap-demo CLI script
