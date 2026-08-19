# Product Demos Base Addon

This addon installs the foundation for Ansible Product Demos (APD) in your AAP environment.

## What it Creates

- **Organization**: "Ansible Product Demos (APD)" — created by the install job dispatch
- **Bootstrap project**: "APD Bootstrap Project" (Default org) — SCM source for `install-apd.yml`
  and domain `setup_demo.yml` runs
- **APD project**: "Ansible Product Demos" (APD org) — created inside the APD organization by the install job
- **Execution Environment**: Product Demos EE (`quay.io/ansible-product-demos/apd-ee-26:latest`)
- **Inventory**: "Ansible Product Demos Inventory"
- **Credentials**:
  - AAP Credential (for managing AAP itself)
  - Galaxy/Automation Hub credentials (requires configuration)
  - Machine credential (SSH/WinRM, requires configuration)
  - OpenShift credential (requires configuration)
  - AWS credential (requires configuration)
- **Job Templates**:
  - "APD | Single demo setup" - Configure one demo category at a time
  - "APD | Multi-demo setup" - Configure multiple demo categories

## Usage

### Installation

Install all demo domains at once:

```bash
aap-demo enable product-demos   # base + linux, windows, network, cloud, openshift (Satellite opt-in)
```

Or install the foundation only (required automatically by domain addons):

```bash
aap-demo enable product-demos-base
```

Or install a single domain:

```bash
aap-demo enable product-demo-linux
```

### Requirements

The addon will automatically install `ansible-navigator` if it's not already present. It requires either:

- `pipx` (recommended for isolated installation), or
- `pip3` (for user-level installation)

Network access is required to:

- Clone the product-demos repository
- Pull the APD execution environment image from quay.io

### Configuration

After installation, you'll need to configure some credentials in the AAP UI:

1. **Galaxy/Automation Hub Tokens** (for downloading certified/validated content):
   - Log into AAP UI
   - Navigate to Credentials
   - Update "Automation Hub Certified Content" and "Automation Hub Validated Content"
   - Add your Red Hat automation hub tokens

2. **Machine Credential** (for connecting to managed nodes):
   - Update "APD Machine Credential"
   - Add SSH keys and/or passwords for your target systems

3. **Cloud Credentials** (optional, for cloud demos):
   - Update "AWS" credential with your AWS access keys
   - **OpenShift Credential** is auto-configured for local MicroShift when you
     enable `product-demo-openshift` (uses in-cluster API + your `oc` token)

### Custom Repository

To use a forked or customized version of product-demos:

```bash
PRODUCT_DEMOS_REPO=https://github.com/myorg/product-demos \
PRODUCT_DEMOS_BRANCH=custom \
  aap-demo enable product-demos-base
```

### Removal

To remove the base addon, first disable all domain-specific addons:

```bash
aap-demo disable product-demo-linux
aap-demo disable product-demo-windows
# ... disable all enabled domains
aap-demo disable product-demos-base
```

Note: The addon tracks enabled domains and will prevent removal if any are still active.

## Architecture

aap-demo targets **AAP 2.7 only**. The installer does not discover the AAP version at runtime.

1. Creates a **bootstrap project** in the Default organization, synced from ansible/product-demos
2. Overlays `install-apd-aap-demo.yml` on the controller task pod (no gateway version ping) and
   patches `install-apd.yml` for manual runs
3. Pins `_aap_version: "2.7"` and the Product Demos EE image in job template extra_vars
4. Runs the install job inside the Product Demos EE via AAP job template
5. The install job creates the **APD organization**, its own "Ansible Product Demos" project,
   inventory, credentials, and setup job templates

The bootstrap project and the APD org project both clone the same upstream repository but serve
different roles: bootstrap is the SCM source for installer and domain-setup jobs in Default org;
the APD org project is managed by APD dispatch for demo content.

**Ephemeral patch:** The `install-apd.yml` patch is written directly into the synced project
directory on the controller task pod. A manual project sync in the AAP UI restores upstream
content and removes the version-ping skip. Re-run `aap-demo enable product-demos-base` to
re-sync, re-patch, and reinstall.

Upstream `install-apd.yml` queries `/api/gateway/v1/ping/` to set `_aap_version` for generic
installs. aap-demo replaces that with a pinned version because the deployed platform is always
2.7 and the EE is registered explicitly (`PRODUCT_DEMOS_EE`). Setting `_aap_version` in job
extra_vars alone is not sufficient — the patched playbook file is required.

