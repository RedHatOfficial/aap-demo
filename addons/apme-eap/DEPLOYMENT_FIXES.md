# APME EAP Deployment - Fixes and Resolution Summary

## Overview

This document summarizes the debugging process and fixes applied to successfully deploy the Ansible Quality (APME) Early Access Program portal via Ansible Automation Platform (AAP) on OpenShift Local (MicroShift).

## Initial Problem

The APME deployment job was failing with:
```
error: The public hostname of the integrated registry could not be determined. 
Please specify one with --registry.
```

This error occurred when the `oc registry login` command tried to auto-detect the registry hostname, which doesn't work in MicroShift environments.

## Root Causes Identified

Through iterative debugging, we discovered multiple interconnected issues:

### 1. Registry Configuration Issue
- **Problem**: Playbook configured to use OpenShift integrated registry (`image-registry.openshift-image-registry.svc:5000`) which doesn't exist in MicroShift
- **Impact**: `oc registry login` command failed with hostname detection error
- **Solution**: Deployed aap-demo-registry addon and configured OCI target as `registry.aap-demo-registry.svc.cluster.local:5000/apme`

### 2. Network Connectivity Issue (Hairpin NAT)
- **Problem**: Pods running inside the cluster cannot connect to external routes like `aap-aap-operator.apps.127.0.0.1.nip.io`
- **Impact**: OAuth application check failed - pods couldn't reach AAP Gateway API via external route
- **Root Cause**: Network routing prevents pods from accessing their own external routes (hairpin NAT limitation)
- **Solution**: Use internal service URL `http://aap.aap-operator.svc.cluster.local` for AAP API access from within cluster

### 3. Malformed Portal URL
- **Problem**: `openshift_cluster_domain` was being derived from `kubernetes.default.svc` API URL, resulting in malformed portal URL: `https://redhat-rhaap-portal-apme.https://kubernetes.default.svc`
- **Impact**: OAuth redirect URI was invalid, causing OAuth application creation to fail
- **Solution**: Explicitly extract cluster domain from existing routes and pass as `openshift_cluster_domain` variable

### 4. Missing Variables
- **Problem**: Multiple required variables not included in job template `extra_vars`
- **Impact**: Playbook failed with "undefined variable" errors
- **Missing Variables**:
  - `aap_host`, `aap_username`, `aap_password` - AAP connection for OAuth
  - `aap_organization` - AAP organization for OAuth app
  - `portal_helm_release_name` - Helm release identifier
  - `aap_apme_prerequisites_oauth_application_name` - OAuth app name
  - All Helm chart configuration variables (repo URLs, chart names, versions)
- **Solution**: Added all required variables to job template configuration

### 5. Missing Helm Binary
- **Problem**: Execution Environment (EE) image didn't include `helm` binary
- **Impact**: Helm module failed with "Failed to find required executable 'helm'"
- **Solution**: Rebuilt APME EE to include helm v3.14.0 installed manually from upstream

### 6. Incorrect Helm Module Usage
- **Problem**: Roles concatenated `chart_repo_url` and `chart_name` in `chart_ref` parameter
- **Impact**: Helm tried to fetch from malformed URL like `https://charts.openshift.io/redhat-rhaap-portal` instead of using repo
- **Solution**: Separated `chart_ref` and `chart_repo_url` parameters in kubernetes.core.helm module calls

### 7. ARM64 Image Availability
- **Problem**: Red Hat registry images (`registry.redhat.io/rhdh/rhdh-hub-rhel9:1.9`) don't have ARM64 builds
- **Impact**: ImagePullBackOff on Apple Silicon / ARM64 systems
- **Solution**: Architecture detection + automatic fallback to upstream quay.io images with ARM64 support

## Changes Made

### File: `addons/apme-eap/playbooks/setup_aap_resources.yml`

**Changes**:
1. Added AAP password retrieval and decode steps
2. Added AAP route hostname extraction
3. Derived cluster domain from existing route
4. Built comprehensive `job_extra_vars` with all required variables:
   - OpenShift connection vars
   - AAP connection vars (`aap_host` using internal service URL)
   - Helm chart configuration vars
   - Set `skip_plugin_push: true` to bypass OCI push issues

