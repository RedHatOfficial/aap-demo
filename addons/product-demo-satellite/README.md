# Product Demo - Satellite

Red Hat Satellite integration demonstrations from the Ansible Product Demos collection.

## What it Creates

Job templates for Satellite automation scenarios:
- **SATELLITE | Server Registration** - Register systems to Satellite
- **SATELLITE | Promote Content** - Content view promotion
- **SATELLITE | Publish Content View** - Content view publishing
- **SATELLITE | OpenSCAP Scan** - Security compliance scanning
- Satellite lifecycle management workflows

## Usage

```bash
# Install Satellite demos (also installs base if needed)
aap-demo enable product-demo-satellite

# Remove Satellite demos
aap-demo disable product-demo-satellite
```

## Prerequisites

- AAP deployed via `aap-demo deploy`
- Product demos base addon (automatically installed)
- Red Hat Satellite server

## Configuration

After installation, configure in AAP UI:

1. **Satellite Server Setup**:
   - Configure connectivity to your Satellite server
   - May require additional credentials for Satellite API access

2. **Run Satellite Demos**:
   - Job templates integrate with Satellite for content management

## Resources

- [Satellite Demos Documentation](https://ansible.github.io/product-demos/satellite/)
- [Product Demos Repository](https://github.com/ansible/product-demos)