See [`patches/install-apd.yml`](patches/install-apd.yml) for the upstream PR candidate that adds
`when: _aap_version is not defined` to the ping task.

Domain-specific addons (`product-demo-linux`, etc.) launch the same per-domain AAP job
templates — they do **not** run `setup_demo.yml` locally. The Product Demos EE provides
`infra.aap_configuration` inside the cluster.

## Troubleshooting

### Job template creation fails (`Playbook not found for project`)

AAP 2.7 validates job template playbooks against the project's SCM playbook index
(`playbook_files`), not just files on the controller task pod. `install-apd-aap-demo.yml` is an
aap-demo overlay and is not in upstream `ansible/product-demos`; the deploy script registers it
in the project catalog after copying it onto the task pod.

If you see this error on an older deploy script, re-run on the latest branch:

```bash
aap-demo enable product-demos-base
```

Or use the upstream playbook name (patched on disk, version ping skipped via extra vars):

```bash
APD_INSTALL_PLAYBOOK=install-apd.yml aap-demo enable product-demos-base
```

### Version ping timeout (`Query AAP version from the API`)

If a job fails pinging `https://…nip.io/api/gateway/v1/ping/` from inside a job pod, the
bootstrap project is still using upstream `install-apd.yml` (no skip) or the job template
playbook is not `install-apd-aap-demo.yml`.

The deploy script overlays `install-apd-aap-demo.yml` on the **controller task pod** and
launches with `_aap_version: "2.7"` in extra vars. It aborts before launching if the overlay
cannot be applied.

If an install job still hits this task:

1. Confirm **APD | Install Base Resources** uses playbook `install-apd-aap-demo.yml` (not
   `install-apd.yml`).
2. Re-run `aap-demo enable product-demos-base` on the latest branch (do not manually sync the
   bootstrap project in the UI first).
3. Confirm installer credential **APD Installer - AAP Admin** uses `http://` route hostname on
   CRC/MicroShift (`…nip.io`), not `https://`.

### ansible-navigator installation fails

If automatic installation fails, install manually:

```bash
# Using pipx (recommended)
pipx install ansible-navigator

# Or using pip3
pip3 install --user ansible-navigator

# Add to PATH if needed (pip3 user install)
export PATH="$HOME/.local/bin:$PATH"
```

### Cannot clone repository

- Check network connectivity
- Verify the repository URL and branch exist
- For private forks, ensure git credentials are configured

### Image pull failures

The APD execution environment (`quay.io/ansible-product-demos/apd-ee-26:latest`) is public, but ensure:

- Podman or Docker is running
- Network access to quay.io is available

### Playbook execution fails

- Check the ansible-navigator output for specific errors
- Verify AAP is fully deployed and accessible
- Check AAP admin credentials are correct

### Duplicate Ansible Product Demos project / domain setup fails

If `setup_demo.yml` fails with `projects/?name=Ansible+Product+Demos returned 2 items,
expected 1`, the Default org has a stray project with the same name as the APD org project.

Re-run `aap-demo enable product-demos` (or a single domain template) — deploy removes duplicate
Default org projects after each domain job. The bootstrap SCM project is named
**APD Bootstrap Project** to avoid colliding with the APD org project.

### Satellite domain fails after bulk install

The Satellite domain creates demo templates but **SETUP | Satellite** calls your Satellite API
using placeholder credentials until you update them. That failure is expected without a real
Satellite server.

Update credentials and re-run setup — see [`../product-demo-satellite/README.md`](../product-demo-satellite/README.md).

## Related Addons

Domain-specific addons that depend on this base:

- `product-demo-linux` - RHEL and Linux automation demos
- `product-demo-windows` - Windows Server automation demos
- `product-demo-network` - Network automation demos
- `product-demo-cloud` - Cloud provisioning demos
- `product-demo-openshift` - OpenShift automation demos
- `product-demo-satellite` - Red Hat Satellite demos

## Resources

- [Ansible Product Demos Repository](https://github.com/ansible/product-demos)
- [APD Documentation](https://ansible.github.io/product-demos/)
- [ansible-navigator Documentation](https://ansible.readthedocs.io/projects/navigator/)
