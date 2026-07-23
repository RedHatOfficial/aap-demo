# ADR-019: APME Playbook Addon

**Status:** Accepted  
**Date:** 2026-07-21  
**Author:** Chad Ferman

## Context

The APME (Ansible Portal Managed Engine) Early Access Program provides an official deployment method using Ansible playbooks (the "welcome pack"). While aap-demo could implement APME deployment using pure bash (similar to other addons), using the official playbooks provides better alignment with upstream and easier maintenance as APME evolves.

**Deployment options considered:**

1. **Pure bash implementation** - Custom logic replicating welcome pack behavior
2. **Ansible playbook wrapper** - Use official welcome pack playbooks via thin bash wrapper
3. **Hybrid approach** - Mix bash for discovery, Ansible for deployment

**Challenge:** aap-demo addons are bash-based (ADR-008), but APME has official Ansible playbooks. This creates a choice between addon consistency (bash-only) and upstream alignment (use official playbooks).

## Decision

Create `apme-playbook` addon that uses official APME EAP welcome pack Ansible playbooks via a bash wrapper. This establishes a new pattern: **Ansible-based addons with bash integration**.

### Architecture Decision 1: Wrapper Pattern

**Thin bash wrapper** (`deploy.sh`) that:
- Conforms to aap-demo addon contract (deploy/--delete interface)
- Handles prerequisite checking
- Auto-discovers aap-demo environment
- Generates Ansible vars file dynamically
- Delegates to official welcome pack playbooks

**Benefits:**
- Addon system compatibility (bash entry point)
- Upstream alignment (use official playbooks as-is)
- No playbook duplication or maintenance burden

### Architecture Decision 2: Isolated Python Virtual Environment

**Problem:** System-wide Ansible installation creates conflicts and version dependencies.

**Solution:** Create isolated Python venv at `~/.aap-demo/apme-playbook-venv` with:
- Ansible (2.15+)
- Required Python libraries (PyYAML, kubernetes, openshift, requests, jmespath)
- Ansible collections (kubernetes.core, community.okd, community.general)

**Benefits:**
- No system-wide Ansible requirement
- Reproducible environment
- No conflicts with other Ansible projects
- Clean uninstall (delete one directory)

### Architecture Decision 3: KUBECONFIG-Based Authentication

**Problem:** Welcome pack playbooks expect `openshift_token` (bearer token), but CRC/MicroShift uses client certificate authentication.

**Solution:** Modify copied role tasks to support both authentication methods:
- `api_key: "{{ openshift_token | default(omit) }}"` (optional token)
- `kubeconfig: "{{ lookup('env', 'K8S_AUTH_KUBECONFIG') | default(omit) }}"` (KUBECONFIG fallback)
- Set `K8S_AUTH_KUBECONFIG` environment variable in deploy wrapper

**Benefits:**
- Works with CRC/MicroShift client certificates
- Still supports token auth if available
- No kubeconfig file writing needed

### Architecture Decision 4: Environment Auto-Discovery

**Automated discovery** of aap-demo context instead of manual vars editing:
- KUBECONFIG path from CRC defaults
- OpenShift API URL from kubeconfig
- Cluster domain from routes
- AAP route from `aap-operator` namespace
- AAP admin password from secrets
- Cluster architecture (x86/ARM)

**Generated vars file:** `~/.aap-demo/apme-playbook-vars.yml` (regenerated each deploy)

**Benefits:**
- Zero manual configuration
- Always uses current cluster state
- Consistent with other addon UX

### Architecture Decision 5: Welcome Pack Integration

**Copy official playbooks** into addon directory instead of external dependency:
```
addons/apme-playbook/
├── deploy.sh              # Bash wrapper (NEW)
├── requirements.txt       # Python deps (NEW)
├── requirements.yml       # Ansible collections (from welcome pack)
├── defaults.yml           # Default config (NEW)
├── playbooks/             # COPIED from welcome pack
├── roles/                 # COPIED from welcome pack (MODIFIED for kubeconfig)
└── plugin_packs/          # COPIED from welcome pack
```

