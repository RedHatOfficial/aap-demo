# ADR-029: CLI Reliability Foundation

**Status**: Accepted

**Date**: 2026-10-07

## Context

The CLI orchestrates CRC, Kubernetes resources, operators, and addons. Mutating commands
previously had no cross-process coordination, readiness logic was duplicated, and several
required lifecycle operations suppressed failures. Status and diagnostics also calculated
VM disk usage through different data sources, producing contradictory output.

## Decision

Introduce three shared reliability modules:

- `includes/operation-lock.sh` uses an atomic directory lock for mutating commands. It
  reports the owning PID, command, and start time; dead-owner locks are removed safely.
- `includes/kubernetes-readiness.sh` provides reusable Deployment and DaemonSet rollout
  checks with bounded timeouts and failure diagnostics.
- `includes/resource-preflight.sh` streams Kubernetes JSON through `jq` to calculate
  scheduler-aware CPU and memory requests. It accounts for the larger of regular-container
  sums and init-container maxima, and excludes unscheduled pods.

Resource preflight warns by default to preserve local-development workflows. Automation
can set `AAP_RESOURCE_PREFLIGHT_STRICT=true` to fail when recommended CPU or memory
headroom is unavailable. `AAP_RESOURCE_PREFLIGHT_SKIP=true` explicitly bypasses the check.
The read-only `aap-demo preflight` command combines those capacity calculations with
tool, infrastructure state, Kubernetes connectivity, architecture, storage, VM disk,
and operator catalog checks.

VM disk reporting and deployment disk checks use the same `/var` filesystem metric from
the cluster host. Status labels the physical host and CRC guest operating systems
separately.

Required CRC start/stop, CoreDNS recovery, gateway patch, addon disable, and shared
rollout failures now propagate instead of returning success-shaped results.

## Consequences

### Positive

- Concurrent mutating commands cannot race on cluster or addon state.
- Stale locks recover without manual deletion.
- Required lifecycle failures produce nonzero exits suitable for automation.
- Resource pressure is visible before large installations begin.
- Readiness failures include relevant Kubernetes diagnostics.
- Status and diagnose agree on VM disk usage.
- Automation can validate prerequisites without changing cluster state or taking the
  mutation lock.
- Deterministic lifecycle fault injection and the opt-in live idempotency harness cover
  failure propagation and repeated convergence.

### Negative

- A crashed process can leave a lock directory until the next mutating invocation removes it.
- Strict preflight thresholds are recommendations, not a complete scheduler simulation.
- Operator-specific readiness still remains in individual addon implementations.

## Follow-up

Future reconciliation work should reuse these modules, move remaining addon-specific waits
onto shared helpers, and introduce explicit ready/degraded state reporting.
