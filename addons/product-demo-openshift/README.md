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

On aap-demo MicroShift clusters, the **OpenShift Credential** is configured
automatically when product demos are enabled (`aap-demo enable product-demo-openshift`
or `aap-demo enable product-demos`; wiring runs automatically after install):

- **API host**: `https://kubernetes.default.svc:443` (in-cluster endpoint for job pods)
- **Bearer token**: from your active `oc` session or kubeconfig
- **verify_ssl**: `false`

Override discovery with environment variables when needed:

```bash
OPENSHIFT_API_HOST=https://api.example.com:6443 \
OPENSHIFT_BEARER_TOKEN=sha256~... \
  aap-demo enable product-demo-openshift
```

To manage a different cluster, update **OpenShift Credential** in the APD
organization via the AAP UI after installation.

## Resources

- [OpenShift Demos Documentation](https://ansible.github.io/product-demos/openshift/)
- [Product Demos Repository](https://github.com/ansible/product-demos)
