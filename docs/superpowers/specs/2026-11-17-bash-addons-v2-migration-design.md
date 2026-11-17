---
type: Design
title: Bash addon migration to native V2 addons
description: Design for migrating legacy bash addon installers to the Python V2 addon interface on isolated feature branches.
status: draft
stale_after: 2027-05-17
---

# Bash addon migration to native V2 addons

## Outcome

Every non-AO addon that currently exposes `addons/<name>/deploy.sh` will have a
native implementation of the Python `aap_demo.addons.base.Addon` interface. Each
addon is developed and tested on its own `feature/<addon>-v2` branch. The legacy
script remains the behavioral reference during the port and is not removed until
the native implementation has passed its branch test gate.

## Scope

In scope are `apme-eap`, `devspaces`, `eda-playground`, `keycloak`, `local-cache`,
`mcp-server`, `ollama`, `olm`, `opa`, `portal`, `portal-operator`, `registry`,
`setup-pah`, `subscription-attach`, `product-demos-base`, `product-demos`, and
the six product-demo domain addons: `product-demo-cloud`, `product-demo-linux`,
`product-demo-network`, `product-demo-openshift`, `product-demo-satellite`, and
`product-demo-windows`.

`fleet` and `monitoring` are already native V2 addons and are not migration work.
`ao`, `ao-eap`, and `ao-pr-testing` are excluded: `ao` and `ao-eap` belong to
Adam's AO work, and `ao-pr-testing` is deferred until the AO V2 interface and
service contract are available.

## Design

The Python registry remains the single entry point. Each port adds one native
class in `src/aap_demo/addons/` and one registry entry in
`src/aap_demo/addons/__init__.py`. Lifecycle methods use `AppContext`, the
existing runner seams, `addons/common` helpers, and `addons.common.state` for
config persistence. The native class owns only resources that its bash installer
currently owns; it must not broaden cleanup to shared AAP or cluster resources.

The bash directory, manifests, and README stay in place as migration evidence
until the native branch passes. After merge, the script may remain as the V1
implementation for the older command, but V2 must not invoke it. Product-demo
domains share the `product-demos-base` contract but retain separate registry
names and branch/test gates.

## Branch and dependency policy

Every branch starts from the current integration branch and contains exactly one
addon migration, its tests, and the documentation needed for that addon. Branch
names use `feature/<addon>-v2`; names containing `/` are not used. The branch is
not merged until its focused tests, the full Python unit suite, lint, and the
addon live smoke test pass.

The common framework is treated as a prerequisite, not silently changed in an
addon branch. If a port reveals a missing shared helper, create a separate
`feature/addon-common-v2` branch/PR, merge it, then rebase the addon branch. The
product-demo domain branches start after the `product-demos-base` native port is
integrated. AO-dependent work starts only after Adam's AO V2 branch is merged.

## Lifecycle contract

Each native addon implements the applicable `enable`, `disable`, `destroy`, and
`status` behavior exposed by the current CLI. Re-enable is idempotent. Disable
removes addon-owned resources and preserves documented user-local configuration;
destroy removes addon-owned cluster state and saved addon state. Status is
read-only and must not require secrets to be printed. Prerequisite checks belong
in the CLI/registry metadata where possible, not duplicated in addon code.

## Testing contract

Each branch adds focused unit tests that mock `AppContext.runner` and assert:

- registry registration and canonical naming/aliases;
- enable, repeat enable, disable, destroy, and status behavior;
- exact resource ownership and cleanup boundaries;
- failure behavior and state preservation after a failed operation;
- secret and token handling without command-line or normal-output leakage;
- the relevant platform/tool prerequisite behavior.

Each branch also runs the applicable live smoke test on a disposable AAP demo
cluster: enable, verify owned resources and status, re-enable, disable, and
verify cleanup. The test record must state skipped checks when a required
external service or credential is unavailable.

## Non-goals

This migration does not redesign addon behavior, change the bash V1 command,
rewrite unrelated shared framework code, or introduce a new configuration store.
Behavior changes require a separate ADR or an addon-specific design decision.