**Modifications to copied roles:**
- Add kubeconfig support to all kubernetes.core module calls
- No other changes to playbook logic

**Benefits:**
- Self-contained addon (no external zip dependency)
- Can be updated by copying new welcome pack
- Clear diff of local modifications

## Implementation

### Key Files

```
addons/apme-playbook/
├── deploy.sh (~350 lines)         # Bash wrapper with venv setup
├── requirements.txt               # Python dependencies
├── requirements.yml               # Ansible collection requirements
├── defaults.yml                   # Default Helm chart versions, etc.
├── README.md                      # Comprehensive documentation
├── playbooks/
│   └── deploy_apme_portal.yml    # Main playbook from welcome pack
├── roles/                         # 7 roles from welcome pack
│   ├── openshift_apme_setup/     # Namespace, SCCs, pull secrets
│   ├── aap_apme_prerequisites/   # OAuth app, API token
│   ├── apme_oci_push/            # Plugin registry, skopeo push
│   ├── apme_helm_values/         # Generate Helm values
│   ├── apme_scm_secrets/         # GitHub OAuth/App secrets
│   ├── portal_helm_install/      # RHDH Helm chart
│   └── apme_gateway_helm/        # APME gateway (x86 only)
└── plugin_packs/
    └── *.oci.tar.gz (37 MB)      # Bundled APME plugins
```

### Deployment Flow

```
aap-demo enable apme-playbook
  ↓
deploy.sh
  ↓
1. check_prerequisites()
   - kubectl, helm, skopeo, python3
  ↓
2. setup_venv()
   - Create venv if not exists
   - pip install -r requirements.txt
   - ansible-galaxy collection install -r requirements.yml
  ↓
3. discover_environment()
   - Auto-detect KUBECONFIG, API URL, AAP creds, etc.
  ↓
4. generate_vars_file()
   - Write ~/.aap-demo/apme-playbook-vars.yml
  ↓
5. deploy()
   - export K8S_AUTH_KUBECONFIG=$KUBECONFIG
   - export ANSIBLE_ROLES_PATH=$SCRIPT_DIR/roles
   - ansible-playbook playbooks/deploy_apme_portal.yml
       -e @~/.aap-demo/apme-playbook-vars.yml
       -e @defaults.yml
```

### Architecture Decision 4: SSL Verification for Local Development

**Problem:** OAuth login fails with "Failed to send POST request: fetch failed" on local MicroShift/nip.io deployments because the APME portal backend cannot verify AAP's self-signed TLS certificate.

**Context from Portal Addon:**
The portal addon solves this by **dynamically detecting MicroShift** and injecting `checkSSL: false` at deployment time:

```bash
# addons/portal/deploy.sh:694-715
if [ "${IS_MICROSHIFT:-false}" = true ]; then
  ssl_values="
    ansible:
      rhaap:
        checkSSL: false
    auth:
      providers:
        rhaap:
          'production':
            checkSSL: false"
fi
```

**Solution for APME Addon:**
Apply the same pattern via Ansible variable substitution:

1. **Default variable:** `apme_helm_values_check_ssl: false` (in `roles/apme_helm_values/defaults/main.yml`)
2. **Template placeholder:** Keep `checkSSL: true` in template (production default)
3. **Runtime substitution:** Ansible replaces all `checkSSL: true` with the variable value

```yaml
# roles/apme_helm_values/tasks/main.yml
- name: Substitute portal Helm value placeholders
  ansible.builtin.replace:
    path: "{{ apme_portal_helm_values_path }}"
    regexp: "checkSSL: true"
    replace: "checkSSL: {{ apme_helm_values_check_ssl | string | lower }}"
```

**Benefits:**
- **Default-safe:** Development works out-of-box with `checkSSL: false`
- **Production-ready:** Override with `-e apme_helm_values_check_ssl=true` for real certs
- **Template parity:** Keep upstream template with production defaults
- **Single control point:** One variable controls both OAuth auth and RHAAP API SSL

**Affects Two Config Locations:**
1. `auth.providers.rhaap.production.checkSSL` - OAuth authentication
2. `ansible.rhaap.checkSSL` - RHAAP API backend integration

