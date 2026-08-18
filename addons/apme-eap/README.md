# APME Playbook Addon

Deploy Ansible Portal with Ansible Quality (APME) on OpenShift Local (MicroShift) using
**official APME EAP welcome pack Ansible playbooks** executed locally in an isolated Python
virtual environment.

> **Preview:** APME is prototype software for the Early Access Program.
> Confidential — Red Hat associate and NDA partner use only.

## Overview

This addon uses the **official APME EAP welcome pack playbooks** executed locally via `ansible-playbook`. This implementation:

- **Local execution**: Playbooks run in isolated Python venv (no AAP API dependency)
- **KUBECONFIG authentication**: Uses standard kubeconfig for cluster access
- Uses structured Ansible roles from the official APME welcome pack
- Auto-discovers aap-demo environment (no manual configuration)
- Maintains alignment with upstream APME deployment patterns

**Architecture:** Bash wrapper (`deploy.sh`) handles environment discovery and generates vars
file, then invokes official APME playbooks via `ansible-playbook` with KUBECONFIG-based
authentication.

## Quick Start

### Prerequisites

**System requirements:**

- `kubectl` or `oc`
- `python3` (3.8+)
- `helm` 3.10+ (portal Helm chart — auto-installed via brew/dnf when missing)
- AAP deployed (`aap-demo deploy`)

The addon deploys a **pre-built portal hub image** (`quay.io/cferman/portal-hub-eap:latest`)
with APME plugins baked in at build time. Deploy does **not** push OCI plugin archives,
run `install-dynamic-plugins`, or require `skopeo` or the in-cluster registry addon.

**Ansible installation** (auto-installed in venv):

- A venv is created at `~/.aap-demo/apme-eap-venv` with full Ansible suite + collections
- Includes kubernetes.core, community.okd, and other required collections
- The playbooks run locally using KUBECONFIG authentication (~150 MB venv)

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

When credential files exist, apme-eap automatically:

- Runs `setup-pah` to configure rh-certified / validated remotes on AAP
- Enables portal `pahCollections` catalog sync
- Seeds APME `/settings/galaxy-servers` with AAP Automation Hub (`{AAP}/api/galaxy/`) + community Galaxy
- Writes literal AAP URLs into portal app-config (fixes `/undefined` navigation from unset `${AAP_HOST_URL}`)

See [collection authentication](../../docs/collection-authentication.md).

### Deploy

```bash
aap-demo enable apme-eap
```

This will:

1. Check system prerequisites (kubectl, python3, helm — installs helm if missing)
2. Create venv with full Ansible + collections (if not exists)
3. Auto-discover your aap-demo environment (KUBECONFIG, cluster domain, AAP route/credentials)
4. Run **setup-pah** when `~/.aap-demo/galaxy-token` or `pah-config.yml` exists (configures AAP hub remotes)
5. Generate playbook vars at `~/.aap-demo/apme-eap-vars.yml`
6. Run `playbooks/deploy_apme_portal.yml` with pre-built `portal-hub-eap` container image
7. Seed APME galaxy servers from AAP (+ external PAH when configured) and enable PAH catalog sync

**Authentication:** The playbooks use KUBECONFIG (client certificate auth) to interact with
the cluster. The `K8S_AUTH_KUBECONFIG` environment variable is set automatically by the
wrapper script.

**First run** takes longer (~2-3 minutes) to set up the virtual environment and install
Ansible collections. Subsequent runs reuse the existing venv and are faster.

### Check Status

```bash
aap-demo status        # Shows APME in addons section
kubectl get pods -n apme
kubectl get route -n apme
```

### Undeploy

```bash
aap-demo disable apme-eap
```

This removes the APME namespace and generated vars file but preserves GitHub credentials
and the virtual environment for future use.

**Clean re-test cycle** (remove saved GitHub creds and private key):

```bash
aap-demo disable apme-eap --purge-creds
# or non-interactive:
APME_PURGE_CREDS=true aap-demo disable apme-eap
```

When run interactively, disable also prompts to remove saved credentials.

**To completely remove everything** (including venv):

```bash
aap-demo disable apme-eap --purge-creds
rm -rf ~/.aap-demo/apme-eap-venv
```

## Architecture

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
deploy.sh (bash wrapper)
    ↓
Environment auto-discovery:
  - KUBECONFIG from CRC
  - OpenShift API URL
  - AAP route and credentials
  - Cluster architecture (x86/ARM)
    ↓
Generate vars file:
  ~/.aap-demo/apme-eap-vars.yml
    ↓
ansible-playbook playbooks/deploy_apme_portal.yml
    ↓
Roles execute in sequence:
  1. openshift_apme_setup
  2. apme_pah_integration (setup-pah + galaxy facts)
  3. aap_apme_prerequisites
  4. apme_helm_values (portal-hub-eap image + PAH sync)
  5. apme_scm_secrets (if enabled)
  6. portal_helm_install
  7. apme_gateway_helm
  8. post_tasks: seed APME galaxy servers + portal rollout
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

These are written to `~/.aap-demo/apme-eap-vars.yml` (regenerated on each deploy).

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

## Differences from Bash Addon

| Feature | Bash Addon | Playbook Addon |
|---------|------------|----------------|
| Implementation | Pure bash (~1,180 lines) | Ansible playbooks + bash wrapper (~300 lines) |
| Upstream alignment | Custom logic | Official APME welcome pack roles |
| Configuration | Hardcoded in script | Ansible vars file (editable) |
| Maintainability | Single script | Structured roles |
| Prerequisites | kubectl, helm, gh | ansible-playbook + kubectl, helm |
| Plugin delivery | Pre-built portal hub image | Same |

## File Structure

```
addons/apme-eap/
├── deploy.sh                     # Bash wrapper (addon contract)
├── defaults.yml                  # Default configuration
├── requirements.yml              # Ansible collection dependencies
├── README.md                     # This file
├── playbooks/
│   ├── deploy_apme_portal.yml    # Main deployment playbook
│   ├── tasks/
│   └── templates/
├── roles/
│   ├── openshift_apme_setup/
│   ├── aap_apme_prerequisites/
│   ├── apme_helm_values/
│   ├── apme_scm_secrets/
│   ├── portal_helm_install/
│   └── apme_gateway_helm/
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

### Python venv creation fails

**Symptom**: `python3 not found` or venv module errors

**Solution**:

```bash
# macOS
brew install python3

# Verify
python3 --version  # Should be 3.8 or later
```

### Ansible collection missing

**Symptom**: `ERROR! couldn't resolve module/action 'kubernetes.core.k8s'`

**Cause**: Virtual environment was corrupted or collections install failed

**Solution**:

```bash
# Remove and recreate venv
rm -rf ~/.aap-demo/apme-eap-venv
aap-demo enable apme-eap  # Will recreate venv
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
