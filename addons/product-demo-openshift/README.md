# Product Demo - OpenShift

OpenShift and Kubernetes automation demonstrations from the Ansible Product Demos collection.

## What it Creates

Job templates for OpenShift automation scenarios:
- **OPENSHIFT | Deploy Application** - Application deployment
- **OPENSHIFT | CNV Management** - KubeVirt virtualization management
- **OPENSHIFT | GitLab Setup** - GitLab instance deployment
- **OPENSHIFT | DevSpaces** - OpenShift DevSpaces configuration
- Kubernetes resource management workflows

## Usage

```bash
# Install OpenShift demos (also installs base if needed)
aap-demo enable product-demo-openshift

# Remove OpenShift demos
aap-demo disable product-demo-openshift
```

## Prerequisites

- AAP deployed via `aap-demo deploy`
- Product demos base addon (automatically installed)
- OpenShift or Kubernetes cluster to manage

## Configuration

After installation, configure in AAP UI:

1. **OpenShift Credential**:
   - Navigate to Credentials in APD organization
   - Update "OpenShift Credential" with your cluster API URL and bearer token

2. **Run OpenShift Demos**:
   - Job templates will deploy resources to your OpenShift cluster

## Resources

- [OpenShift Demos Documentation](https://ansible.github.io/product-demos/openshift/)
- [Product Demos Repository](https://github.com/ansible/product-demos)
