# ADR-029: Windows Feature Parity Strategy

<!-- markdownlint-disable MD013 -->

**Status**: Proposed

**Date**: 2026-09-26

**Authors**: aap-demo maintainers

## Context

aap-demo maintains a Bash CLI for macOS/Linux and a PowerShell CLI for
Windows. The earlier Windows parity work tracked [PR #95](https://github.com/RedHatOfficial/aap-demo/pull/95),
but the repository has since added several addon families and lifecycle
behaviors:

- AO GA, LLM provider selection, auto-wiring, and agentic workflow model binding;
- APME, local-cache, Product Demos, OPA, Ollama, and the operator-based portal;
- CRC version checks, catalog fallbacks, readiness handling, and newer status paths.

The PowerShell registry and dispatcher have not kept pace. The Windows CLI
advertises `start` without a handler, has no `wire` command, exposes only a
subset of addons, and invokes Bash addon scripts without a single supported
contract for Windows paths, environment variables, arguments, or cleanup
options. A full native rewrite of every addon would delay parity and duplicate
complex Bash logic.

Fleet is optional host-side VM infrastructure with a separate lifecycle and is intentionally excluded from this parity increment.

## Decision

Keep the two platform entry points, but define a clear ownership boundary:

1. **PowerShell owns the core Windows lifecycle.** Cluster creation, start/stop,
   kubeconfig synchronization, deploy, status, diagnostics, cleanup, and
   repair remain native PowerShell operations.
2. **A single PowerShell addon adapter runs non-fleet addon deployment scripts.**
   Addons continue to own their Bash implementation, while the adapter supplies
   Git Bash discovery, kubeconfig and CA propagation, Windows-to-Git-Bash path
   conversion, argument forwarding, exit-code handling, and safe addon-state
   persistence.
3. **The Windows addon registry mirrors the current Bash addon surface, excluding
   fleet.** It includes the AO alias, APME, local-cache, Product Demos
   base/aggregate/domain addons, OPA, Ollama, MCP, both portal paths, and PAH
   setup. Dependencies and purge flags are forwarded instead of reimplemented
   in the dispatcher.
4. **`start` and `wire` are first-class PowerShell commands.** `start` restores
   cluster access and DNS state; `wire` runs the same idempotent integration
   setup used after deploy, watch, and addon enablement.
5. **Status and diagnostics report parity-oriented state.** They show the
   expanded addon registry, route/readiness hints, wiring failures, CRC
   compatibility, and actionable missing-tool errors without printing
   credentials.
6. **Fleet remains out of scope.** No fleet registry entry, QEMU prerequisite
   flow, fleet lifecycle hook, or Windows fleet implementation is part of this
   decision.

This keeps the critical Windows path native, avoids a second implementation of
addon business logic, and gives future native addon ports a stable adapter
boundary.

## Consequences

### Positive

- Windows users receive the current addon and lifecycle surface without requiring a complete rewrite.
- Argument, environment, cleanup, and failure semantics become consistent across PowerShell and Bash.
- New Bash addons can be exposed on Windows through one adapter while native implementations are evaluated separately.
- `start` and `wire` become reliable recovery paths after CRC restarts and addon reconciliation.
- Fleet remains isolated from the parity work and cannot expand its host-VM risk or test matrix.

### Negative

- Git Bash remains a prerequisite for addon scripts that have no native PowerShell implementation.
- Two CLI implementations still require coordinated changes and parity tests.
- Windows path and quoting conversion at the Bash boundary adds adapter complexity.
- Some addons, especially APME, portal-operator, and Ollama, still need
  Windows/CRC integration coverage before they can be treated as stable.

### Neutral

- The Bash addon scripts remain the source of truth for addon deployment logic in this increment.
- Core Windows commands continue to use `oc` and CRC rather than `kubectl`.
- Fleet can be addressed later by a separate ADR and feature branch.

## Alternatives Considered

### Port every addon to native PowerShell immediately

Rejected for this increment. It duplicates substantial shell, API, Helm,
Ansible, and credential logic and would delay the parity work while increasing
long-term drift.

### Run the entire Bash CLI through Git Bash on Windows

Rejected. It would remove native PowerShell lifecycle behavior, weaken Windows
path and certificate handling, and make CRC/Hyper-V failures harder to
diagnose.

### Generate the PowerShell registry dynamically from Bash at runtime

Rejected. Runtime parsing couples user-facing help and validation to Bash
implementation details and makes failures harder to reason about. The registry
should be explicit and reviewed when addons change.

### Include fleet in the parity branch

Rejected. Fleet has host-side QEMU lifecycle, image, SSH, and AAP registration
concerns that need a separate Windows design and validation plan.

## References

- [PR #95 — bring PowerShell CLI and Windows addons to Bash
  parity](https://github.com/RedHatOfficial/aap-demo/pull/95)
- [ADR-010 — Cross-Platform CLI](010-cross-platform-cli.md)
- [ADR-014 — CLI Testing Strategy](014-testing-strategy.md)
- [ADR-021 — Local Cache Addon](021-local-cache-addon.md)
- [ADR-022 — APME Pre-Built Portal Hub Deployment](022-apme-prebuilt-portal-hub.md)
- [ADR-023 — Addon Auto-Wiring](023-addon-auto-wiring.md)
- [ADR-024 — Ollama Addon](024-ollama-addon.md)
- [ADR-025 — Portal Operator CPU Preflight](025-portal-operator-cpu-preflight.md)
- [ADR-026 — Fleet Addon](026-fleet-addon.md) (explicitly out of scope)
