# ADR-003: Infrastructure Backend Selection

**Status**: Accepted

**Date**: 2026-07-02

**Authors**: aap-demo maintainers

## Context

AAP requires an OpenShift-compatible API surface: Routes, Security Context Constraints (SCCs),
Operator Lifecycle Manager (OLM), and CRD-based operators. Developers run aap-demo on macOS,
Linux, and Windows with varying resource budgets.

Options evaluated:

| Backend | Platform | VM overhead | OpenShift fidelity |
|---------|----------|-------------|-------------------|
| CRC MicroShift | macOS, Linux, Windows | Yes (~10 system pods) | API subset, fast |
| CRC OpenShift | macOS, Linux, Windows | Yes (~96 system pods) | Full OCP |
| MINC (Podman container) | Linux only | No | Same API subset as MicroShift |
| External lab cluster | Any | None (remote) | Varies |

## Decision

**CRC MicroShift is the default and primary supported backend.** The infrastructure layer uses a
dispatch pattern (`includes/infra-api.sh` → `includes/infra-crc.sh`) so additional backends can
be added without rewriting the CLI.

### CRC presets

During `aap-demo create`, users choose:

| Preset | Use when |
|--------|----------|
| **microshift** (default) | Day-to-day AAP dev; fastest startup; ~16 GB RAM |
| **openshift** | DevSpaces, OperatorHub, full OCP operator ecosystem |

Selection persists as `CRC_PRESET` in `~/.aap-demo/config`.

### Resource defaults

| Setting | Default | Env override |
|---------|---------|--------------|
| CPUs | 8 | `CRC_CPUS` |
| Memory | 16 GiB | `CRC_MEMORY` |
| Disk | 100 GiB | `CRC_DISK` |
| LVMS PV reservation | 70 GiB | `CRC_PV_SIZE` |

### Backend abstraction

```text
aap-demo command
      │
      ▼
infra-api.sh  ──dispatch──▶  infra-crc.sh
  infra_exec_cmd()            SSH to CRC VM (port 2222)
  infra_get_kubeconfig()      ~/.crc/machines/crc/kubeconfig
  infra_copy_to/from()        scp + sudo on VM
```

`INFRA_TYPE` defaults to `crc`. The abstraction was designed for `minc` and `lab` backends;
only CRC is implemented in this repository today.

### MINC status

[environment-comparison.md](../environment-comparison.md) documents MINC (MicroShift in Podman,
Linux-only) as a lightweight alternative. MINC is **not currently implemented** in `includes/` —
documentation reflects a planned or legacy path. Linux users should use CRC MicroShift unless/until
`infra-minc.sh` lands.

### External / lab clusters

Users with an existing OpenShift cluster can skip `create` and point `KUBECONFIG` at their
cluster. Deploy logic (OLM, CatalogSource, Subscription, AAP CR) runs against any cluster
meeting prerequisites. `config/manifests/aap-ingress.yaml` supports vanilla Kubernetes with a
manual Ingress when Routes are unavailable.

## Consequences

### Positive

- CRC is Red Hat-supported, cross-platform, and matches AAP certification targets
- MicroShift preset minimizes resource use while preserving Routes + SCCs + OLM
- Infra abstraction isolates SSH/kubeconfig details from deploy logic
- OpenShift preset available without a separate tool

### Negative

- CRC requires Hyper-V (Windows) or virtualization (macOS/Linux) — not container-only
- MINC documentation may confuse users until implementation catches up
- Switching backends requires `destroy` + re-`create` — no in-place migration

### Neutral

- Laptop architecture (arm64 vs amd64) affects portal image profiles (ADR-002) but not backend choice
- Remote x86 clusters work from ARM laptops via `KUBECONFIG`

## Alternatives Considered

### MINC as default on Linux

Deferred: CRC provides a more consistent cross-platform experience; MINC backend not yet implemented.

### kind / k3s only

Rejected: no native Routes, SCCs, or OLM — insufficient for operator-based AAP.

### Single OpenShift preset only

Rejected: full OCP is overkill for most AAP component testing (~96 vs ~10 system pods).

## References

- [environment-comparison.md](../environment-comparison.md)
- [includes/infra-api.sh](../../includes/infra-api.sh)
- [includes/infra-crc.sh](../../includes/infra-crc.sh)
- [includes/crc-create.sh](../../includes/crc-create.sh)
- [ADR-001](001-project-cli-architecture.md)
