# APME Execution Environment

Custom Ansible Automation Platform execution environment based on AAP 2.7 ee-supported-rhel9 with additional OpenShift and container tooling.

## Contents

- **Base**: `registry.redhat.io/ansible-automation-platform-27/ee-supported-rhel9:latest`
- **Additional Tools**:
  - `openshift-clients` (oc CLI)
  - `skopeo` (container image management)
- **Collections**:
  - `kubernetes.core` - Kubernetes/OpenShift automation
  - `ansible.posix` - POSIX utilities

## Building

### Prerequisites

1. Install ansible-builder:
   ```bash
   pip install ansible-builder
   ```

2. Authenticate to Red Hat registry:
   ```bash
   podman login registry.redhat.io
   ```

### Build locally

```bash
cd addons/apme-eap/execution-environment
ansible-builder build --tag quay.io/YOUR_ORG/apme-ee:latest
```

### Build in OpenShift

```bash
# Create BuildConfig
oc new-build https://github.com/RedHatOfficial/aap-demo.git \
  --context-dir=addons/apme-eap/execution-environment \
  --name=apme-ee \
  --strategy=docker

# Start build
oc start-build apme-ee --follow
```

## Pushing to Registry

```bash
# Push to Quay
podman push quay.io/YOUR_ORG/apme-ee:latest

# Or push to OpenShift internal registry
podman tag quay.io/YOUR_ORG/apme-ee:latest \
  image-registry.openshift-image-registry.svc:5000/aap-operator/apme-ee:latest
podman push image-registry.openshift-image-registry.svc:5000/aap-operator/apme-ee:latest
```

## Using in AAP

1. **Add to AAP**:
   - Navigate to Administration → Execution Environments
   - Click "Add"
   - Name: `APME EE`
   - Image: `quay.io/YOUR_ORG/apme-ee:latest`
   - Pull: Always

2. **Update Job Template**:
   - Edit "Deploy APME" job template
   - Set Execution Environment to "APME EE"
   - Save

3. **Update variables** to enable plugin push:
   ```yaml
   skip_plugin_push: false
   oci_registry: "image-registry.openshift-image-registry.svc:5000/apme"
   ```

## Verification

Test the EE locally:

```bash
ansible-navigator run --execution-environment-image quay.io/YOUR_ORG/apme-ee:latest \
  --mode stdout \
  --pull-policy missing \
  --playbook test.yml
```

Or run a quick test:

```bash
podman run -it --rm quay.io/YOUR_ORG/apme-ee:latest /bin/bash -c "oc version --client && skopeo --version"
```

## Size

Expected image size: ~1.5-2 GB (base AAP EE is ~1.2 GB, plus oc/skopeo ~300-500 MB)