### Architecture Decision 5: MicroShift OAuth Network Connectivity

**Problem:** Even with `checkSSL: false`, OAuth login fails with "Failed to send POST request: fetch failed" because the portal pod cannot reach AAP via the nip.io hostname.

**Root Cause:**
- **nip.io DNS resolves to 127.0.0.1 inside pods** (loopback, not the ingress IP)
- Portal tries to reach `https://aap-aap-operator.apps.127.0.0.1.nip.io/o/token/`
- Fetch fails because 127.0.0.1 inside the pod is not AAP

**Portal Addon Solution:**
The portal addon (`deploy.sh:626-660`) applies two fixes:

1. **Use `http://` not `https://`** for AAP_HOST_URL - in-cluster Service traffic is port 80
2. **Patch deployment with `hostAliases`** - maps the nip.io route to AAP Service ClusterIP:
   ```bash
   kubectl patch deployment redhat-rhaap-portal --type=merge -p '{
     "spec": {
       "template": {
         "spec": {
           "hostAliases": [{
             "ip": "<AAP_SERVICE_CLUSTER_IP>",
             "hostnames": ["aap-aap-operator.apps.127.0.0.1.nip.io"]
           }]
         }
       }
     }
   }'
   ```

**APME Addon Implementation:**
Created new role `portal_microshift_fixes` (runs after `portal_helm_install`):

```yaml
roles:
  - role: portal_helm_install
  - role: portal_microshift_fixes  # ← MicroShift-only hostAlias + http:// fix
  - role: apme_gateway_helm
```

**Role Tasks:**
1. Detect `IS_MICROSHIFT` environment variable
2. Get AAP Service ClusterIP from `aap-operator` namespace
3. Extract AAP route hostname from `secrets-rhaap-portal`
4. Patch portal Deployment with `hostAliases` mapping
5. Update `secrets-rhaap-portal.aap-host-url` from `https://` to `http://`
6. Wait for deployment rollout

**Why This Works:**
- `hostAliases` overrides DNS resolution **inside the pod only**
- AAP route hostname now resolves to AAP Service ClusterIP (e.g., `10.43.173.79`)
- `http://` connects to Service port 80 (no TLS, internal traffic)
- Browser users still reach AAP via `https://` through ingress (external traffic)

### Integration with aap-demo.sh

**No special handling required** - addon system auto-discovers:
- Added to `AVAILABLE_ADDONS` list
- Added to argument parser case statement
- Standard `bash addons/apme-playbook/deploy.sh` invocation

## Consequences

### Positive

- **Upstream alignment**: Uses official APME deployment logic, easy to update
- **Isolated dependencies**: Venv prevents system pollution and conflicts
- **Zero manual config**: Auto-discovers all required values
- **Structured deployment**: Role-based organization clearer than single bash script
- **Reproducible**: Same Ansible + Python versions every run
- **Easy updates**: Copy new welcome pack when APME releases updates
- **New addon pattern**: Establishes Ansible-based addon precedent for future use

### Negative

- **Larger footprint**: 40+ files vs 1 bash script (but most are data/roles)
- **Slower first run**: Venv setup takes 1-2 minutes (cached afterward)
- **New prerequisite**: Requires `python3` (but extremely common)
- **Complexity**: Users must understand both bash wrapper and Ansible internals for deep debugging
- **Modification tracking**: Need to track changes to copied welcome pack roles

### Neutral

- **Venv persistence**: Venv kept across disable/enable (faster), manual cleanup needed for full removal
- **Plugin pack**: 37 MB binary in repo (could be downloaded instead, but simpler bundled)
- **Architecture**: Same dual-path (x86/ARM) as bash addon but implemented in playbook roles

## Alternatives Considered

### 1. Pure Bash Implementation

Replicate all welcome pack logic in bash (like existing addons).

**Rejected:** 
- High maintenance burden (keep in sync with upstream)
- Welcome pack already tested and working
- Bash not ideal for Helm chart management and complex workflows

### 2. Shell Out to Welcome Pack Zip