**Key Additions**:
```yaml
aap_host: "http://aap.aap-operator.svc.cluster.local"  # Internal service URL
openshift_cluster_domain: "{{ cluster_domain }}"       # Explicit cluster domain
aap_organization: "Default"
# ... all Helm configuration variables
```

### File: `addons/apme-eap/playbooks/roles/aap_apme_prerequisites/tasks/create_oauth_app.yml`

**Changes**:
- Temporarily disabled `no_log: true` on OAuth check task for debugging (line 40)

### File: `addons/apme-eap/playbooks/roles/portal_helm_install/tasks/main.yml`

**Changes**:
- Split `chart_ref` concatenation into separate `chart_ref` and `chart_repo_url` parameters

**Before**:
```yaml
chart_ref: "{{ portal_helm_chart_repo_url }}{{ portal_helm_chart_name }}"
```

**After**:
```yaml
chart_ref: "{{ portal_helm_chart_name }}"
chart_repo_url: "{{ portal_helm_chart_repo_url }}"
```

### File: `addons/apme-eap/playbooks/roles/apme_gateway_helm/tasks/main.yml`

**Changes**:
- Same chart_ref/chart_repo_url split as portal role

### File: `addons/apme-eap/execution-environment/Containerfile`

**Changes**:
- Added helm installation (v3.14.0 for ARM64)
- Downloads from https://get.helm.sh since helm not available in RHEL9 minimal repos

**Addition**:
```dockerfile
# Install Helm manually (not available in RHEL9 minimal repos, curl-minimal already present)
RUN curl -fsSL https://get.helm.sh/helm-v3.14.0-linux-arm64.tar.gz | tar -xz && \
    mv linux-arm64/helm /usr/local/bin/helm && \
    chmod +x /usr/local/bin/helm && \
    rm -rf linux-arm64
```

### File: `addons/apme-eap/playbooks/roles/apme_helm_values/tasks/main.yml`

**Changes**:
- Added architecture detection
- Added conditional image registry/repository override for ARM64
- Replaces `registry.redhat.io` with `quay.io` for ARM64 systems

**Addition**:
```yaml
- name: Detect system architecture
  ansible.builtin.set_fact:
    system_arch: "{{ ansible_architecture }}"

- name: Use upstream RHDH images for ARM64
  ansible.builtin.set_fact:
    rhdh_image_registry: "quay.io"
    rhdh_image_repository: "rhdh/rhdh-hub-rhel9"
  when: system_arch in ['aarch64', 'arm64']

- name: Override RHDH image registry for ARM64
  ansible.builtin.replace:
    # ... replaces registry.redhat.io with quay.io
```

## Prerequisites Added

### In-Cluster Registry
Deployed the aap-demo-registry addon:
```bash
./addons/registry/deploy.sh
```

This provides:
- Service: `registry.aap-demo-registry.svc.cluster.local:5000`
- Route: `https://registry.apps.127.0.0.1.nip.io`
- Storage: 10Gi PVC backed by LVMS

## Deployment Flow

### Job Template Configuration
The AAP job template "Deploy APME" is configured with:

1. **Project**: `aap-demo-apme` (Git SCM, auto-sync on launch)
2. **Inventory**: `localhost` (local connection)
3. **Execution Environment**: APME EE (quay.io/cferman/apme-ee:latest) with oc, skopeo, helm
4. **Playbook**: `addons/apme-eap/playbooks/deploy_apme_portal.yml`
5. **Extra Vars**: All configuration passed via job template (see setup_aap_resources.yml)

### Execution Flow

1. **Setup Phase** (runs locally):
   ```bash
   ansible-playbook playbooks/setup_aap_resources.yml
   ```
   - Creates/updates AAP project, inventory, EE, job template
   - Generates OpenShift service account token
   - Retrieves AAP admin password
   - Builds complete extra_vars configuration

2. **Launch Phase** (runs locally):
   ```bash
   ansible-playbook playbooks/launch_apme_deployment.yml
   ```
   - Launches job template in AAP via REST API
   - Polls job status every 5 seconds
   - Streams job output
   - Reports success/failure

3. **Deployment Phase** (runs in AAP execution environment):
   - Playbook: `deploy_apme_portal.yml`
   - Runs in pod with APME EE image
   - Creates namespace
   - Sets up OAuth with AAP
   - Installs portal Helm chart
   - Installs APME gateway Helm chart

