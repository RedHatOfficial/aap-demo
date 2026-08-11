# Product Demo - Linux

Linux and RHEL automation demonstrations from the Ansible Product Demos collection.

## What it Creates

Job templates for Linux automation scenarios:

- **LINUX | Register with Insights** - Register systems with Red Hat Insights
- **LINUX | Fact Scan** - Gather system facts
- **LINUX | Patching** - Automated patch management
- **LINUX | Hardening** - Security hardening with DISA STIG
- **LINUX | System Roles** - RHEL system roles automation
- **LINUX | Podman** - Container management with Podman
- **LINUX | Troubleshooting** - Common troubleshooting workflows
- **LINUX | Deploy Application** - Application deployment
- **LINUX | Service Management** - Start/stop services
- And more...

## Usage

```bash
# Install Linux demos (also installs base if needed)
aap-demo enable product-demo-linux

# Remove Linux demos
aap-demo disable product-demo-linux
```

## Prerequisites

- AAP deployed via `aap-demo deploy`
- Product demos base addon (automatically installed)
- Network access to clone https://github.com/ansible/product-demos

## Configuration

After installation, configure these credentials in AAP UI:

1. **Insights Inventory Credential**:
   - Navigate to Credentials in APD organization
   - Update "Insights Inventory" with your Red Hat account credentials
   - Required for: Insights integration demos

2. **APD Machine Credential**:
   - Add SSH keys for connecting to Linux hosts
   - Required for: Most demo templates

3. **Add Linux Hosts to Inventory**:
   - Navigate to Inventories > "Ansible Product Demos Inventory"
   - Add your RHEL/Linux hosts
   - Or use the Insights inventory source

## Demo Scenarios

### Patching Workflow

Demonstrates a complete patch management cycle with pre-checks, patching, and rollback capabilities.

### Security Compliance

Shows DISA STIG hardening and compliance scanning with Insights.

### System Roles

Uses Red Hat Enterprise Linux system roles for consistent configuration management.

### Container Management

Podman-based container deployment and management on RHEL.

## Resources

- [Linux Demos Documentation](https://ansible.github.io/product-demos/linux/)
- [Product Demos Repository](https://github.com/ansible/product-demos)