Require users to download welcome pack separately, reference it.

**Rejected:**
- Poor UX (extra download step)
- Version mismatch risk (user has wrong welcome pack version)
- Harder to modify for aap-demo integration

### 3. Convert Playbooks to Bash

Port playbook logic to bash for consistency.

**Rejected:**
- Defeats purpose of using official deployment method
- Loses upstream alignment benefit
- More work than wrapper approach

### 4. Require System Ansible

Don't use venv, require user to install Ansible globally.

**Rejected:**
- System pollution
- Version conflicts with other projects
- Harder for users (manual ansible-galaxy collection install)

## Future Considerations

- **Welcome pack updates**: When new APME releases come out, process:
  1. Extract new welcome pack
  2. Copy playbooks/, roles/, plugin_packs/ to addon
  3. Re-apply kubeconfig modifications to roles
  4. Test deployment
  5. Commit changes with changelog

- **Bash addon comparison**: The `apme` branch has a pure-bash implementation. Both approaches can coexist:
  - `apme`: Bash-only, custom logic, faster startup
  - `apme-playbook`: Ansible-based, official logic, upstream-aligned

- **Pattern reuse**: This venv + Ansible wrapper pattern could be used for other addons requiring Ansible (e.g., future product addons with official playbooks)

## Deployment Issues and Resolutions

During initial deployment on MicroShift (OpenShift Local), several interconnected issues were discovered and resolved:

### Issue 1: Registry Hostname Detection Failure

**Problem**: `oc registry login` failed with "The public hostname of the integrated registry could not be determined"

**Root Cause**: Playbook configured to use OpenShift integrated registry (`image-registry.openshift-image-registry.svc:5000`) which doesn't exist in MicroShift

**Resolution**: 
- Deployed `aap-demo-registry` addon providing HTTP registry at `registry.aap-demo-registry.svc.cluster.local:5000`
- Configured job template with `oci_registry` pointing to custom registry
- Set `skip_plugin_push: true` to bypass skopeo TLS verification issues with HTTP-only registry

### Issue 2: Missing Job Template Variables

**Problem**: Sequential "undefined variable" errors for `aap_organization`, `portal_helm_release_name`, and all Helm configuration variables

**Root Cause**: Job template `extra_vars` didn't include variables expected by APME playbooks (which have defaults in their own defaults.yml files but AAP doesn't load those)

**Resolution**: Build comprehensive `extra_vars` dictionary in setup playbook
```yaml
job_extra_vars:
  # OpenShift connection
  openshift_api_url: "https://localhost:6443"
  openshift_token: "{{ openshift_token }}"
  openshift_project_name: "apme"
  openshift_cluster_domain: "{{ cluster_domain }}"
  openshift_validate_certs: false
  
  # OCI registry
  skip_plugin_push: true
  oci_registry: "registry.aap-demo-registry.svc.cluster.local:5000/apme"
  
  # AAP connection (internal service URL)
  aap_host: "https://aap-aap-operator.apps.127.0.0.1.nip.io"
  aap_username: "admin"
  aap_password: "{{ aap_admin_password }}"
  aap_organization: "Default"
  
  # Portal configuration
  portal_helm_release_name: "redhat-rhaap-portal"
  aap_apme_prerequisites_oauth_application_name: "APME Portal OAuth"
  
  # Helm chart configuration (portal)
  portal_helm_chart_repo: "openshift-helm-charts"
  portal_helm_chart_repo_url: "https://charts.openshift.io/"
  portal_helm_chart_name: "redhat-rhaap-portal"
  portal_helm_chart_version: "2.2.3"
  portal_helm_install_timeout: 1800
  
  # Helm chart configuration (APME gateway)
  apme_helm_chart_repo: "apme"
  apme_helm_chart_repo_url: "https://ansible.github.io/apme"
  apme_helm_chart_name: "apme"
  apme_helm_chart_version: "0.1.2"
  apme_helm_release_name: "apme"
```
### Issue 3: Incorrect Helm Module Parameter Usage

