# ADR-027: Low-Resource Automation Orchestrator Replicas

**Status**: Proposed

**Date**: 2026-09-24

**Authors**: aap-demo maintainers

## Context

The Automation Orchestrator operator defaults its backend, UI, and worker to two
replicas each. That improves redundancy, but it reserves additional CPU and
memory on the single-node CRC/MicroShift clusters used by this repository. The
extra reservations can prevent other parts of a local AAP demo from scheduling,
even when live resource usage appears low.

Issue [#171](https://github.com/RedHatOfficial/aap-demo/issues/171) originally
requested an opt-in one-replica mode while preserving the two-replica default.
This repository is a development/demo environment, so the local product
decision is to make the resource-saving profile the default and retain the
two-replica configuration as an explicit opt-out.

The replica settings must remain in the operator-managed
`AutomationOrchestrator` custom resource. Directly scaling generated
Deployments would be overwritten by the operator and would make the CR stop
being the source of truth.

## Decision

Render explicit replica counts in the checked-in
[`AutomationOrchestrator` CR template](../../addons/ao/manifests/automationorchestrator-cr.yaml):

- `AO_LOW_RESOURCE` unset, `1`, or `true`: one backend, one UI, and one worker
  replica. This is the default for local development and demos.
- `AO_LOW_RESOURCE=0` or `false`: two backend, two UI, and two worker replicas.
  This is the explicit higher-resource/redundancy profile.

The addon substitutes the selected integer into the CR and applies it with
`kubectl`. It must not use `kubectl scale` or patch the generated backend, UI,
or worker Deployments.

Changing profiles on an existing install is done by rerunning
`aap-demo enable ao` with the desired environment variable. The addon reapplies
the CR and waits for the resource to report `Ready=True` without deleting the
database or requiring `FORCE=1`. `FORCE=1` remains the explicit reinstall path.

The one-replica default is not highly available and is not intended for
production or HA validation.

## Consequences

### Positive

- Local CRC/MicroShift clusters reserve less CPU and memory for AO by default.
- The default better fits the resource constraints of the development/demo
  environment.
- The two-replica profile remains available when a user needs additional
  redundancy and has the capacity to support it.
- The operator-managed CR remains the single source of truth.

### Negative

- The default AO deployment has no replica-level redundancy.
- One-replica mode is unsuitable for production or HA validation.
- Users who need the previous behavior must explicitly set
  `AO_LOW_RESOURCE=0` or `false`.

### Neutral

- The operator continues to reconcile all generated Deployments.
- Switching profiles preserves the PostgreSQL cluster and AO credentials.
- The existing AO addon, OLM installation, integrations, and wiring remain
  unchanged.

## Alternatives Considered

### Directly scale the generated Deployments

Rejected because the Automation Orchestrator operator can overwrite direct
Deployment changes, and the custom resource would no longer describe the
desired state.

### Keep two replicas as the aap-demo default

Rejected for this repository because it targets development/demo clusters where
the additional reservations can prevent the rest of the demo stack from
scheduling. Two replicas remain available through an explicit opt-out.

### Add a separate manifest or addon

Rejected because a single CR template and validated profile keep the addon
surface small and make the mode reversible without duplicating the deployment
flow.

## References

- [Issue #171](https://github.com/RedHatOfficial/aap-demo/issues/171)
- [`addons/ao/deploy.sh`](../../addons/ao/deploy.sh)
- [`addons/ao/README.md`](../../addons/ao/README.md)
- [ADR-008: Addon System Architecture](008-addon-system.md)
- [ADR-014: CLI Testing Strategy](014-testing-strategy.md)
- [ADR-017: Automation Orchestrator Addon](017-ao-addon.md)
