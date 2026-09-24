# ADR-025: Portal Operator CPU Preflight Check

**Status**: Accepted

**Date**: 2026-09-18

**Authors**: Chris Hammer

## Context

Enabling the `portal-operator` addon on a single-node CRC/MicroShift cluster can leave the
`AutomationPortal` resource stuck in `Pending` even when live CPU usage is low. The Kubernetes
scheduler uses declared CPU **requests**, not live consumption, to decide whether a pod can be
placed. On a typical demo cluster running AAP + Automation Orchestrator + optional addons, nearly
all allocatable CPU is already reserved by request:

| Namespace | Approximate CPU requests |
|---|---:|
| `aap-operator` | ~3310m |
| `automation-orchestrator` | ~1980m |
| `aap-demo-ollama` (if enabled) | ~1000m |

The portal operator deployment adds:

| Component | CPU request | Notes |
|---|---:|---|
| `portal-operator` controller | 100m | always |
| PostgreSQL | 250m | initial scheduling blocker |
| Backstage | 1250m | main portal pod |
| Backstage (rollout duplicate) | 1250m | temporary; created during any rollout |

The PostgreSQL pod (250m) was the first to fail with
`0/1 nodes are available: 1 Insufficient cpu` in observed failures. Scaling Ollama to zero
freed ~1000m of reserved CPU and unblocked the install.

Because the scheduler uses requests rather than live consumption, a node can appear healthy
under `kubectl top` while still being unable to place new pods. The gap between observed usage
(~17% on an 8-CPU node) and reserved requests (~98%) is large enough to surprise operators.

## Decision

Add a `cpu_preflight()` function to `addons/portal-operator/deploy.sh` that runs before any
cluster state is modified. It measures headroom, warns when headroom is low, and offers a
non-destructive interactive prompt to scale down Ollama.

### Thresholds

Two thresholds derived from the per-pod request data in issue #148:

| Threshold | Value | Rationale |
|---|---:|---|
| `PORTAL_MIN_CPU_M` | 1600m | PostgreSQL (250m) + Backstage (1250m) + controller (100m) |
| `PORTAL_ROLLOUT_CPU_M` | 2850m | `PORTAL_MIN_CPU_M` + Backstage rollout duplicate (1250m) |

- Headroom ≥ 2850m: green, proceed silently.
- Headroom 1600–2849m: amber warning — initial install should succeed but a Backstage rollout
  (e.g. on re-enable or upgrade) may stall. Prompt to scale Ollama.
- Headroom < 1600m: red warning — PostgreSQL is likely to fail scheduling. Prompt to scale Ollama.

### CPU measurement

```bash
# Allocatable millicores (handles "8" or "8000m" output)
kubectl get node -o jsonpath='{.items[0].status.allocatable.cpu}'

# Sum of all Running pod CPU requests across all namespaces
kubectl get pods -A --field-selector=status.phase=Running -o json \
  | jq '[.items[].spec.containers[].resources.requests.cpu // "0"]
        | map(if test("m$") then gsub("m$";"") | tonumber
              else tonumber * 1000 end)
        | add // 0'
```

Init containers are excluded — they do not run concurrently with the main containers and are
not counted by the Kubernetes resource quota for running pods.

### Interactive remediation

When headroom is amber or red, the function checks whether `deployment/ollama` in namespace
`aap-demo-ollama` has `replicas > 0`. If yes, it prompts:

```
Ollama is running and reserves ~1000m CPU.
Scale Ollama to 0 to free CPU for the portal? [y/N]:
```

If the user answers yes, the function runs:

```bash
kubectl scale deployment/ollama -n aap-demo-ollama --replicas=0
```

Then re-measures headroom and reports the new value. If headroom is still below
`PORTAL_ROLLOUT_CPU_M` after scaling (or if the user declines), the install continues with a
trailing warning.

No other workloads are modified. AO workers and catalog source pods are operator-managed and
must not be patched by this function.

### Escape hatch

Setting `SKIP_CPU_PREFLIGHT=1` bypasses the check entirely. This is intended for CI
environments and expert users who have already managed CPU reservations manually.

### Placement in deploy.sh

`cpu_preflight()` is called from `main()` after `require_amd64_cluster` and before
`setup_namespace`, so it runs before any namespace, secret, or operator resource is created.

### Documentation

`addons/portal-operator/README.md` gets a note recommending ≥ 8 CPUs for CRC when running
AAP + AO + portal together, and documents the `SKIP_CPU_PREFLIGHT=1` escape hatch.

## Consequences

### Positive

- Operators see a clear explanation when scheduling fails instead of a cryptic
  `Insufficient cpu` event buried in `kubectl describe pod`.
- The Ollama scale-down is non-destructive: the operator remains, the model stays, and
  `aap-demo enable ollama` restores it.
- Headroom is re-reported after scaling so the operator knows whether the install is likely
  to succeed.
- The check is idempotent and safe to run multiple times (e.g. on re-enable).

### Negative

- The 1600m and 2850m thresholds are derived from a single observed cluster snapshot and
  may drift as the portal operator image changes CPU requests.
- The check only identifies Ollama as a scalable workload; other optional reservations
  (duplicate catalog source pods, AO workers) require manual action.
- On multi-node clusters the per-node headroom picture would require summing per-node
  allocatable vs per-node requests; the current implementation uses the first node, which
  is correct for single-node CRC but approximate otherwise.

### Neutral

- The portal operator install is not blocked even if headroom remains insufficient —
  the user receives a warning and the install proceeds. Kubernetes will queue the
  pending pod and schedule it once capacity is released.
- The `SKIP_CPU_PREFLIGHT=1` escape hatch means the gate has no effect in automated
  pipelines that set it.

## Alternatives Considered

**Block the install when headroom < PORTAL_MIN_CPU_M**: Provides a hard gate but may
frustrate users whose cluster is borderline or who know Ollama will free up soon. Rejected
in favour of warn-and-prompt so the install always reaches a schedulable state after the
interactive step.

**Shared `includes/cpu-preflight.sh` library**: Would allow other addons to reuse the
headroom logic. Rejected as premature — portal-operator is the only addon that needs this
today. Extract to a shared library when a second caller appears.

**Gate at `cmd_enable` in `aap-demo.sh`**: Keeps the check in the central dispatcher but
couples deployment detail to the main script and makes `deploy.sh` incomplete when run
directly. Rejected in favour of keeping the check self-contained in the addon.

## References

- [Issue #148](https://github.com/RedHatOfficial/aap-demo/issues/148)
- [`addons/portal-operator/deploy.sh`](../../addons/portal-operator/deploy.sh)
- [`addons/portal-operator/README.md`](../../addons/portal-operator/README.md)
- [`addons/ollama/deploy.sh`](../../addons/ollama/deploy.sh)