**Problem**: Helm failed with `404 Not Found` trying to fetch `https://charts.openshift.io/redhat-rhaap-portal`

**Root Cause**: Roles concatenated repo URL and chart name: `chart_ref: "{{ repo_url }}{{ chart_name }}"` instead of using separate parameters

**Resolution**: Use `chart_repo_url` parameter
```yaml
# Before (incorrect)
chart_ref: "{{ portal_helm_chart_repo_url }}{{ portal_helm_chart_name }}"

# After (correct)
chart_ref: "{{ portal_helm_chart_name }}"
chart_repo_url: "{{ portal_helm_chart_repo_url }}"
## References
```

### Issue 4: Postgres Registry Override

**Problem**: Postgres pod failed with `unauthorized: access to the requested resource is not authorized` on `quay.io/rhel9/postgresql-15`

**Root Cause**: Overly broad regex replacement changed postgres registry from `registry.redhat.io` to `quay.io`, but postgres image on quay.io requires authentication

**Resolution**: Make image replacement specific to RHDH hub only
```yaml
# Target only RHDH hub image, not postgres or other images
- regexp: '(pullSecrets: \[\]\n\s+registry: )registry\.redhat\.io(\n\s+repository: rhdh/rhdh-hub-rhel9)'
  replace: '\1{{ rhdh_image_registry }}\2'
```

### Issue 5: Plugin Compatibility Between RHDH Versions Community needed for arm 

**Problem**: Init container error - `backstage-community-plugin-scaffolder-backend-module-quay-dynamic` not found in community RHDH 1.10

**Root Cause**: Community RHDH (1.10) and Red Hat RHDH (1.9) have different plugin sets

**Resolution**: Remove incompatible plugins for community version
```yaml
- name: Remove incompatible plugins for community RHDH (ARM64)
  ansible.builtin.lineinfile:
    path: "{{ apme_portal_helm_values_path }}"
    regexp: ".*backstage-community-plugin-scaffolder-backend-module-quay.*"
    state: absent
  when: system_arch in ['aarch64', 'arm64']
```

## Migration from ADR-019b

An alternative implementation (ADR-019b) explored AAP-native execution via REST API, where playbooks ran inside AAP rather than locally. This approach was marked as **REJECTED** due to being "Overcomplex and adds multiple new support needs."

The current implementation (ADR-019) follows the simpler local execution model:

**Differences between ADR-019b (rejected) and ADR-019 (current)**:

| Aspect | ADR-019b (Rejected) | ADR-019 (Current) |
|--------|---------------------|-------------------|
| Execution location | Inside AAP (via Job Templates) | Local (in venv) |
| Authentication | Service account tokens via AAP API | KUBECONFIG (client certs) |
| AAP dependencies | Requires AAP REST API, Project, Inventory, Job Template resources | None (only needs AAP gateway for OAuth app creation) |
| Venv size | ~50 MB (ansible-core only for API calls) | ~150 MB (full Ansible + collections) |
| Complexity | High (token management, AAP resource creation, job orchestration) | Low (direct ansible-playbook execution) |
| Visibility | AAP Web UI shows job progress | Terminal shows playbook output |

**If migrating from an ADR-019b prototype**, the refactored addon will:
- No longer create AAP resources (Project, Inventory, Job Template)
- No longer require API tokens
- Run playbooks locally instead of inside AAP
- Use KUBECONFIG instead of service account tokens

**To clean up old AAP resources** (if any were created during ADR-019b testing):
```bash
# These resources are no longer created or used
kubectl delete -n aap-operator \
  project/aap-demo-apme \
  inventory/aap-demo-localhost \
  jobtemplate/deploy-apme 2>/dev/null || true
```

The APME namespace and portal deployment itself remain unchanged between approaches — only the orchestration mechanism differs.

## Security Configuration Parity Fix (2026-07-23)

After initial deployment testing, pod creation failures revealed missing security configuration in the `openshift_apme_setup` role that the `portal` addon implements in its bash wrapper.

### Issue: Missing OpenShift Security Constraints

**Problem**: Pods in the `apme` namespace failed to start with security context constraint (SCC) errors, while the same workload succeeded in the `portal` addon namespace.

