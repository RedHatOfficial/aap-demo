# Product Demo - Network

Network automation demonstrations from the Ansible Product Demos collection.

## What it Creates

Job templates for network automation scenarios:
- **NETWORK | Backup Running Configs** - Backup device configurations
- **NETWORK | Compliance Check** - Network compliance validation
- **NETWORK | Generate Report** - Network documentation and reporting
- Multi-vendor support (Cisco, Arista, Juniper, etc.)

## Usage

```bash
# Install Network demos (also installs base if needed)
aap-demo enable product-demo-network

# Remove Network demos
aap-demo disable product-demo-network
```

## Prerequisites

- AAP deployed via `aap-demo deploy`
- Product demos base addon (automatically installed)
- Network devices to manage

## Configuration

After installation, configure in AAP UI:

1. **APD Machine Credential**:
   - Add network device credentials (username/password or SSH key)

2. **Add Network Devices to Inventory**:
   - Navigate to Inventories > "Ansible Product Demos Inventory"
   - Add your network devices with appropriate ansible_network_os variables

## Resources

- [Network Demos Documentation](https://ansible.github.io/product-demos/network/)
- [Product Demos Repository](https://github.com/ansible/product-demos)