## Architecture Considerations

### Internal vs External URLs

**External URLs** (for browser/local machine access):
- AAP: `https://aap-aap-operator.apps.127.0.0.1.nip.io`
- APME Portal: `https://redhat-rhaap-portal-apme.apps.127.0.0.1.nip.io`
- Registry: `https://registry.apps.127.0.0.1.nip.io`

**Internal URLs** (for pod-to-pod communication):
- AAP API: `http://aap.aap-operator.svc.cluster.local`
- OpenShift API: `https://kubernetes.default.svc:443`
- Registry: `registry.aap-demo-registry.svc.cluster.local:5000`

### ARM64 vs x86_64

**x86_64 Systems**:
- Uses official Red Hat images: `registry.redhat.io/rhdh/rhdh-hub-rhel9:1.9`
- Full support for all features

**ARM64 Systems** (Apple Silicon):
- Uses upstream community images: `quay.io/rhdh/rhdh-hub-rhel9:1.9`
- Automatic detection and fallback
- Same functionality, different image source

## Known Limitations

### Plugin Push Disabled
- Set `skip_plugin_push: true` in job template
- **Reason**: The aap-demo-registry uses HTTP, but skopeo defaults to HTTPS
- **Impact**: APME plugins not pre-loaded in portal
- **Future Fix**: Either:
  1. Add `--dest-tls-verify=false` to skopeo for external registries, or
  2. Configure registry with TLS, or
  3. Load plugins via alternative method

### Debugging Visibility
- OAuth check has `no_log: false` (disabled for debugging)
- **Security Note**: Re-enable `no_log: true` in production to hide sensitive data

## Testing Commands

### Check Deployment Status
```bash
# AAP job status
export AAP_TOKEN=$(kubectl get secret aap-api-token -n aap-operator -o jsonpath='{.data.token}' | base64 -d)
curl -sk -H "Authorization: Bearer $AAP_TOKEN" \
  "https://aap-aap-operator.apps.127.0.0.1.nip.io/api/controller/v2/jobs/?order_by=-id&page_size=1" | \
  jq -r '.results[0] | "\(.id) | \(.name) | \(.status)"'

# Pod status
kubectl get pods -n apme

# Helm releases
kubectl get helmrelease -n apme
```

### Access Portal
```bash
# Get portal route
kubectl get route -n apme -o jsonpath='{.items[0].spec.host}'

# Open in browser
open "https://$(kubectl get route -n apme -o jsonpath='{.items[0].spec.host}')"
```

## Lessons Learned

1. **MicroShift Limitations**: Not a full OpenShift - missing integrated registry, different networking
2. **Hairpin NAT**: Always use internal service URLs for pod-to-pod communication
3. **Architecture Awareness**: Check image availability for target architecture
4. **Iterative Debugging**: Remove `no_log` temporarily to see actual errors
5. **Variable Scope**: Job template extra_vars don't inherit from playbook defaults
6. **Helm Module**: Use `chart_repo_url` parameter, not URL concatenation

## Future Enhancements

1. **Enable Plugin Push**: Fix skopeo TLS verification for HTTP registries
2. **Re-enable no_log**: Secure OAuth and password tasks
3. **Multi-arch Images**: Build custom multi-arch EE images
4. **Vars File Approach**: Move extra_vars to a dedicated vars file for easier management
5. **Validation**: Add pre-flight checks for prerequisites (registry, DNS, etc.)

## Commit History

Key commits on `apme-playbook` branch:

1. `fix(apme-eap): use internal service URLs and set cluster domain`
2. `fix(apme-eap): add missing aap_organization variable`
3. `fix(apme-eap): add portal_helm_release_name and oauth app name`
4. `fix(apme-eap): skip plugin push to avoid registry TLS issues`
5. `fix(apme-eap): add all required Helm chart configuration variables`
6. `feat(apme-eap): add helm to execution environment`
7. `fix(apme-eap): use chart_repo_url parameter for helm module`
8. `feat(apme-eap): use upstream RHDH images for ARM64 systems`

## References

- ADR-019b: Architecture decisions for APME deployment
- APME EAP Welcome Pack: Original playbooks and documentation
- aap-demo repo: https://github.com/RedHatOfficial/aap-demo
