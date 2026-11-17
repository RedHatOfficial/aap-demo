# ADR-043: Native V2 Migration of Non-AO Bash Addons

**Status**: Proposed

**Date**: 2026-11-17

**Authors**: aap-demo maintainers

**Extends**: [ADR-040](040-addon-framework-and-bash-fallback.md)

## Context

ADR-040 provides a Python `Addon` interface and a bash fallback so the new
command can run legacy installers. The fallback is a compatibility step, not
the desired long-term implementation: it keeps addon behavior outside Python,
duplicates lifecycle assumptions, and makes native testing and status handling
inconsistent.

The repository has many addon directories with `deploy.sh`. They have different
resource ownership, credentials, external tools, and cleanup rules, so migrating
them in one branch would make failures difficult to isolate. The AO addon is
already being handled by Adam and `ao-pr-testing` depends on the AO V2 contract.

## Decision

Migrate each non-AO bash addon to a native Python V2 implementation, one addon
per feature branch and pull request. Each branch is named
`feature/<addon>-v2`, adds one registry entry and native `Addon` class, and has
its own focused unit tests and disposable-cluster smoke test.

In scope: `apme-eap`, `devspaces`, `eda-playground`, `keycloak`, `local-cache`,
`mcp-server`, `ollama`, `olm`, `opa`, `portal`, `portal-operator`, `registry`,
`setup-pah`, `subscription-attach`, `product-demos-base`, `product-demos`, and
the six product-demo domain addons.

`fleet` and `monitoring` are already native. `ao` and `ao-eap` are excluded from
this series. `ao-pr-testing` is deferred until Adam's AO V2 interface is merged.

Native implementations use `AppContext`, the existing runner seams,
`aap_demo.addons.common`, and the shared addon state helpers. They must preserve
the bash installer's user-visible behavior, resource ownership, local state,
defaults, and cleanup boundaries. They must not shell out to `deploy.sh`.

The legacy directories remain available to the older command and are retained
as behavioral references. If a shared helper is missing, it is added in a
separate common-framework PR before the addon branch continues. Product-demo
domain branches start after `product-demos-base` is merged.

## Testing and merge gate

Every branch tests registry registration, enable, repeat enable, disable,
destroy, status, failure-state preservation, cleanup ownership, secret
redaction, and relevant tool/platform prerequisites. It then runs the full
Python unit suite, Ruff, format checks, `git diff --check`, and an opt-in live
smoke test that enables, inspects, re-enables, disables, and verifies cleanup.

No branch may include another addon migration or commit directly to `main`.
All commits are signed.

## Consequences

### Positive

- Each addon can be reviewed, tested, reverted, and released independently.
- Native V2 lifecycle behavior becomes consistent and reusable through the
  shared Python framework.
- Failures are localized to an addon branch instead of obscured by a large
  cross-addon migration.
- The older bash command continues to work while ports land incrementally.

### Negative

- The series creates many branches and pull requests.
- Product-demo domains temporarily depend on the base-addon migration.
- Some ports require live credentials or external services for full validation.
- Native ports may expose behavior differences that require addon-specific ADRs.
