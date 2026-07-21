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

## References

- [ADR-008](008-addon-system.md): Addon system architecture
- [ADR-004](004-portal-helm-addon.md): Portal Helm addon (similar dual-path pattern)
- [APME Welcome Pack](https://drive.google.com/drive/folders/146Yc3TDKgX0l7k1etdJVXZ2NqhBvPuqr): Official APME deployment documentation
- [APME GitHub Repository](https://github.com/ansible/apme): APME source code
- [addons/apme-playbook/README.md](../../addons/apme-playbook/README.md): Addon documentation
