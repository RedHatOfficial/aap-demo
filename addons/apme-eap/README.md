# APME Playbook Addon

Deploy Ansible Portal with Ansible Quality (APME) on OpenShift Local (MicroShift) using **official APME EAP welcome pack Ansible playbooks** executed locally in an isolated Python virtual environment.

> **Preview:** APME is prototype software for the Early Access Program. Confidential — Red Hat associate and NDA partner use only.

## Overview

This addon uses the **official APME EAP welcome pack playbooks** executed locally via `ansible-playbook`. This implementation:

- **Local execution**: Playbooks run in isolated Python venv (no AAP API dependency)
- **KUBECONFIG authentication**: Uses standard kubeconfig for cluster access  
- Uses structured Ansible roles from the official APME welcome pack
- Auto-discovers aap-demo environment (no manual configuration)
- Maintains alignment with upstream APME deployment patterns

**Architecture:** Bash wrapper (`deploy.sh`) handles environment discovery and generates vars file, then invokes official APME playbooks via `ansible-playbook` with KUBECONFIG-based authentication.

## Quick Start

### Prerequisites

**System requirements**:
- `kubectl` or `oc`
- `python3` (3.8+)
- AAP deployed (`aap-demo deploy`)

**Ansible installation** (auto-installed in venv):
- A venv is created at `~/.aap-demo/apme-eap-venv` with full Ansible suite + collections
- Includes kubernetes.core, community.okd, and other required collections
- The playbooks run locally using KUBECONFIG authentication (~150 MB venv)

### No Manual Configuration Required! 🎉

The addon **automatically discovers** your aap-demo environment (KUBECONFIG, cluster domain, AAP credentials). No manual setup needed!

### Deploy

```bash
aap-demo enable apme-eap
```

This will:
1. Check system prerequisites (kubectl, python3)
2. Create venv with full Ansible + collections (if not exists)
3. Auto-discover your aap-demo environment (KUBECONFIG, cluster domain, AAP route/credentials)
4. Generate playbook vars at `~/.aap-demo/apme-eap-vars.yml`
5. Run `playbooks/deploy_apme_portal.yml` directly via ansible-playbook

**Authentication:** The playbooks use KUBECONFIG (client certificate auth) to interact with the cluster. The `K8S_AUTH_KUBECONFIG` environment variable is set automatically by the wrapper script.

**First run** takes longer (~2-3 minutes) to set up the virtual environment and install Ansible collections. Subsequent runs reuse the existing venv and are faster.

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

This removes the APME namespace but preserves the virtual environment for future use.

**To completely remove everything** (including venv):
```bash
aap-demo disable apme-eap
rm -rf ~/.aap-demo/apme-eap-venv
```

## Architecture

### Welcome Pack Roles

The addon uses these roles from the official APME welcome pack:

1. **openshift_apme_setup** - Creates namespace, grants SCCs, copies pull secrets
2. **aap_apme_prerequisites** - Creates AAP OAuth app, generates API token
3. **apme_oci_push** - Deploys in-cluster plugin registry, pushes plugins via skopeo
4. **apme_helm_values** - Generates Helm values for portal configuration
5. **apme_scm_secrets** - Creates GitHub OAuth/App secrets (optional)
6. **portal_helm_install** - Installs Red Hat Developer Hub Helm chart
7. **apme_gateway_helm** - Installs APME gateway Helm chart (x86 only)

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
  2. aap_apme_prerequisites
  3. apme_oci_push
  4. apme_helm_values
  5. apme_scm_secrets (if enabled)
  6. portal_helm_install
  7. apme_gateway_helm (x86 only)
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

- **portal_helm_chart_version** - Override RHDH chart version
- **apme_helm_chart_version** - Override APME gateway chart version
- **apme_oci_push_force** - Set `true` to re-push plugins even if already in registry
- **devspaces_base_url** - Enable "Open in DevSpaces" actions

## Differences from Bash Addon

| Feature | Bash Addon | Playbook Addon |
|---------|------------|----------------|
| Implementation | Pure bash (~1,180 lines) | Ansible playbooks + bash wrapper (~300 lines) |
| Upstream alignment | Custom logic | Official APME welcome pack roles |
| Configuration | Hardcoded in script | Ansible vars file (editable) |
| Maintainability | Single script | Structured roles |
| Prerequisites | kubectl, helm, skopeo, gh | ansible-playbook + same tools |
| Update process | Rewrite bash logic | Copy new welcome pack |
| GitHub CI download | Built-in (ARM) | Uses bundled plugin pack |

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
│   ├── apme_oci_push/
│   ├── apme_helm_values/
│   ├── apme_scm_secrets/
│   ├── portal_helm_install/
│   └── apme_gateway_helm/
└── plugin_packs/
    └── *.oci.tar.gz              # Bundled APME plugins
```

## Troubleshooting

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

### Plugin push fails (ARM)

**Symptom**: skopeo copy fails during `apme_oci_push` role

**Solution**:
1. Check port-forward to plugin registry is working
2. Verify skopeo is installed: `which skopeo`
3. Check plugin registry pod is running: `kubectl get pods -n apme -l app=plugin-registry`

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

### Using Custom Plugin Builds

To use a different APME plugin build:

1. Download OCI artifact from GitHub Actions
2. Replace `plugin_packs/*.oci.tar.gz` with your artifact
3. Re-deploy: `aap-demo enable apme-eap`

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

- [APME EAP Welcome Pack](https://drive.google.com/drive/folders/146Yc3TDKgX0l7k1etdJVXZ2NqhBvPuqr) - Official APME deployment documentation
- [aap-demo Documentation](../../docs/FULL-README.md) - Main aap-demo documentation
- [APME GitHub Repository](https://github.com/ansible/apme) - APME source code
- [APME Plugins Repository](https://github.com/ansible/ansible-rhdh-plugins) - RHDH plugins for APME
