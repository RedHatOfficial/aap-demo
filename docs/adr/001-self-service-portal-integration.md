# ADR-001: Self-Service Portal Integration

**Status**: Accepted

**Date**: 2026-06-18

**Authors**: DevOps Automator (AI), Chad Ferman

## Context

AAP 2.7 introduced a Self-Service Automation Portal that enables end users to request and manage automation workflows without deep Ansible knowledge. The portal provides a catalog-driven interface for workflow consumption.

aap-demo provides a rapid deployment tool for AAP on OpenShift Local, primarily targeting development, testing, and demonstration scenarios. Users needed a simple way to deploy AAP with the portal enabled for:

- **Demo scenarios**: Showcasing self-service automation capabilities to stakeholders
- **Development**: Building and testing portal integrations and custom catalogs
- **Training**: Learning portal administration and workflow publishing

The existing deployment approach used Custom Resource (CR) templates in `config/crs/` with component-specific configurations. The standard `aap-minimal.yaml` enabled controller, hub, and EDA but did not include the portal component.

### Problem Statement

Users who wanted to test or demonstrate the Self-Service Portal had to:

1. Manually modify CR YAML files to add `portal.disabled: false`
2. Understand AAP operator CR structure
3. Patch existing deployments with kubectl commands
4. Lack documentation on portal-specific requirements

This created friction for a common use case and increased the barrier to entry for portal exploration.

## Decision

We will add native Self-Service Portal support to aap-demo through:

### 1. Portal-Enabled CR Template

Create `config/crs/aap-with-portal.yaml` following the established AAP component pattern:

```yaml
spec:
  controller:
    disabled: false
  eda:
    disabled: false
  hub:
    disabled: false
  portal:
    disabled: false  # New component
```

This leverages the AAP operator's existing component management where `disabled: false` enables a component and the operator handles all deployment details (pods, services, routes, database schema, RBAC).

### 2. Dedicated `aap-demo portal` Command

Implement a new subcommand that:

- Deploys AAP with the portal-enabled CR by default (`CR=with-portal`)
- Follows existing deployment patterns (cluster verification, OLM check, namespace setup)
- Provides intelligent feedback for existing deployments with patch suggestions
- Maintains consistency with other aap-demo commands

### 3. Documentation Integration

Add portal documentation to:

- **Quick Start**: Show `aap-demo portal` alongside `aap-demo deploy`
- **Features Section**: Explain portal capabilities and use cases
- **Common Commands**: Include portal deployment examples
- **Manual Enablement**: Document kubectl patch for existing deployments

### Implementation Approach

**CR Pattern Consistency**: Follow existing AAP component structure where each component (controller, hub, eda, portal) uses `disabled: true/false` toggle.

**Operator Delegation**: Let the AAP operator manage all portal deployment details rather than implementing portal-specific logic in aap-demo. This ensures:

- Compatibility with operator updates
- Consistency with production deployments
- Reduced aap-demo maintenance burden

**User Experience**: Make portal deployment as simple as `aap-demo portal` while providing escape hatches for advanced scenarios (manual CR specification, existing deployment patching).

## Consequences

### Positive

- **Simplified Portal Deployment**: Single command (`aap-demo portal`) deploys complete AAP with portal
- **Demo Readiness**: Portal-enabled deployments become trivial for sales/training scenarios
- **Pattern Consistency**: Portal follows same CR pattern as other AAP components
- **Low Maintenance**: Operator handles complexity; aap-demo just sets `disabled: false`
- **Documentation**: Clear path for portal enablement documented in README
- **Flexibility**: Users can still use custom CRs or patch existing deployments

### Negative

- **Resource Overhead**: Portal adds ~2GB memory requirement (documented in limitations)
- **Operator Dependency**: Requires AAP operator 2.7+ (already a requirement for AAP 2.7)
- **Additional CR Template**: One more file to maintain in `config/crs/`
- **Testing Surface**: New command requires validation across deployment scenarios

### Neutral

- **Storage Requirements**: Portal uses shared PostgreSQL; no additional PVC needed (RWX still recommended for hub)
- **Authentication**: Portal uses existing AAP gateway credentials (no new auth mechanism)
- **Network**: Portal route auto-created by operator (follows existing route pattern)

## Alternatives Considered

### Alternative 1: Patch-Only Approach

**Description**: Don't create new CR or command; document kubectl patch only

**Why Not Chosen**:

- Increases barrier to entry for non-Kubernetes experts
- Doesn't align with aap-demo's "one command" philosophy
- Manual patching error-prone for users unfamiliar with CR structure
- Misses opportunity to provide curated portal-enabled template

### Alternative 2: Enable Portal by Default in `aap-minimal.yaml`

**Description**: Add `portal.disabled: false` to the standard deployment

**Why Not Chosen**:

- Increases memory requirements for all deployments (not all users need portal)
- Breaks existing deployments expecting minimal configuration
- Removes user choice; some scenarios only need controller/hub
- Resource-constrained environments (8GB RAM) might struggle

### Alternative 3: Command Flag Instead of Dedicated Subcommand

**Description**: `aap-demo deploy --with-portal` instead of `aap-demo portal`

**Why Not Chosen**:

- Less discoverable (`aap-demo help` would show as sub-option)
- Doesn't align with existing command structure (deploy, status, clean are verbs/nouns)
- Harder to document in quick-start (conditional flag vs. simple command)
- Makes `aap-demo deploy` more complex over time as components grow

### Alternative 4: Interactive Prompt During Deploy

**Description**: Ask "Enable Self-Service Portal? [y/N]" during `aap-demo deploy`

**Why Not Chosen**:

- Breaks automation/CI scenarios requiring non-interactive deployment
- Adds complexity to deployment flow
- Users might not know if they need portal at deployment time
- Easier to add component later than during initial deployment

## References

- [GitHub Issue #18](https://github.com/RedHatOfficial/aap-demo/issues/18) - Original feature request
- [AAP 2.7 Portal Docs](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.7/install-assembly_self_service_about) - Official Red Hat documentation
- [AAP Operator Customization](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/installing_on_openshift_container_platform/assembly-operator-customize-aap) - Component configuration patterns
- [PORTAL_IMPLEMENTATION.md](/PORTAL_IMPLEMENTATION.md) - Detailed implementation guide
- Commits: `fec6ab1` (implementation), `9a8fd86` (documentation)

## Related Decisions

- **Future ADR**: Portal-only deployment (controller/eda disabled) for pure self-service scenarios
- **Future ADR**: Custom portal configuration (resource limits, replicas, custom catalogs)
- **Future ADR**: Portal addon system integration (enable portal post-deployment)
