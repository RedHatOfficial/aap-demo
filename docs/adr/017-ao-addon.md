# ADR-017: Automation Orchestrator Addon (ao)

**Status**: Accepted

**Date**: 2026-07-15 (updated 2026-08-21)

**Authors**: Chad Ferman

## Context

Automation Orchestrator (AO) is Red Hat's workflow orchestration platform. It runs as an
operator-managed application on OpenShift and can integrate with Ansible Automation Platform
(job templates, OIDC).

aap-demo needs a repeatable, scriptable way to deploy AO on **MicroShift** for development and
demos, without requiring users to obtain private Quay credentials or run multi-step manual installs.

## Decision

Add `ao` to the aap-demo addon system as [`addons/ao/deploy.sh`](../../addons/ao/deploy.sh),
invoked via `aap-demo enable ao`.

### Current install model (GA + GitOps manifests, 2026-08-21)

The addon applies **checked-in Kubernetes manifests** shaped like
[`aapctl install ao --dry-run`](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-generate_aapctl_manifests_for_gitops).
**`aapctl` is not required at install time** — only `kubectl`/`oc` and a cluster from
`aap-demo deploy`.

| Aspect | Choice |
|--------|--------|
| Addon ID | `ao` (`ao-eap` accepted as legacy alias) |
| App namespace | `automation-orchestrator` |
| Operator install | OLM `Subscription` + `OperatorGroup` (AllNamespaces) in app namespace |
| Operator catalog | Copy of `redhat-operators` CatalogSource into app namespace (MicroShift) |
| Operator channel | `stable` default (`AO_OPERATOR_CHANNEL` override) |
| Index fallback | Early-access build index when default AAP catalog lacks AO |
| PostgreSQL | CloudNativePG from upstream manifest (dev-only; not Red Hat supported) |
| Instance | `AutomationOrchestrator` CR from [`manifests/automationorchestrator-cr.yaml`](../../addons/ao/manifests/automationorchestrator-cr.yaml) |
| Database secrets | `orchestrator-postgres-secret`, `temporal-postgres-secret`, `temporal-visibility-postgres-secret` (created at install, not committed) |
| Registry auth | Copy `redhat-operators-pull-secret` → `automation-orchestrator-pull-secret` |

Manifest templates and apply order: [`addons/ao/manifests/README.md`](../../addons/ao/manifests/README.md).

User-facing guide: [`addons/ao/README.md`](../../addons/ao/README.md).

### MicroShift workarounds

| Problem | Cause | Workaround |
|---------|-------|------------|
| OLM can't resolve AO subscription | Catalog in `aap-operator`; subscription in another namespace | Copy `redhat-operators` CatalogSource into `automation-orchestrator` |
| Second OperatorGroup in `aap-operator` | AO operator requires AllNamespaces; AAP already has `aap-operator-og` | Install AO OLM resources only in `automation-orchestrator` |
| CNPG via OLM fails | No `certified-operators` on MicroShift | Install CNPG from upstream release manifest |
| Catalog signature failures | MicroShift 4.22+ GPG policy on `registry.redhat.io` | Shared [`includes/olm-catalog-signature.sh`](../../includes/olm-catalog-signature.sh): relax `policy.json`, reload CRI-O, `wait_for_catalog_ready()` with auto-recovery; `ensure_catalog_signature_policy()` before AO catalog create |
| Postgres password drift on re-run | Secret regenerated but CNPG cluster retains bootstrap password | Reuse password from existing secrets; `FORCE=1` recreates cluster |
| AO missing from default index | Index version / publish lag | Automatic `AO_FALLBACK_INDEX_IMAGE` |

### Delete flow

`deploy.sh --delete` / `aap-demo disable ao`:

1. Optional: `aapctl uninstall` if `aapctl` is on PATH
2. Remove `AutomationOrchestrator` CR and AO OLM resources
3. Delete `automation-orchestrator` namespace
4. Remove legacy EA CatalogSources if present
5. Delete CloudNativePG operator manifest (when installed by this addon)

### aap-demo.sh integration

- `ao` in `AVAILABLE_ADDONS`; `ao-eap` normalized via `_normalize_addon_name()`
- Pass-through: `--force`, `--refresh-catalog`
- `show_status`: AO route URL when enabled
- Post-install wiring via [`includes/addon-wire.sh`](../../includes/addon-wire.sh): registers global
  **AAP** and **MCP Server** integrations automatically after enable and deploy (see ADR-023).
  **`mcp-server` is a hard dependency of `ao`** — `aap-demo enable ao` enables MCP first.

## Consequences

### Positive

- Single command: `aap-demo enable ao`
- No Quay POC, no `gh`, no runtime `aapctl` dependency
- Manifests track Red Hat GitOps documentation; maintainers can refresh with `generate-manifests.sh`
- Idempotent with explicit `FORCE=1` reinstall path

### Negative

- MicroShift-specific catalog copy and CNPG path differ from stock OpenShift / `aapctl install`
- Dev-only CNPG Postgres is not production-supported
- Default `stable` channel; use `AO_OPERATOR_CHANNEL=early-access` when needed

### Neutral

- AO isolated in `automation-orchestrator`; AAP remains in `aap-operator`
- `aapctl` remains optional for uninstall cleanup and manifest regeneration

## Alternatives considered

**Runtime `aapctl install`**: Matches Red Hat interactive docs but pulls in Technology Preview
CLI, hardcoded full-OCP catalog assumptions, and non-deterministic dry-run secrets. Rejected for
default path; manifest shape retained.

**Subscription in `aap-operator`**: Matches AAP pattern but breaks OLM when two OperatorGroups
occupy the same namespace. Rejected.

**Private EA index + Quay**: Original Early Access flow. Rejected after GA operator landed in
`redhat-operator-index`.

## References

- [`addons/ao/README.md`](../../addons/ao/README.md)
- [`includes/olm-catalog-signature.sh`](../../includes/olm-catalog-signature.sh)
- [Generate aapctl manifests for GitOps](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-generate_aapctl_manifests_for_gitops)
- [Install the operator from the OpenShift CLI](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-install_the_operator_from_the_openshift_cli)
- ADR-008: Addon system
- ADR-005: OLM on MicroShift

---

## Historical note: Early Access flow (superseded 2026-08-20)

The original addon (`ao-eap`) used a private Quay index, `aapctl` end-to-end, catalog-operator
patches, and `openshift-marketplace`. That flow is **no longer the default**. Legacy state paths
(`~/.aap-demo/ao-eap-state`) are still read when present. See git history before 2026-08-21 for
the full EA install sequence.

### Amendment log

See [ADR-023](023-addon-auto-wiring.md) for the full auto-wiring design.

| Date | Change |
|------|--------|
| 2026-08-20 | GA migration: `redhat-operators` OLM path, hand-written CR |
| 2026-08-21 | Rename `ao-eap` → `ao`; GitOps manifests from `aapctl --dry-run`; MicroShift catalog in app namespace; aapctl optional at runtime |
| 2026-08-21 | Catalog signature policy: shared `olm-catalog-signature.sh` with deploy; SSH key refresh; CRI-O reload; signature pull auto-recovery |
| 2026-08-26 | Addon auto-wiring: `includes/addon-wire.sh` configures AO ↔ AAP OAuth and MCP integrations after enable |
| 2026-08-26 | Wire applies APD-style AO network access (`APP_INTEGRATION_URL_ALLOWED_HOSTS`) before integration registration on MicroShift |
| 2026-08-26 | `mcp-server` is a required dependency of `ao`; enable ao installs MCP and wire fails if MCP integration is missing |