**Root Cause Analysis**: Comparison of `addons/apme-eap/` and `addons/portal/` revealed three missing configurations:

1. **Pod Security Admission Labels** - Missing namespace labels for privileged pod security admission
2. **SCC Grants** - No ClusterRoleBindings granting `anyuid` and `privileged` SCCs to namespace service accounts
3. **Pull Secret Propagation** - AAP pull secrets not copied from `aap-operator` namespace to `apme` namespace

### Resolution: Enhanced openshift_apme_setup Role

**File Modified**: `addons/apme-eap/playbooks/roles/openshift_apme_setup/tasks/main.yml`

**Changes Applied**:

#### 1. Pod Security Admission Labels
```yaml
# Added to namespace creation
labels:
  pod-security.kubernetes.io/enforce: privileged
  pod-security.kubernetes.io/audit: privileged
  pod-security.kubernetes.io/warn: privileged

# Separate task to update existing namespaces
- name: Update existing namespace with pod security labels
  kubernetes.core.k8s:
    state: patched
    definition:
      metadata:
        labels:
          pod-security.kubernetes.io/enforce: privileged
          pod-security.kubernetes.io/audit: privileged
          pod-security.kubernetes.io/warn: privileged
```

**Why**: Kubernetes Pod Security Admission controller requires explicit labels to allow privileged workloads. RHDH/Backstage pods need elevated permissions for init containers and dynamic plugin loading.

#### 2. Security Context Constraint (SCC) Grants
```yaml
- name: Grant anyuid SCC to namespace service accounts
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRoleBinding
      metadata:
        name: "system:openshift:scc:anyuid:{{ openshift_project_name }}"
      roleRef:
        kind: ClusterRole
        name: system:openshift:scc:anyuid
      subjects:
        - kind: Group
          name: "system:serviceaccounts:{{ openshift_project_name }}"

- name: Grant privileged SCC to namespace service accounts
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRoleBinding
      metadata:
        name: "system:openshift:scc:privileged:{{ openshift_project_name }}"
      roleRef:
        kind: ClusterRole
        name: system:openshift:scc:privileged
      subjects:
        - kind: Group
          name: "system:serviceaccounts:{{ openshift_project_name }}"
```

**Why**: OpenShift requires explicit SCC grants for pods to run with non-default security contexts. Portal pods require:
- `anyuid`: Run as non-root users with specific UIDs
- `privileged`: Init containers and certain operations need privileged access

#### 3. Pull Secret Propagation
```yaml
- name: Check for AAP pull secret in AAP namespace
  kubernetes.core.k8s_info:
    kind: Secret
    name: redhat-operators-pull-secret
    namespace: "{{ openshift_apme_setup_aap_namespace }}"
  register: aap_pull_secret
  failed_when: false

- name: Copy AAP pull secret to APME namespace
  kubernetes.core.k8s:
    state: present
    definition:
      kind: Secret
      metadata:
        name: redhat-operators-pull-secret
        namespace: "{{ openshift_project_name }}"
      type: kubernetes.io/dockerconfigjson
      data:
        .dockerconfigjson: "{{ aap_pull_secret.resources[0].data['.dockerconfigjson'] }}"
  when:
    - aap_pull_secret.resources is defined
    - aap_pull_secret.resources | length > 0
  no_log: true

- name: Patch default service account to use pull secret
  kubernetes.core.k8s:
    state: patched
    definition:
      kind: ServiceAccount
      metadata:
        name: default
        namespace: "{{ openshift_project_name }}"
      imagePullSecrets: "{{ existing_secrets + [{'name': 'redhat-operators-pull-secret'}] | unique }}"
  when:
    - aap_pull_secret.resources is defined
    - "'redhat-operators-pull-secret' not in (default_sa.resources[0].imagePullSecrets | default([]) | map(attribute='name') | list)"
```

**Why**: APME namespace needs access to Red Hat registry credentials to pull container images. Without this, image pulls fail with authentication errors.

