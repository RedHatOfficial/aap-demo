# APME Playbook Addon

Deploy Ansible Portal with Ansible Quality (APME) on OpenShift Local (MicroShift) via
the published **APME operator**.

> **Preview:** APME is prototype software for the Early Access Program.
> Confidential — Red Hat associate and NDA partner use only.

## Overview

The CLI (`deploy.sh`) installs the published [APME operator](https://github.com/ansible/apme-operator/releases/tag/v0.1.0),
applies its `Apme` resource, and deploys the portal directly through the local Kubernetes API:

- **Direct deployment**: No AAP project, execution environment, job template, or AAP job is created
- **AAP integration**: AAP remains the OAuth and Ansible API backend used by the portal
- **Pre-built portal hub**: `quay.io/cferman/portal-hub-eap:latest` (no registry/skopeo at deploy)
- **Operator-managed APME**: The operator manages the APME engine, gateway, and Postgres resources

**Architecture:** `deploy.sh` discovers the environment, runs host pre-steps (`setup-pah`,
GitHub credentials), installs the operator, deploys the portal, and configures the portal to use
the internal APME gateway.

## Operator install

The local deploy script installs the published APME operator and applies an `Apme` custom resource.
The RHDH portal remains deployed from `addons/portal/deploy.yaml`; the operator manages
the APME engine, gateway, and Postgres resources.

```bash
kubectl apply -f https://github.com/ansible/apme-operator/releases/download/v0.1.0/install.yaml
kubectl get apme -n apme
```

`aap-demo enable apme-eap` uses the kubeconfig resolved from `KUBECONFIG` or
`~/.aap-demo/kubeconfig.microshift`. AAP is still required as the portal's OAuth/API backend,
but it is not used to run the deployment.

See [ADR-023](../../docs/adr/023-apme-openshift-template.md) for the full decision record.

### Optional Route TLS

Place PEM files in `~/.aap-demo/apme-eap-tls/` (`tls.crt`, `tls.key`, optional `ca.crt`, `dest-ca.crt`) before deploy.

### GitHub integration

| Mode | Default | Configuration |
| ---- | ------- | ------------- |
| PAT + OAuth | Yes | Prompt or `GITHUB_TOKEN` / `GITHUB_OAUTH_*` in cred file |
| GitHub App (push/PR) | No | See **Advanced configuration → GitHub App** below |

## Quick Start

### Prerequisites

**System requirements:**

- `kubectl` or `oc`
- `python3` (3.8+)
- `yq` (mikefarah/yq; installed automatically on macOS and Linux when Homebrew,
  dnf, or apt is available)
- `curl` and `jq`
- AAP deployed (`aap-demo deploy`) for portal OAuth/API integration

The addon deploys a **pre-built portal hub image** (`quay.io/cferman/portal-hub-eap:latest`)
with APME plugins baked in at build time. Deploy does **not** push OCI plugin archives,
run `install-dynamic-plugins` on the host, or require `skopeo` or the in-cluster registry addon.

**Host does not need Helm or a full Ansible install** — OpenShift Template processing runs locally.

### No Manual Configuration Required! 🎉

The addon **automatically discovers** your aap-demo environment (KUBECONFIG, cluster domain,
AAP credentials). No manual setup needed!

### Automation Hub (setup-pah)

For certified collection access and the repositories **catalog** view, configure hub credentials
**before** or **alongside** apme-eap deploy:

```bash
# console.redhat.com offline token → ~/.aap-demo/galaxy-token
aap-demo enable setup-pah

# optional external PAH → ~/.aap-demo/pah-config.yml
aap-demo enable apme-eap
```

When credential files exist, apme-eap automatically on the **host**:

- Runs `setup-pah` to configure rh-certified / validated remotes on AAP
- Passes credential flags into the job for portal `pahCollections` catalog sync
- Seeds APME `/settings/galaxy-servers` from inside the job

See [collection authentication](../../docs/collection-authentication.md).

### Deploy

```bash
aap-demo enable apme-eap
```

This will:

1. Check prerequisites (kubectl, python3, curl, jq)
2. Auto-discover cluster domain, AAP route, and admin password
3. Run **setup-pah** on the host when `~/.aap-demo/galaxy-token` or `pah-config.yml` exists
4. Install the APME operator and wait for its CRD/controller
5. Apply the `Apme` resource and wait for APME readiness
6. Deploy the portal and configure its internal APME gateway connection

Override the EE image:

```bash
APME_EE_IMAGE=quay.io/yourorg/custom-ee:1.0.0 aap-demo enable apme-eap
```

### Check Status

```bash
aap-demo status        # Shows APME in addons section
kubectl get pods -n apme
kubectl get route -n apme
# AAP remains the OAuth/API backend; inspect APME with `kubectl get pods -n apme`
```

### Undeploy

```bash
aap-demo disable apme-eap
```

This removes the APME namespace and generated vars/params files but preserves GitHub credentials.

**Clean re-test cycle** (remove saved GitHub creds and private key):

```bash
aap-demo disable apme-eap --purge-creds
# or non-interactive:
APME_PURGE_CREDS=true aap-demo disable apme-eap
```

When run interactively, disable also prompts to remove saved credentials.

## Architecture

### Runtime resources

The operator creates the APME engine, gateway, and Postgres resources in the `apme` namespace.
The portal is deployed separately in that namespace. AAP is external to this deployment and is
used only for OAuth and Ansible API access.

### Welcome Pack Roles

The addon uses these roles from the official APME welcome pack:

1. **openshift_apme_setup** - Creates namespace and scaffolder ConfigMap
2. **apme_pah_integration** - setup-pah remotes, PAH catalog sync flags, APME galaxy seeding
3. **aap_apme_prerequisites** - Creates AAP OAuth app, generates API token
4. **apme_helm_values** - Generates Helm values for the pre-built portal hub image
5. **apme_scm_secrets** - Creates GitHub OAuth/App secrets (optional)
6. **portal_helm_install** - Installs Red Hat Developer Hub Helm chart
7. **apme_gateway_helm** - Installs APME gateway Helm chart

### Deployment Flow

```
aap-demo enable apme-eap
    ↓
deploy.sh (local CLI)
  - Resolve ~/.aap-demo/kubeconfig.microshift
  - setup-pah on host (if credentials exist)
  - Install APME operator and apply Apme resource
  - Deploy portal from the OpenShift template
  - Configure portal → apme-gateway:8080
    ↓
Portal route ready — login via AAP OAuth
```

## Configuration

### Auto-Discovered Values

The deploy.sh wrapper automatically discovers:

- **openshift_api_url** - From kubeconfig
- **openshift_cluster_domain** - From console route or AAP route
- **aap_host** - From AAP route in aap-operator namespace
- **aap_username** - Fixed: `admin`
- **aap_password** - From AAP secret
- **openshift_project_name** - Fixed: `apme`

These are used to configure the portal during deployment; the direct flow does not generate an
AAP job vars file.

### GitHub Integration (Manual Configuration)

To enable repository quality scanning, edit the generated vars file:

```bash
vim ~/.aap-demo/apme-eap-vars.yml
```

Uncomment and fill in the GitHub section:

```yaml
configure_github_secrets: true
github_oauth_client_id: "YOUR_OAUTH_CLIENT_ID"
github_oauth_client_secret: "YOUR_OAUTH_CLIENT_SECRET"
github_app_id: "YOUR_APP_ID"
github_app_client_id: "YOUR_APP_CLIENT_ID"
github_app_client_secret: "YOUR_APP_CLIENT_SECRET"
github_app_private_key_path: "/path/to/private-key.pem"
github_token: "YOUR_PERSONAL_ACCESS_TOKEN"
```

Then re-run:

```bash
aap-demo enable apme-eap
```

For detailed GitHub setup instructions, see the [APME EAP welcome pack documentation](https://drive.google.com/drive/folders/146Yc3TDKgX0l7k1etdJVXZ2NqhBvPuqr).

### Advanced Configuration

Edit `~/.aap-demo/apme-eap-vars.yml` to customize:

- **portal_hub_image** - Override pre-built portal hub image (default: `quay.io/cferman/portal-hub-eap:latest`)
- **apme_pah_run_setup_pah** - Run `setup-pah` when `~/.aap-demo/galaxy-token` exists (default: `true`)
- **apme_pah_seed_apme_galaxy_servers** - POST AAP/community galaxy servers to APME gateway (default: `true`)
- **apme_pah_collections_enabled** - `auto` | `true` | `false` for portal PAH catalog sync (default: `auto`)
- **portal_helm_chart_version** - Override RHDH chart version
- **apme_helm_chart_version** - Override APME gateway chart version
- **devspaces_base_url** - Enable "Open in DevSpaces" actions

## Advanced configuration

### GitHub App (optional)

For portal push branch and PR creation from Quality workflows, configure a GitHub App in addition to a PAT:

1. Create a GitHub App at https://github.com/settings/apps/new
2. Callback URL: `https://redhat-rhaap-portal-apme.<cluster-domain>/api/auth/github/handler/frame`
3. Permissions: Contents and Pull requests (read/write)
4. Save credentials to `~/.aap-demo/apme-eap-github-creds.yml` with `github_app_*` fields
5. Set `configure_github_app_secrets: true` in `~/.aap-demo/apme-eap-vars.yml` or include App fields in the cred file
6. Re-run `aap-demo enable apme-eap`

Verify: `kubectl get secret secrets-scm -n apme`

## Differences from Bash Addon

| Feature | Bash Addon | Playbook Addon |
|---------|------------|----------------|
| Implementation | Pure bash (~1,180 lines) | Ansible playbooks + bash wrapper (~300 lines) |
| Upstream alignment | Custom logic | Official APME welcome pack roles |
| Configuration | Hardcoded in script | Ansible vars file (editable) |
| Maintainability | Single script | Structured roles |
| Prerequisites | kubectl, helm, gh | kubectl, python3, curl, jq |
| Plugin delivery | Pre-built portal hub image | Same |

## File Structure

```
addons/apme-eap/
├── deploy.sh                     # Bash wrapper (AAP REST API orchestration)
├── ../portal/deploy.yaml         # Shared portal OpenShift Template (PostgreSQL + RHDH)
├── deploy-apme.yaml              # APME engine extension template
├── lib.sh                        # AAP project/EE/job template helpers
├── defaults.yml                  # Default configuration
├── README.md                     # This file
├── playbooks/
│   ├── deploy_apme_portal.yml    # Main deployment playbook (runs in AAP EE)
│   └── roles/
│       ├── apme_template_deploy/
│       ├── aap_apme_prerequisites/
│       ├── apme_pah_integration/
│       └── apme_scm_secrets/
├── execution-environment/        # Optional custom EE (default: Product Demos EE)
└── plugin_packs/                 # Deprecated (reference OCI packs only)
```

## Pre-built hub architecture

See **[ADR-022: APME Pre-Built Portal Hub Deployment](../../docs/adr/022-apme-prebuilt-portal-hub.md)**
for the full decision record: init contract, plugin trees, API factory wiring, incident log, and
verification checklist. Read this before changing hub image builds or `apme_helm_values` tasks.

## Troubleshooting

Quick fixes below; root causes and anti-patterns are documented in ADR-022.

### Git Repositories catalog: blank page or `scrollWidth` TypeError

**Symptom**: `/self-service/repositories/catalog` shows
`Cannot read properties of null (reading 'scrollWidth')` or a blank table.

**Cause**: Two issues can affect Git Repositories:

1. **Init copied `/pre-installed/` then ran `install-dynamic-plugins`**, which removed APME
   plugins during cleanup (GitHub sign-in fallback). Init must only run
   `install-dynamic-plugins` — do not copy `/pre-installed/dynamic-plugins-root/` first.
2. **Catalog table (`@material-table/core` + React 18)**: `scrollWidth` TypeError on
   `/self-service/repositories/catalog`. Init patches served `dist-scalprum` bundles after
   install (not the full plugin source tree).

**Pre-built hub plugin trees**:

| Path | Role |
| ---- | ---- |
| `/opt/app-root/src/dynamic-plugins/dist/ansible-portal/` | Baked source packages (`install-dynamic-plugins` input) |
| `/opt/app-root/src/dynamic-plugins-root/` | Writable volume; scalprum serves `dist-scalprum/static/` |

**Solution**: Redeploy with current `apme-eap` playbooks (init runs `install-dynamic-plugins`
from local baked paths). Hard-refresh the browser after redeploy so cached chunks are not reused.

### Git Repositories: `NotImplementedError: apiRef{plugin.apme.api}`

**Symptom**: Git Repositories or Self Service pages throw `No implementation available for apiRef{plugin.apme.api}`.

**Cause**: `ansible.plugin-backstage-apme` exports two API factories. Config must register both
`apmeApiFactory` (core APME client API) and `gitRepositoriesExtensionsApiFactory` (catalog UI
extensions). Registering only the extensions factory leaves `plugin.apme.api` unbound.

**Solution**: Redeploy with current `apme-eap` playbooks (values template includes both
factories). Hard-refresh the browser after redeploy.

### python3 missing on host

**Symptom**: `python3 not found` when loading GitHub credentials from YAML

**Solution**:

```bash
# macOS
brew install python3

# Verify
python3 --version  # Should be 3.8 or later
```

### Ansible collection missing (AAP job)

**Symptom**: `ERROR! couldn't resolve module/action 'kubernetes.core.k8s'`

**Cause**: Job template not using Product Demos EE, or EE image missing `kubernetes.core`

**Solution**:

```bash
# Re-register EE and relaunch (uses Product Demos EE by default)
aap-demo enable apme-eap

# Or override EE image
APME_EE_IMAGE=quay.io/ansible-product-demos/apd-ee-26:latest aap-demo enable apme-eap
```

### Playbook fails with "AAP route not found"

**Symptom**: `AAP route not found. Deploy AAP first`

**Solution**: Deploy AAP before enabling this addon:

```bash
aap-demo deploy
aap-demo status  # Verify AAP is running
aap-demo enable apme-eap
```

### OAuth app creation fails

**Symptom**: Playbook fails during `aap_apme_prerequisites` role

**Solution**: Check AAP credentials:

```bash
kubectl get secret -n aap-operator <aap-cr-name> -o jsonpath='{.data.admin_password}' | base64 -d
# Verify password works by logging into AAP web UI
```

### Portal OAuth login fails (`fetch failed`)

**Symptom**: AAP username/password sign-in works, but portal OAuth returns
`Login failed; caused by Error: Failed to send POST request: fetch failed`

**Cause**: On MicroShift/CRC, the portal backend must POST to `https://<aap-route>/o/token/`.
with a `hostAliases` entry mapping the route hostname to the AAP Service ClusterIP.
External route hostnames (`apps.crc.testing`, `nip.io`) do not resolve correctly inside pods.

**Fix**: Re-run `aap-demo enable apme-eap`. On MicroShift the addon sets `aap_host_url` to
`https://<aap-route>` and patches `hostAliases` on the portal Deployment.

After deploy, `aap-demo enable apme-eap` runs automatic OAuth verification (AAP host URL,
host alias, token endpoint reachability). If verification fails, re-run the enable command.
Use `aap-demo diagnose` to check whether the CoreDNS route rewrite rule is configured.

Verify from the portal pod:

```bash
kubectl exec deploy/redhat-rhaap-portal -c backstage-backend -n apme -- printenv AAP_HOST_URL
# MicroShift expected: http://aap-aap-operator.apps.crc.testing (or *.nip.io)

kubectl exec deploy/redhat-rhaap-portal -c backstage-backend -n apme -- \
  getent hosts aap-aap-operator.apps.crc.testing
```

### Portal hub image pull fails

**Symptom**: Portal pod stays in `ImagePullBackOff`

**Solution**:

1. Verify the image is reachable: `podman pull quay.io/cferman/portal-hub-eap:latest`
2. Override in `~/.aap-demo/apme-eap-vars.yml`: `portal_hub_image: "your-registry/portal-hub-eap:tag"`
3. Re-deploy: `aap-demo enable apme-eap`

### Helm not installed

**Symptom**: Playbook fails with `Failed to find required executable 'helm'` or `helm: command not found`

**Solution**: Re-run enable — helm is auto-installed when Homebrew (`brew`) or `dnf` is available:

```bash
aap-demo enable apme-eap
```

Or install manually:

```bash
# macOS
brew install helm

# RHEL/Fedora
sudo dnf install helm
```

Verify: `helm version --short` (requires 3.10+).

### Helm timeout

**Symptom**: Helm install times out waiting for pods

**Solution**:

```bash
# Check pod status
kubectl get pods -n apme

# Check events
kubectl get events -n apme --sort-by='.lastTimestamp'

# Common fix: resource constraints
kubectl describe pod -n apme <pod-name>
```

### GitHub secrets not working

**Symptom**: Repository registration fails or Quality tab missing

**Solution**:

1. Verify secrets-scm exists: `kubectl get secret secrets-scm -n apme`
2. Check secret keys: `kubectl get secret secrets-scm -n apme -o jsonpath='{.data}' | jq 'keys'`
3. Re-enable with `configure_github_secrets: true` in vars file
4. Redeploy: `aap-demo enable apme-eap`

## Post-Deployment Steps

### 1. Verify Deployment

**ARM (RHDH portal)**:

```bash
kubectl get route -n apme
# Open the route URL in browser
```

**x86 (APME gateway)**:

```bash
kubectl port-forward -n apme deploy/apme-gateway 8080:8080
# Open http://localhost:8080
```

### 2. Sign In

Use AAP admin credentials (same as AAP web UI).

### 3. Register Repository

1. Navigate to **Self-service** → **Register Git repository**
2. Select owner/org and repository
3. Confirm default branch
4. Verify repository appears in catalog

### 4. Run Quality Scan

1. Open registered repository
2. Select **Quality** tab
3. Start scan → Generate fixes → Push branch → Create PR

## Advanced Topics

### Using a Custom Portal Hub Image

APME plugins are baked into the portal hub container at build time. To use a different build:

1. Build and publish a `portal-hub-eap` image with APME plugins under `dynamic-plugins/dist/ansible-portal/`
2. Optionally add `/pre-installed/dynamic-plugins-root/` for faster init staging
3. Set `portal_hub_image` in `~/.aap-demo/apme-eap-vars.yml`
4. Re-deploy: `aap-demo enable apme-eap`

### Debugging Playbook Execution

Run the playbook with verbose output:

```bash
cd addons/apme-eap
ansible-playbook playbooks/deploy_apme_portal.yml \
  -e @~/.aap-demo/apme-eap-vars.yml \
  -vvv
```

### Manual Playbook Execution

You can run the playbook directly without the wrapper:

```bash
cd addons/apme-eap

# Edit vars file manually
vim ~/.aap-demo/apme-eap-vars.yml

# Run playbook
ansible-playbook playbooks/deploy_apme_portal.yml \
  -e @~/.aap-demo/apme-eap-vars.yml \
  -e @defaults.yml
```

## References

- [APME EAP Welcome Pack](https://drive.google.com/drive/folders/146Yc3TDKgX0l7k1etdJVXZ2NqhBvPuqr) -
  Official APME deployment documentation
- [aap-demo Documentation](../../docs/FULL-README.md) - Main aap-demo documentation
- [APME GitHub Repository](https://github.com/ansible/apme) - APME source code
- [APME Plugins Repository](https://github.com/ansible/ansible-rhdh-plugins) - RHDH plugins for APME
