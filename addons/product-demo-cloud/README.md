# Product Demo - Cloud

Cloud infrastructure and provisioning demonstrations from the Ansible Product Demos collection.

## What it Creates

Job templates for cloud automation scenarios:

- **CLOUD | Create VPC** - AWS VPC provisioning
- **CLOUD | Create VM** - EC2 instance creation
- **CLOUD | AWS EC2 Management** - Instance lifecycle management
- **CLOUD | Patch Compliance Report** - Cloud infrastructure patching
- AWS infrastructure automation workflows

## Usage

```bash
# Install Cloud demos (also installs base if needed)
aap-demo enable product-demo-cloud

# Remove Cloud demos
aap-demo disable product-demo-cloud
```

## Prerequisites

- AAP deployed via `aap-demo deploy`
- Product demos base addon (automatically installed)
- AWS account credentials

## Configuration

After installation, configure in AAP UI:

1. **AWS Credential**:
   - Navigate to Credentials in APD organization
   - Update "AWS" credential with your AWS access key and secret key

2. **Run Cloud Provisioning Demos**:
   - Job templates will provision resources in your AWS account
   - Be aware of potential costs for running cloud resources

## Resources

- [Cloud Demos Documentation](https://ansible.github.io/product-demos/cloud/)
- [Product Demos Repository](https://github.com/ansible/product-demos)