**File Modified**: `addons/apme-eap/playbooks/roles/openshift_apme_setup/defaults/main.yml`

**Changes Applied**:
```yaml
openshift_apme_setup_aap_namespace: "aap-operator"  # Added for pull secret source
```

### Comparison with Portal Addon

The `portal` addon implements the same security configuration via bash functions:

| Configuration | Portal Addon (Bash) | APME-EAP Addon (Ansible) |
|--------------|---------------------|--------------------------|
| Pod Security Labels | `kubectl label namespace` in `setup_portal_namespace()` | `kubernetes.core.k8s` in namespace creation task |
| SCC Grants (anyuid) | `oc adm policy add-scc-to-group` or ClusterRoleBinding | `kubernetes.core.k8s` ClusterRoleBinding |
| SCC Grants (privileged) | `oc adm policy add-scc-to-group` or ClusterRoleBinding | `kubernetes.core.k8s` ClusterRoleBinding |
| Pull Secret Copy | `kubectl create secret` in `copy_pull_secret_to_portal_namespace()` | `kubernetes.core.k8s` Secret creation |
| Service Account Patch | `jq` + `kubectl patch` | `kubernetes.core.k8s` with Jinja2 unique filter |

### Implementation Notes

**Why ClusterRoleBinding instead of `oc adm policy`?**

The Ansible implementation uses ClusterRoleBinding resources directly for several reasons:
1. **Declarative**: Kubernetes-native resources managed via API
2. **API-Based**: Works without requiring `oc` CLI tool
3. **Portable**: Same approach works on OpenShift and vanilla Kubernetes
4. **Idempotent**: `kubernetes.core.k8s` handles idempotency automatically

Both approaches achieve the same result — granting SCCs to service accounts.

**Pull Secret Unique Merge**

The pull secret patch uses a Jinja2 filter to merge secrets without duplicates:
```yaml
imagePullSecrets: "{{ existing_secrets + [{'name': 'redhat-operators-pull-secret'}] | unique }}"
```

This ensures:
- Existing pull secrets are preserved
- New pull secret added only if not already present
- No duplicate entries created

### Backward Compatibility

All changes are fully backward compatible:

- **Idempotent**: All tasks use `state: present` or `state: patched` and will not fail if resources already exist
- **Conditional**: Pull secret copying only occurs if the secret exists in the AAP namespace
- **Safe**: Unique list merge for service account `imagePullSecrets` prevents duplicates

### Testing Verification

To verify the security configuration:

```bash
# Check pod security labels
kubectl get namespace apme -o yaml | grep pod-security

# Check SCC ClusterRoleBindings
kubectl get clusterrolebinding | grep "apme"

# Check pull secret
kubectl get secret -n apme redhat-operators-pull-secret

# Check service account
kubectl get sa default -n apme -o yaml | grep imagePullSecrets -A 2

# Verify pods can start successfully
kubectl get pods -n apme
```

### Lessons Learned

**Addon Parity is Critical**: When porting functionality from one addon pattern (bash) to another (Ansible), security configuration must be included even if not immediately obvious. The portal addon's bash wrapper contains essential OpenShift-specific setup that isn't part of the upstream APME welcome pack playbooks.

**Security Defaults Differ**: OpenShift Local (MicroShift) and full OpenShift have different default security postures. Configuration that works implicitly on one platform may require explicit grants on another.

**Test Across Addon Patterns**: Testing deployment success isn't just about workload functionality — it's also about ensuring the cluster security model allows the workload to run at all.

## References

- [ADR-019b](019b-apme-aap-native-execution.md): Rejected AAP-native execution approach
- [ADR-008](008-addon-system.md): Addon system architecture
- [ADR-004](004-portal-helm-addon.md): Portal Helm addon (similar dual-path pattern)
- [APME Welcome Pack](https://drive.google.com/drive/folders/146Yc3TDKgX0l7k1etdJVXZ2NqhBvPuqr): Official APME deployment documentation
- [APME GitHub Repository](https://github.com/ansible/apme): APME source code
- [addons/apme-playbook/README.md](../../addons/apme-playbook/README.md): Addon documentation
