# ADR-002: Portal Helm Deployment Architecture (x86 and ARM)

**Status**: Accepted

**Date**: 2026-06-26

**Authors**: Chad Ferman

## Context

The AAP Self-Service Portal is deployed via the OpenShift Helm chart
`openshift-helm-charts/redhat-rhaap-portal`. The chart and Red Hat RHDH hub
images are certified for **x86_64** only, but aap-demo must also support
**ARM64** clusters (CRC/MicroShift on Apple Silicon).

Developers need a single addon command that works on both architectures without
maintaining separate deployment paths or non-Helm alternatives (QEMU appliances,
local VMs).

### Constraints

- Must integrate with existing AAP OAuth and catalog APIs
- Must work on OpenShift Local (CRC/MicroShift) and full OpenShift
- ARM support is experimental (community images, not Red Hat supported)
- Laptop CPU does not determine deployment profile — **cluster node architecture** does

## Decision

Provide one `portal` addon (`aap-demo enable portal`) that auto-detects cluster
CPU and applies one of two Helm profiles against the same chart and namespace.

### Profile selection

```bash
kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}'
```

| Cluster CPU | Profile | RHDH hub image | PostgreSQL |
|-------------|---------|----------------|------------|
| `amd64` | **x86** | Chart default (`registry.redhat.io/rhdh/...`) | Chart default |
| `arm64` | **ARM** | `quay.io/rhdh-community/rhdh:1.10` | `registry.redhat.io/rhel9/postgresql-15` |

Override: `PORTAL_ARCH=arm` or `PORTAL_ARCH=x86`.

### Shared deployment model

Both profiles use:

- **Chart:** `openshift-helm-charts/redhat-rhaap-portal` (plugin version `2.2`)
- **Namespace:** `redhat-rhaap-portal`
- **Release:** `redhat-rhaap-portal`
- **Plugin delivery:** OCI artifacts from `registry.redhat.io`
- **OAuth app:** `ansible-automation-portal` in AAP Gateway
- **Config dir:** `~/.aap-demo/portal`

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  aap-demo enable portal                                         │
│    └─> addons/portal/deploy.sh                                  │
│          ├─ detect cluster arch (arm64 | amd64)                 │
│          ├─ AAP OAuth + API setup (two-phase redirect URI)      │
│          ├─ Helm install/upgrade (profile-specific values)        │
│          └─ Post-install (MicroShift OAuth, ARM plugin patch)   │
└─────────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          ▼                                       ▼
   x86 profile (amd64)                    ARM profile (arm64)
   ───────────────────                    ───────────────────
   global/upstream values                 redhat-developer-hub wrapper
   Red Hat RHDH hub (chart)               quay.io/rhdh-community/rhdh:1.10
   Chart PostgreSQL image                 RHEL9 PostgreSQL 15 override
                                          Disable broken quay scaffolder plugin
                                          Reset dynamic-plugins PVC on install
```

### x86 profile

Uses chart defaults with top-level `global` and `upstream` Helm values. Suitable
for production-like x86 OpenShift clusters. Red Hat supported when deployed on
supported OpenShift versions per chart certification.

### ARM profile

Overrides container images because Red Hat RHDH hub images are amd64-only:

1. **RHDH hub:** `quay.io/rhdh-community/rhdh:1.10` (multi-arch manifest)
2. **PostgreSQL:** `registry.redhat.io/rhel9/postgresql-15:9.8-1782419742`
3. **Values structure:** `redhat-developer-hub:` top-level key (chart subchart layout)
4. **Quay plugin:** Post-Helm ConfigMap patch disables
   `backstage-community-plugin-scaffolder-backend-module-quay-dynamic` (broken in
   community RHDH 1.10)
5. **Plugin PVC:** Reset on install so init container reinstalls OCI plugins cleanly

AAP OCI plugin bundles are JavaScript; they install on ARM even though OCI
metadata reports `amd64`. This is experimental and not Red Hat supported.

### MicroShift / CRC OAuth (both profiles)

On MicroShift, ingress is not available on in-cluster Service port 443. The
deploy script:

1. Sets `AAP_HOST_URL` to `http://<aap-route>` (not `https://`) for pod→AAP
   token exchange
2. Patches the portal Deployment with a `hostAliases` entry mapping the AAP
   route hostname to the AAP Service ClusterIP (nip.io resolves to `127.0.0.1`
   inside pods)
3. Sets `checkSSL: false` in appConfig for rhaap auth/catalog providers

Browsers still reach AAP over HTTPS via ingress; only backend token exchange uses
HTTP with the host alias.

### OAuth two-phase configuration

1. **Pre-Helm:** Create OAuth app with placeholder redirect URI
2. **Post-Helm:** Patch redirect URI to
   `https://<portal-route>/api/auth/rhaap/handler/frame`

Credentials persist in `~/.aap-demo/portal/oauth_credentials.json` because AAP
does not return `client_secret` on subsequent reads.

## Consequences

### Positive

- Single addon and namespace for all supported cluster architectures
- ARM Mac developers use native CRC/MicroShift (no QEMU emulation)
- x86 production path unchanged (chart defaults)
- MicroShift OAuth login works reliably (host alias + HTTP token URL)

### Negative

- ARM profile is experimental (community RHDH, chart certified x86 only)
- ARM install requires extra post-Helm steps (quay disable, PVC reset)
- Image overrides may break on chart upgrades without testing both profiles

### Neutral

- Laptop architecture is informational only; remote x86 clusters work from ARM Macs
- `registry.redhat.io` credentials still required for AAP OCI plugins on ARM

## Alternatives considered

### Separate portal-arm addon

Rejected: duplicated deploy logic; never released; merged into unified portal addon.

### QEMU portal appliance on macOS (portal-vm)

Rejected: slow x86 emulation, macOS-only, separate lifecycle from cluster deployment;
superseded by ARM Helm profile on CRC/MicroShift.

### Wait for official ARM RHDH images

Deferred: community multi-arch images unblock development; switch to Red Hat images
when available.

## Implementation

| Path | Purpose |
|------|---------|
| `addons/portal/deploy.sh` | Deploy, disable, profile detection, OAuth, Helm |
| `addons/portal/values.yaml.template` | Reference values (generated file at install) |
| `addons/portal/README.md` | Operator guide and troubleshooting |

## References

- [ADR-004](004-portal-helm-addon.md) — Initial Helm addon design decisions
- OpenShift Helm chart: `openshift-helm-charts/redhat-rhaap-portal`
- Community RHDH: https://github.com/redhat-developer/rhdh-local
- AAP Extend docs: Portal installation (Helm, OCI plugins)
