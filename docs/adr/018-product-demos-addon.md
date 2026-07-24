# ADR-018: Ansible Product Demos Addon Integration

**Status**: Accepted

**Date**: 2026-07-24

**Authors**: Claude Sonnet 4.5, Chad Ferman

## Context

The [Ansible Product Demos (APD)](https://github.com/ansible/product-demos) repository provides officially supported demo content across multiple technology domains (Linux, Windows, Network, Cloud, OpenShift, Satellite). These demos are valuable for field sellers, technical marketers, and anyone needing to demonstrate AAP capabilities in specific scenarios.

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

We integrated ansible/product-demos as **seven separate addons**: one base addon plus six domain-specific addons.

### Architecture

**Base Addon (`product-demos-base`)**
- One-time installation of APD foundation
- Auto-installs `ansible-navigator` via pipx (preferred) or pip3 (fallback)
- Clones product-demos repo to temporary directory (`/tmp/product-demos.XXXXXX`)
- Runs `install-apd.yml` playbook using APD execution environment
- Creates APD organization, project, execution environment, base credentials
- Cleans up temporary directory after completion
- Supports custom repo/branch via `PRODUCT_DEMOS_REPO` and `PRODUCT_DEMOS_BRANCH` env vars

**Domain Addons (6 total)**
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

**Temporary Directory Pattern**
```bash
TEMP_DIR=$(mktemp -d /tmp/product-demos.XXXXXX)
trap 'rm -rf "$TEMP_DIR"' EXIT
```
Uses shell trap to ensure cleanup even on failures.

**Auto-Installation of ansible-navigator**
```bash
if ! command -v ansible-navigator &> /dev/null; then
    if command -v pipx &> /dev/null; then
        pipx install ansible-navigator  # Isolated, preferred
    elif command -v pip3 &> /dev/null; then
        pip3 install --user ansible-navigator  # Fallback
    fi
fi
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
Users can point to custom repositories:
```bash
PRODUCT_DEMOS_REPO=https://github.com/myorg/product-demos \
PRODUCT_DEMOS_BRANCH=custom \
  aap-demo enable product-demo-linux
```

## Consequences

### Positive

1. **Zero Manual Setup** - Users run one command and everything is configured
2. **Granular Control** - Users install only the domains they need
3. **No Persistent Clutter** - Temporary directories are cleaned up automatically
4. **Fork-Friendly** - Easy to use customized demo content
5. **Standard Pattern** - Follows existing addon conventions, familiar UX
6. **Official Content** - Provides access to Red Hat's official demo library
7. **Idempotent** - Safe to re-run without errors or duplicates
8. **Minimal Disk Usage** - No permanent repo clone (saves ~50MB per user)

### Negative

1. **Network Dependency** - Must clone repo each time (acceptable for demo tool)
2. **Auto-Installation Complexity** - Installing ansible-navigator adds failure modes
3. **Credential Configuration** - Users still need to configure some credentials via AAP UI (Galaxy tokens, AWS keys, etc.)
4. **Deletion Complexity** - Removing APD resources requires manual AAP UI steps (no API-based deletion implemented)
5. **Multiple Addons** - Seven addons instead of one (more to maintain)

### Neutral

1. **Follows APD Upstream** - Uses official playbooks unchanged
2. **AAP 2.7 Compatible** - Uses AAP 2.7 API and gateway operator
3. **Documentation Burden** - Each addon has its own README (but provides clarity)

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

### Alternative 3: Manual ansible-navigator Installation

**Description**: Require users to install ansible-navigator manually before enabling addons.

**Why Not Chosen**:
- User explicitly requested auto-installation
- Creates friction and reduces "just works" experience
- Inconsistent with addon pattern (addons should handle their dependencies)

**What Would Be Different**:
- Simpler deploy scripts (no installation logic)
- Clearer error messages (just check for presence)
- One more manual step for users

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

## References

- [Issue #71: Feature: Integrate `ansible/product-demos` as an Add-on](https://github.com/RedHatOfficial/aap-demo/issues/71)
- [Ansible Product Demos Repository](https://github.com/ansible/product-demos)
- [APD Documentation](https://ansible.github.io/product-demos/)
- [ADR-008: Addon System](008-addon-system.md)
- [ansible-navigator Documentation](https://ansible.readthedocs.io/projects/navigator/)
- Commit: `823863f` - Implementation on `feature/platform-demos-addon` branch
