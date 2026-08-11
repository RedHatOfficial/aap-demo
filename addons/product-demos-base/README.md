# Product Demos Base Addon

This addon installs the foundation for Ansible Product Demos (APD) in your AAP environment.

## What it Creates

- **Organization**: "Ansible Product Demos (APD)"
- **Project**: "Ansible Product Demos" (cloned from https://github.com/ansible/product-demos)
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
aap-demo enable product-demos   # base + linux, windows, network, cloud, openshift, satellite
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
   - Update "OpenShift Credential" for OpenShift/Kubernetes demos

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

This addon uses the official `install-apd.yml` playbook from the ansible/product-demos repository. It:

1. Auto-installs `ansible-navigator` if needed
2. Clones the product-demos repository to a temporary directory
3. Extracts AAP admin credentials from the cluster
4. Runs the installation playbook using the APD execution environment
5. Cleans up the temporary directory

Domain-specific addons (linux, windows, network, etc.) build on this foundation by
running their respective `setup.yml` playbooks.

## Troubleshooting

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
