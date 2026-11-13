# ADR-043: Addon Classification System (Certified and Community Tiers)

**Status**: Proposed

**Date**: 2026-11-13

**Authors**: aap-demo maintainers

## Context

The aap-demo project has grown to include 15+ optional addons. All currently live in a single
`addons/` directory with no formal classification. This creates several problems:

**Testing burden**: Not every addon can be tested against every AAP release — the test matrix
grows quadratically. Core maintainers are implicitly responsible for all addons, whether they
use them or not.

**Community growth**: Contributors want to share addons without committing to production-level
quality gates. New addon ideas emerge faster than the core team can maintain. No clear path
exists for community contributions that don't meet core standards yet, and users have no
template for building custom addons.

**Customer trust**: Field teams need to know which addons are Red Hat-validated. Customers
deploying aap-demo for demos need confidence that addons won't break on new AAP releases. The
flat structure treats a mature addon (portal) the same as an experiment (EDA playground).

**Maintainability**: Core team should model Ansible best practices for customers, but testing
all addons equally prevents focus on customer-impacting components. Maintainer responsibility
should be explicit, not assumed.

## Decision

Implement a **two-tier addon classification system** (Certified and Community) with separate
repositories and a plugin installation model.

**Certified tier** addons are demo-ready, tested with each AAP release, maintained by core
team, and meet strict quality standards:

- **Testing**: Pass four test categories before each AAP release: enable/disable lifecycle,
  AAP integration, cross-platform (where applicable), and idempotency
- **Maintenance**: Named core maintainer commits to responding to issues, updating for AAP
  versions, and reviewing contributions
- **Documentation**: README with purpose/prerequisites/usage, troubleshooting guidance,
  integration notes, and ADR for architectural decisions

**Community tier** addons are functional contributions from the broader community —
experiments, POCs, or niche use cases maintained on a best-effort basis. They may be promoted
to Certified via an issue request and maintainer approval.

**Repository structure**: Three repositories — Certified (core tested addons), Community
(community contributions), and Template (GitHub template for creating new addons). Repository
naming deferred to implementation.

**Installation**: Plugin/package system where certified addons install directly
(`aap-demo enable <name>`) and community addons require adding a source first
(`aap-demo addon install <source>`). Implementation details deferred.

**Migration**: All existing addons in `addons/` undergo case-by-case review against Certified
tier criteria and are assigned to appropriate tier.

**Out of scope**: Ansible CaC quality requirements (separate ADR planned), repository naming,
plugin system implementation details, community maintenance model, detailed documentation
requirements, and timeline.

## Consequences

### Positive

- Users know which addons are tested and maintained — deploying demos can trust certified
  addons won't break on new AAP releases
- Test matrix limited to certified addons — core team focuses resources on customer-impacting
  components, explicit ownership replaces implicit responsibility
- Lower barrier for community contributions — new ideas can be community addons first,
  promoted when mature. Addon template reduces friction. Users can build and share custom
  addons for their environments
- Field teams can confidently use certified addons in demos

### Negative

- **Fragmentation**: Multiple repos make addon discovery harder. Users must manage addon
  sources. Moving existing addons could break workflows. Guides must reference multiple repos
- **Maintenance burden**: PRs, issues, and releases across three repos. Building and
  maintaining plugin system. Case-by-case review overhead for existing addons and promotion
  requests. Template maintenance as standards evolve
- Community tier might be seen as "second-class" or unsupported. Maintainer approval for
  promotion could slow growth. Extra installation steps for community addons might discourage
  adoption

### Neutral

- Implementation details deferred (naming, timeline, plugin system) allows phased approach —
  can start with classification criteria, add repos/plugin system later
- All existing addons require case-by-case review; none automatically certified or demoted

## Alternatives Considered

### Single repo with metadata tags

Keep all addons in the `addons/` directory, mark tier via metadata file or header comments.

Rejected: Not clear enough separation — users must read metadata to know tier. Testing matrix
still includes all addons unless CI explicitly filters. No clean way to separate maintenance
responsibility. Community contributions clutter main repo with experimental code.

### No classification system

Continue current approach: all addons in one repo, no formal tiers or testing requirements.

Rejected: Doesn't solve testing burden — matrix grows with every addon. No quality signal to
users. Discourages community contribution (high bar for inclusion). Doesn't scale as addon
count grows.

### All certified, no community tier

Require all addons to meet certified quality bar or be removed.

Rejected: Kills community contribution and experimentation. Forces maintainers to reject
useful addons or commit to maintaining them. No space for POCs or niche use cases. Doesn't
enable ecosystem growth.

## References

- [ADR-008](008-addon-system.md): Original addon system architecture
- [ADR-014](014-testing-strategy.md): CLI testing strategy
- [ADR-040](040-addon-framework-and-bash-fallback.md): Shared addon framework and bash fallback
- Future ADR: Ansible CaC requirements for addons
- Future: Repository naming, plugin system implementation
