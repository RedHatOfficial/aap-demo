# Product Demo - Windows

Windows Server automation demonstrations from the Ansible Product Demos collection.

## What it Creates

Job templates for Windows automation scenarios:

- **WINDOWS | Patching** - Windows Update management
- **WINDOWS | Compliance** - Security compliance checking
- **WINDOWS | Install IIS** - IIS web server deployment
- **WINDOWS | PowerShell DSC** - Desired State Configuration
- **WINDOWS | Create AD Domain** - Active Directory domain controller setup
- **WINDOWS | Join AD Domain** - Domain joining workflow
- **WINDOWS | Chocolatey** - Package management with Chocolatey
- And more...

## Usage

```bash
# Install Windows demos (also installs base if needed)
aap-demo enable product-demo-windows

# Remove Windows demos
aap-demo disable product-demo-windows
```

## Prerequisites

- AAP deployed via `aap-demo deploy`
- Product demos base addon (automatically installed)
- Windows Server hosts to manage

## Configuration

After installation, configure in AAP UI:

1. **APD Machine Credential**:
   - Add Windows username and password for WinRM connection
   - Required for connecting to Windows hosts

2. **Add Windows Hosts to Inventory**:
   - Navigate to Inventories > "Ansible Product Demos Inventory"
   - Add your Windows Server hosts
   - Ensure WinRM is enabled on target hosts

## Resources

- [Windows Demos Documentation](https://ansible.github.io/product-demos/windows/)
- [Product Demos Repository](https://github.com/ansible/product-demos)
