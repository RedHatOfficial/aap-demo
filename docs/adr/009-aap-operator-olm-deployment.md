# ADR-009: AAP Operator Deployment via OLM

**Status**: Accepted

**Date**: 2026-07-02

**Authors**: aap-demo maintainers

## Context

AAP 2.7 is distributed as the `ansible-automation-platform-operator` on the Red Hat operator
index. aap-demo must install the operator and reconcile an `AnsibleAutomationPlatform` CR using
the same mechanism as customer OpenShift deployments.

Constraints:

- Valid `registry.redhat.io` pull secret required
- Operator channel must match target AAP version (e.g., `stable-2.7`)
- Namespace needs SCCs and PSA labels before pods schedule
- Hub requires RWX storage (ADR-006)

## Decision

Deploy AAP via a **four-step OLM pipeline** triggered by `aap-demo deploy`:

```text
1. Namespace prep     → SCCs, PSA labels, pull secret copy
2. CatalogSource      → redhat-operators in target namespace
3. Subscription       → ansible-automation-platform-operator
4. AAP CR             → config/crs/aap-minimal.yaml (or variant)
```

### Manifest templates

| File | Purpose |
|------|---------|
| `config/olm/operatorgroup.yaml` | Targets operator to namespace |
| `config/olm/catalogsource.yaml` | `redhat-operator-index:v4.20` (overridable) |
| `config/olm/subscription.yaml` | Channel `stable-2.7`, automatic installPlan |
| `config/crs/aap-minimal.yaml` | Controller + EDA + Hub, nfs-local-rwx for Hub |
| `config/crs/aap-minimal-noingress.yaml` | Lab/k8s without Routes |
| `config/crs/aap-controller.yaml` | Controller-only variant |

Runtime substitution replaces namespace placeholders and adjusts Hub storage when `nfs-local-rwx` is missing.

### Namespace preparation

Before Subscription:

```bash
oc adm policy add-scc-to-group anyuid system:serviceaccounts:<namespace>
oc adm policy add-scc-to-group privileged system:serviceaccounts:<namespace>
kubectl label namespace <namespace> pod-security.kubernetes.io/enforce=privileged ...
```

Pull secret copied/created as `redhat-operators-pull-secret`.

### Deploy modes

| Command | Behavior |
|---------|----------|
| `aap-demo deploy` | Operator + AAP CR (full stack) |
| `aap-demo deploy-operator` | Subscription only |
| `aap-demo deploy-aap` | AAP CR only (operator must exist) |
| `CR=controller` | Select alternate CR manifest |

### Controller git safe-directory

`aap-minimal.yaml` sets `GIT_CONFIG_*` env vars and `fsGroup: 996` so AWX project sync works
on emptyDir volumes — a common local-dev failure mode.

### Reconciliation monitoring

- `aap-demo watch` — polls AAP CR conditions
- `aap-demo diagnose` — checks CR phase, pod health, PVC binding
- Expected deploy time: 5–15 minutes depending on preset and hardware

## Consequences

### Positive

- Matches production OpenShift install path — high fidelity
- Channel pinning enables version-specific testing
- CR variants support minimal, controller-only, and no-ingress lab setups
- `idle` patch on AAP CR scales down for resource savings

### Negative

- Requires Red Hat pull secret — barrier for contributors without subscription
- Catalog index version must align with cluster OCP version mapping
- Automatic installPlan can pull unexpected CSV if channel moves
- Bundle unpack needs privileged SCC (OLM internals)

### Neutral

- Operator manages all AAP component lifecycle after CR apply
- Multiple AAP instances possible via `NAMESPACE` override

## Alternatives Considered

### Direct manifest install without operator

Rejected: unsupported; loses upgrade and reconciliation machinery.

### Ansible installer (aap-setup)

Rejected: different target (RPM/VM installs); not OpenShift-native.

### Pin CSV manually instead of Subscription channel

Rejected: channel subscription is the supported customer path.

## References

- [config/olm/](../../config/olm/)
- [config/crs/](../../config/crs/)
- [ADR-005](005-olm-on-microshift.md)
- [ADR-006](006-storage-architecture.md)
- [ADR-012](012-scc-and-pod-security.md)
