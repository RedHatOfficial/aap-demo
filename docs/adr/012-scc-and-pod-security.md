# ADR-012: Security Context Constraints and Pod Security

**Status**: Accepted

**Date**: 2026-07-02

**Authors**: aap-demo maintainers

## Context

OpenShift enforces **Security Context Constraints (SCCs)** and **Pod Security Admission (PSA)**
labels. AAP operator workloads, OLM bundle unpack jobs, NFS, and portal pods require elevated
permissions beyond the `restricted` default.

MicroShift applies SCCs like full OpenShift but runs on a single node with no separate worker
pool — misconfiguration blocks entire deploy.

## Decision

Grant SCCs at the **namespace ServiceAccount group level** and set namespace PSA labels to
**`privileged`** for AAP and addon namespaces.

### AAP namespace (default `aap-operator`)

Applied during `aap-demo deploy`:

```bash
oc adm policy add-scc-to-group anyuid system:serviceaccounts:<namespace>
oc adm policy add-scc-to-group privileged system:serviceaccounts:<namespace>

kubectl label namespace <namespace> \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged
```

**Rationale:**

| SCC | Needed for |
|-----|------------|
| `anyuid` | AAP components running as non-root UIDs not in default range |
| `privileged` | OLM bundle unpack (seccomp annotations), some init containers |

### NFS namespace (`nfs-storage`)

```bash
oc adm policy add-scc-to-group privileged system:serviceaccounts:nfs-storage
```

NFS server pod requires privileged mount capabilities.

### Portal namespace (`redhat-rhaap-portal`)

Same `anyuid` + `privileged` group grants and PSA labels as AAP namespace (ADR-004).

### Registry namespace

`clusterrolebinding` for `anyuid` on registry ServiceAccount (in-cluster registry pushes).

### Diagnostics

`aap-demo diagnose` verifies:

- Both SCC rolebindings exist for target namespace
- PSA `enforce=privileged` label present
- Outputs fix commands when missing

### sysctl tuning

CRC VM configures elevated `inotify` limits (`max_user_instances`, `max_user_watches`) —
critical for operator performance on constrained VMs. Applied via SSH during create.

## Consequences

### Positive

- AAP operator pods schedule reliably on MicroShift
- OLM CSV install completes (bundle unpack succeeds)
- NFS and portal addons work without per-SA SCC patches
- Diagnose catches most SCC/PSA misconfigurations early

### Negative

- `privileged` PSA is inappropriate for production multitenant clusters — **dev-only pattern**
- Broad group-level SCC grants are coarser than per-ServiceAccount bindings
- Security scanners will flag these namespaces

### Neutral

- Production OpenShift uses namespace-specific SCC strategies tuned by admins
- SCC grants persist until explicitly removed

## Alternatives Considered

### Per-ServiceAccount SCC only

Rejected: operator creates many SAs dynamically; group-level is maintainable for demo.

### Custom SCC with minimal caps

Rejected: high effort; operator and OLM expect standard SCCs.

### Disable PSA labels

Rejected: enforcement would still block pods on newer OpenShift/MicroShift.

## References

- [aap-demo skill](../../.claude/skills/aap-demo/SKILL.md) — Known Fixes table
- [ADR-006](006-storage-architecture.md) — NFS privileged
- [ADR-009](009-aap-operator-olm-deployment.md) — namespace prep
- [ADR-004](004-portal-helm-addon.md) — portal SCCs
