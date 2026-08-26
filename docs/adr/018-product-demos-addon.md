# ADR-018: Ansible Product Demos Addon Integration

**Status**: Accepted

**Date**: 2026-07-24

**Authors**: Claude Sonnet 4.5, Chad Ferman

## Context

The [Ansible Product Demos (APD)](https://github.com/ansible/product-demos) repository provides
officially supported demo content across multiple technology domains (Linux, Windows, Network,
Cloud, OpenShift, Satellite). These demos are valuable for field sellers, technical marketers,
and anyone needing to demonstrate AAP capabilities in specific scenarios.

### Problem Statement

Prior to this integration, users who wanted APD content in their aap-demo environment had to:

1. Manually install `ansible-navigator`
2. Manually clone the product-demos repository
3. Manually set up AAP credentials as environment variables
4. Manually run the installation playbook
5. Repeat for each domain-specific demo category they wanted

This manual process created friction and reduced adoption of official demo content.

### Constraints

- Must follow the existing addon system pattern established in [ADR-008](008-addon-system.md)
- Must not modify the upstream ansible/product-demos repository
- Must work with AAP 2.7 deployed by aap-demo
- Must support OpenShift Local (MicroShift) infrastructure
- Should minimize persistent disk usage
- Should support "Bring Your Own Demo" customization workflow

### Forces at Play

1. **Granularity vs Simplicity**: Users may only need one domain (e.g., Linux) but don't want to install all six domains
2. **Dependency Management**: All domains require the same base infrastructure (organization, project, EE)
3. **Tool Installation**: `ansible-navigator` is required but not part of base aap-demo
4. **Disk Usage**: Cloning product-demos repo permanently consumes ~50MB per user
5. **Upstream Compatibility**: Product-demos assumes specific environment variables and execution patterns
6. **Fork Support**: Users want to customize demos for their specific needs

## Decision

We integrated ansible/product-demos as **seven separate addons**: one base addon plus six
domain-specific addons. After initial implementation and testing, we pivoted to an **AAP job
template approach** instead of local ansible-playbook execution.

### Architecture

**Base Addon (`product-demos-base`)**

**Approach**: Creates an AAP project and job template that runs `install-apd.yml` inside AAP's
execution environment.

**How it works**:

1. Creates custom credential type "APD Installer Credentials" that injects AAP admin credentials as environment variables
2. Creates AAP project pointing to github.com/ansible/product-demos (auto-syncs on launch)
3. Registers Product Demos EE (`quay.io/ansible-product-demos/apd-ee-26:latest`)
4. Creates job template "APD | Install Base Resources" with:
   - Project: Ansible Product Demos
   - Playbook: `install-apd.yml`
   - Execution Environment: Product Demos EE
   - Credential: APD Installer - AAP Admin
5. Launches the job and monitors progress via AAP API
6. Job runs inside Product Demos EE which has all required collections pre-installed

**Benefits over local execution**:

- No local dependencies (no Python venv, no ansible-playbook, no collection downloads)
- Uses official Product Demos EE which has `ansible.platform` and all collections pre-installed
- Jobs are visible in AAP UI for monitoring and troubleshooting
- Leverages AAP's built-in project sync, execution environment management, and job orchestration
- No macOS/podman compatibility issues
- Supports custom repo/branch via `PRODUCT_DEMOS_REPO` and `PRODUCT_DEMOS_BRANCH` env vars

#### Domain Addons (6 total)

- `product-demo-linux` - RHEL and Linux automation
- `product-demo-windows` - Windows Server automation
- `product-demo-network` - Network device automation
- `product-demo-cloud` - AWS cloud provisioning
- `product-demo-openshift` - OpenShift/Kubernetes
- `product-demo-satellite` - Red Hat Satellite integration

Each domain addon:

1. Auto-enables `product-demos-base` if not already installed
2. Retrieves AAP admin credentials from cluster secrets
3. Clones product-demos repo to temporary directory
4. Runs domain-specific `setup_demo.yml` playbook with `demo=<category>`
5. Cleans up temporary directory
6. Provides domain-specific guidance for credential configuration

### Key Implementation Details

#### Custom Credential Type

```bash
# Credential type that injects environment variables AND extra_vars
{
  "name": "APD Installer Credentials",
  "kind": "cloud",
  "injectors": {
    "env": {
      "AAP_HOSTNAME": "{{ aap_hostname }}",
      "AAP_USERNAME": "{{ aap_username }}",
      "AAP_PASSWORD": "{{ aap_password }}"
    },
    "extra_vars": {
      "gateway_host": "{{ aap_hostname }}",
      "controller_host": "{{ aap_hostname }}",
      "gateway_username": "{{ aap_username }}",
      "controller_username": "{{ aap_username }}",
      ...
    }
  }
}
```

The credential injector provides variables in two ways:

- `env`: For `lookup('env')` calls in product-demos playbooks
- `extra_vars`: For `infra.aap_configuration` collection roles

#### AAP API Integration

```bash
# Uses /api/controller/v2/ endpoints (AAP 2.7)
AAP_API="${AAP_HOSTNAME}/api/controller/v2"

# Create project
curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  -X POST -H "Content-Type: application/json" \
  -d "$PROJECT_PAYLOAD" \
  "${AAP_API}/projects/"

# Monitor job via API
STATUS=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
  "${AAP_API}/jobs/${JOB_ID}/" | jq -r '.status')
```

**Dependency Management**
Domain addons check for base installation:

```bash
if ! grep -q "product-demos-base" ~/.aap-demo/config; then
    bash "$SCRIPT_DIR/../product-demos-base/deploy.sh"
fi
```

Base addon prevents removal while domains are enabled:

```bash
if [ ${#ENABLED_DOMAINS[@]} -gt 0 ]; then
    echo "Cannot remove base while domains are enabled: ${ENABLED_DOMAINS[@]}"
    exit 1
fi
```

**Fork Support**
Users can point to custom repositories (updates AAP project configuration):

```bash
PRODUCT_DEMOS_REPO=https://github.com/myorg/product-demos \
PRODUCT_DEMOS_BRANCH=custom \
  aap-demo enable product-demos-base
```

## Consequences

### Positive

1. **Zero Local Dependencies** - No Python venv, no ansible-playbook, no collection installation
2. **Uses Official EE** - Product Demos EE has `ansible.platform` and all required collections pre-installed
3. **Visible in AAP UI** - Jobs appear in AAP for monitoring, troubleshooting, and re-running
4. **Platform Independent** - No macOS/podman issues; works everywhere AAP works
5. **Granular Control** - Users install only the domains they need
6. **Fork-Friendly** - Easy to use customized demo content by changing AAP project URL
7. **Standard Pattern** - Follows existing addon conventions, familiar UX
8. **Official Content** - Provides access to Red Hat's official demo library
9. **Idempotent** - Safe to re-run; AAP handles job idempotency
10. **Leverages AAP** - Uses AAP's project sync, EE management, and credential injection

### Negative

1. **Network Dependency** - AAP must reach github.com to sync project (acceptable for demo tool)
2. **Credential Configuration** - AWS, Satellite, machine SSH/WinRM, and Insights still require
   manual UI updates; OpenShift, AAP callback, and Galaxy tokens are auto-wired by
   [`includes/addon-wire.sh`](../../includes/addon-wire.sh) when the cluster or token file provides values
3. **Deletion Complexity** - Removing APD resources requires manual AAP UI steps (no API-based deletion implemented)
4. **Multiple Addons** - Seven addons instead of one (more to maintain)
5. **API Complexity** - More complex than shell scripts; requires AAP API knowledge for troubleshooting
6. **Network Routing Issue** - Execution environment pods cannot reach external nip.io routes;
   must use internal service URLs

### Neutral

1. **Follows APD Upstream** - Uses official playbooks unchanged
2. **AAP 2.7 Compatible** - Uses AAP 2.7 API (`/api/controller/v2/`)
3. **Documentation Burden** - Each addon has its own README (but provides clarity)

### Known Issues

See [ADR-023](023-addon-auto-wiring.md) for APD credential auto-wiring via `aap-demo wire`.

**Credential creation during install job**: If `install-apd.yml` fails to create the **AAP
Credential**, run `aap-demo wire` after the APD organization exists. Wiring creates or updates
**AAP Credential**, **OpenShift Credential**, and Galaxy credentials using in-cluster URLs.

Historical note (pre-wiring):
"AAP Credential" object. This credential is used by demo job templates to call back into AAP
APIs.

**Root Cause**: Network routing - execution environment pods run inside Kubernetes and cannot
reach the external `*.apps.127.0.0.1.nip.io` route. Using internal service URL
(`http://aap.aap-operator.svc.cluster.local`) allows organization/user creation but credential
creation fails with a censored error (`no_log: true` in `infra.aap_configuration` collection).

**Impact**:

- ✅ APD organization created successfully
- ✅ `apd-admin` user created successfully
- ⏸️ Demo job templates not created (depends on credential)
- ⏸️ APD project not created in organization (depends on credential)

**Workarounds**:

1. Manually create the "AAP Credential" via AAP UI after running the addon
2. Fork `ansible/product-demos` and modify credential creation task
3. Investigate `infra.aap_configuration` version compatibility with AAP 2.7

## Testing Results

Comprehensive testing revealed 5 critical bugs in the initial local ansible-playbook approach, all fixed before user exposure:

1. **AAP Resource Type** - Scripts checked for `aap-gateway` CRD but AAP 2.7 uses `aap`
2. **Route Retrieval** - Label-based filtering didn't match AAP 2.7 routes; changed to direct name lookup
3. **Secret Retrieval** - Label-based secret lookup failed; changed to direct secret name
4. **ansible Installation** - System-wide pip install blocked by macOS
   externally-managed-environment; switched to shared venv
5. **macOS Compatibility** - ansible-navigator requires podman which has known macOS issues

These bugs led to the architectural pivot to the AAP job template approach, which eliminated
all 5 issues by removing local execution entirely.

**Current State** (AAP Job Template Approach):

- ✅ Project creation and sync
- ✅ Execution environment registration
- ✅ Custom credential type and credential creation
- ✅ Job template creation and launch
- ✅ Organization creation in AAP
- ✅ User creation in APD organization
- ⏸️ Credential object creation (blocked by network routing + censored error)

See commit `2b86160` for bug fixes and commit `bb8f375` for AAP job template implementation.

## Alternatives Considered

### Alternative 1: Single Addon with Domain Selection

**Description**: One `product-demos` addon that prompts for which domains to install or accepts an environment variable.

**Why Not Chosen**:

- Issue #71 acceptance criteria specifically requested separate enable calls per domain
- Less aligned with existing addon pattern (each addon = one enable command)
- More complex state management (tracking which domains are installed within one addon)
- Harder to discover available domains (`aap-demo enable` shows all addons clearly)

**What Would Be Different**:

- Fewer files to maintain (2 files instead of 14)
- More complex deploy.sh logic with domain selection
- Less granular control for users

### Alternative 2: Persistent Repository Clone

**Description**: Clone product-demos to `~/.aap-demo/product-demos/` and reuse it.

**Why Not Chosen**:

- User explicitly requested temporary directory approach
- Adds ~50MB persistent disk usage per user
- Requires handling repo updates (git pull) and branch switching
- More complex state management

**What Would Be Different**:

- Faster re-runs (no clone needed)
- Could support local modifications more easily
- More complex update/cleanup logic

### Alternative 3: Local ansible-playbook Execution (Original Implementation)

**Description**: Run `ansible-playbook install-apd.yml` locally using a shared Python venv and install collections via ansible-galaxy.

**Why Not Chosen**:

- Requires complex local dependency management (Python venv, ansible installation, collection downloads)
- `ansible.platform` collection not available without Red Hat Automation Hub or fully synced PAH
- ansible-navigator approach failed on macOS due to podman compatibility issues
- ansible-playbook approach failed due to missing `ansible.platform` collection
- PAH sync for Red Hat collections can take significant time and may not include all required collections
- Creates maintenance burden for keeping collection versions in sync

**What Would Be Different**:

- Simpler scripts (no AAP API calls)
- Faster initial development
- More fragile (depends on local environment, collection availability, PAH sync status)
- Not visible in AAP UI

**Why AAP Job Template Approach is Superior**:

- Eliminates all local dependencies
- Uses official Product Demos EE with guaranteed collection availability
- Provides visibility and monitoring via AAP UI
- Platform-independent (no macOS/Linux differences)

### Alternative 4: Bundle APD Content Directly

**Description**: Fork product-demos and include playbooks/roles directly in aap-demo repo.

**Why Not Chosen**:

- Violates DRY principle (duplicate official content)
- Creates maintenance burden (tracking upstream changes)
- Loses easy fork support (users would need to fork aap-demo, not product-demos)
- No clear licensing for redistributing APD content

**What Would Be Different**:

- No network dependency
- Faster deployment
- Customization would be harder
- Upstream updates would not propagate

## Testing Strategy

A comprehensive test plan has been developed to validate the implementation across 10 test
phases covering 37 distinct test cases.

### Test Coverage

#### Phase 1: Fresh Environment Setup

- Cluster creation and AAP deployment verification
- Ensures clean baseline for testing

#### Phase 2: Base Addon Tests

- First-time installation with ansible-navigator auto-install
- Idempotency verification (re-running succeeds without errors)
- Custom repository and branch support
- Deletion protection when domain addons are enabled

#### Phase 3: Domain Addon Tests

- Installation of all 6 domain addons (linux, windows, network, cloud, openshift, satellite)
- Automatic base addon dependency installation
- Verification of domain-specific job templates
- Idempotency for domain addons

#### Phase 4: Multi-Domain Coexistence

- All domains enabled simultaneously
- No conflicts between domain templates
- Status command integration

#### Phase 5: Cleanup and Removal

- Single domain removal (preserves base and other domains)
- All domains removal (base remains)
- Base removal with dependency checking
- Prevention of base removal when domains are active

#### Phase 6: Error Handling

- No cluster running
- AAP not deployed
- Invalid repository URL
- Network failures during clone

#### Phase 7: Advanced Scenarios

- Custom fork with custom branch
- Pre-installed ansible-navigator detection
- Multiple enable/disable cycles
- Parallel domain installation

#### Phase 8: End-to-End Demo Execution

- Running actual demo job templates in AAP
- Execution environment verification
- Project synchronization
- Validates demos work end-to-end, not just install

#### Phase 9: Documentation Verification

- README accuracy
- Addon-specific README completeness
- ADR documentation
- Ensures documentation matches implementation

#### Phase 10: Regression Testing

- Existing addons still function
- Core aap-demo commands unaffected
- Clean teardown with new addons enabled

### Test Artifacts

**Test Plan Document**: Detailed test procedures with exact commands, expected outcomes, and
validation steps for all 37 test cases.

**Success Criteria**:

- All addon deploy scripts are executable
- Addons registered in `AVAILABLE_ADDONS`
- Documentation complete and accurate
- No regressions in existing functionality
- Idempotent operations throughout
- Graceful error handling with actionable messages

### Validation Methods

1. **Functional Testing**: Manual execution of test procedures
2. **Integration Testing**: AAP UI verification of created resources
3. **State Testing**: Config file and addon tracking validation
4. **Error Testing**: Intentional failure scenarios
5. **Regression Testing**: Existing features and addons verification

## References

- [Issue #71: Feature: Integrate `ansible/product-demos` as an Add-on](https://github.com/RedHatOfficial/aap-demo/issues/71)
- [Ansible Product Demos Repository](https://github.com/ansible/product-demos)
- [APD Documentation](https://ansible.github.io/product-demos/)
- [Product Demos Execution Environment](https://quay.io/repository/ansible-product-demos/apd-ee-26)
- [infra.aap_configuration Collection](https://github.com/redhat-cop/infra.aap_configuration)
- [ADR-008: Addon System](008-addon-system.md)
- Commit: `823863f` - Initial implementation (local ansible-playbook approach)
- Commit: `2b86160` - Bug fixes for AAP 2.7 compatibility
- Commit: `bb8f375` - Pivot to AAP job template approach
- Test Plan: `test-product-demos-addon.md` - 37 test cases across 10 phases
- Test Results: `test-results-product-demos-addon.md` - Discovered 5 critical bugs
