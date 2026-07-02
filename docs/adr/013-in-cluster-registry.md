# ADR-013: In-Cluster Container Registry

**Status**: Accepted

**Date**: 2026-07-02

**Authors**: aap-demo maintainers

## Context

Developers building custom execution environments or testing image workflows need to push images
and reference them from AAP without external registries. CRC/MicroShift shares **Podman/CRI-O
storage** with the VM — but in-cluster pods pull via kubelet/CRI-O, not the host Podman socket.

Requirements:

- Push from laptop Podman to a registry pods can pull from
- HTTPS route for developer ergonomics
- Insecure/mirror config for local TLS limitations

## Decision

Provide **`registry` addon** deploying a simple in-cluster registry at `addons/registry/`.

### Architecture

```text
aap-demo enable registry
      │
      ▼
Namespace: aap-demo-registry
  ├── Deployment: registry (port 5000)
  ├── Service: ClusterIP
  └── Route: registry.apps.127.0.0.1.nip.io
      │
      ▼
CRI-O mirror on CRC VM (via SSH):
  registry.apps.127.0.0.1.nip.io → <ClusterIP>:5000 (insecure)
```

### CRI-O mirror configuration

After deploy, `deploy.sh` SSHs to CRC VM and writes `/etc/containers/registries.conf.d/999-aap-demo-registry.conf`:

```toml
[[registry]]
location = "registry.apps.127.0.0.1.nip.io"
insecure = true
[[registry.mirror]]
location = "<service-cluster-ip>:5000"
insecure = true
```

Then `systemctl reload crio`.

### Usage pattern

```bash
podman tag <image> registry.apps.127.0.0.1.nip.io/<repo>:<tag>
podman push --tls-verify=false registry.apps.127.0.0.1.nip.io/<repo>:<tag>
```

Reference in deployments:

```yaml
image: registry.apps.127.0.0.1.nip.io/<repo>:<tag>
imagePullPolicy: Always
```

### Shared storage benefit

On CRC, images loaded into the VM's CRI-O store are visible to pods when tagged through this
registry — supports rapid iteration without external pushes.

## Consequences

### Positive

- Local image push/pull loop without quay.io or Docker Hub
- Route hostname follows standard nip.io pattern
- CRI-O mirror avoids in-cluster TLS verification issues
- Documented in README architecture section

### Negative

- Insecure registry — dev only
- SSH-dependent CRI-O config (CRC-specific; no-op without CRC SSH key)
- No garbage collection or RBAC beyond namespace
- Registry data lost on namespace delete

### Neutral

- Not enabled by default
- Production uses enterprise registries (quay, ECR, etc.)

## Alternatives Considered

### Host Podman socket mount into cluster

Rejected: MicroShift/CRI-O isolation prevents direct socket sharing.

### External Docker Registry container on laptop

Rejected: kubelet cannot reach host localhost:5000 without extra networking.

### OpenShift internal registry (image-registry-operator)

Rejected: not available on MicroShift; heavy for demo use case.

## References

- [addons/registry/deploy.sh](../../addons/registry/deploy.sh)
- [addons/registry/registry.yaml](../../addons/registry/registry.yaml)
- [ADR-008](008-addon-system.md)
- [README.md](../../README.md) — shared Podman/CRI-O storage
