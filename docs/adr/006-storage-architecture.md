# ADR-006: Storage Architecture

**Status**: Accepted

**Date**: 2026-06-10

**Authors**: aap-demo maintainers

## Context

AAP components have distinct storage needs:

| Component | Access mode | Typical size |
|-----------|-------------|--------------|
| Controller (AWX) | RWO | 5–10 GiB |
| Hub (file storage) | **RWX** required for multi-replica sync | 5+ GiB |
| PostgreSQL | RWO | Operator-managed |
| EDA | RWO | Operator-managed |

MicroShift on CRC uses **LVMS** (`topolvm-provisioner`) for RWO volumes. Hub file storage
requires **ReadWriteMany**, which LVMS does not provide.

## Decision

Deploy an **in-cluster NFS server** with the NFS Subdir External Provisioner to expose
`nfs-local-rwx` StorageClass on CRC/MicroShift. Use **local-path provisioner** as the default
RWO class where LVMS is unavailable (documented MINC path).

### CRC/MicroShift stack

```text
nfs-storage namespace
  ├── nfs-server pod (privileged SCC)
  └── nfs-provisioner (external-provisioner)
           │
           ▼
    StorageClass: nfs-local-rwx (Retain, RWX)
```

Manifests: `config/manifests/nfs-server.yaml`, `config/manifests/nfs-provisioner.yaml`

NFS server IP uses `__NFS_SERVER_IP__` placeholder resolved at deploy time from the NFS Service ClusterIP.

### AAP CR storage binding

`config/crs/aap-minimal.yaml` configures Hub file storage explicitly:

```yaml
hub:
  file_storage_storage_class: nfs-local-rwx
  file_storage_access_mode: ReadWriteMany
```

Deploy logic falls back to RWO when `nfs-local-rwx` is absent (warns in output).

### LVMS PV reservation

`CRC_PV_SIZE` (default 70 GiB) reserves disk for LVMS-provisioned PVCs inside the CRC VM, separate from NFS-backed RWX volumes.

### local-path (MINC / fallback)

`config/manifests/local-path-provisioner.yaml` deploys Rancher local-path-provisioner for
clusters without LVMS. Provides RWO only — Hub RWX requires NFS or an alternative RWX
provisioner.

## Consequences

### Positive

- Hub file storage works with RWX on single-node MicroShift
- NFS is self-contained — no external NAS dependency
- StorageClass name (`nfs-local-rwx`) is stable across docs and CRs
- Deploy adapts when RWX is unavailable (degraded but functional)

### Negative

- NFS server requires `privileged` SCC — security tradeoff for local dev
- In-cluster NFS is not HA — acceptable for demo, not production
- NFS adds pods and memory overhead in `nfs-storage` namespace
- `__NFS_SERVER_IP__` substitution adds deploy-time complexity

### Neutral

- Production OpenShift uses enterprise storage (ODF, NFS, cloud RWX); aap-demo pattern is dev-only
- PVC binding checked by `aap-demo diagnose`

## Alternatives Considered

### Hub on RWO only

Rejected: breaks multi-pod Hub scenarios and diverges from supported AAP configs.

### HostPath RWX

Rejected: not portable across CRC restarts; SCC and path management fragile.

### External cloud RWX (EFS, Azure Files)

Rejected: adds cloud dependency; unsuitable for offline local dev.

## References

- [config/manifests/nfs-provisioner.yaml](../../config/manifests/nfs-provisioner.yaml)
- [config/manifests/nfs-server.yaml](../../config/manifests/nfs-server.yaml)
- [config/crs/aap-minimal.yaml](../../config/crs/aap-minimal.yaml)
- [ADR-012](012-scc-and-pod-security.md) — privileged SCC for NFS
