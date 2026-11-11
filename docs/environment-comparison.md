# AAP Demo Environment Comparison

A comparison of the infrastructure backends supported by aap-demo.

For current host-specific installation instructions and CLI feature boundaries,
start with [Linux](../Linux_Quickstart.md), [macOS](../MAC_Quickstart.md),
[Windows](../Windows_Quickstart.md), or [WSL](../WSL_Quickstart.md).
The startup behavior below describes the Bash CRC workflow; native PowerShell
and addon availability are not automatically identical.

## Executive Summary

| Backend | Platform | Best For | Startup | System Pods |
|---------|----------|----------|---------|-------------|
| **CRC MicroShift** | macOS, Linux, Windows | Recommended default | ~3 min | ~10 |
| **CRC OpenShift** | macOS, Linux, Windows | Full OpenShift fidelity | ~5-8 min | ~96 |
| **MINC** | Linux | Lightweight, no VM | ~2 min | ~10 |

## CRC MicroShift (Recommended)

Red Hat-maintained VM running MicroShift (single-node OpenShift API subset).

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Disk | 50 GB | 100 GB |
| Memory | 8 GB | 16 GB |
| CPUs | 4 | 8 |

**Key characteristics:**

- VM lifecycle managed by CRC (`crc start`, `crc stop`, `crc delete`)
- OpenShift API compatibility (Routes, SCCs, OLM)
- LVMS storage (topolvm-provisioner) with configurable PV reservation
- nip.io routes — no /etc/hosts or local DNS needed
- Shared Podman/CRI-O storage for local image builds
- Ingress CA auto-trusted on macOS keychain / Linux ca-trust
- ~10 system pods, fast boot

```bash
aap-demo create                    # Creates CRC MicroShift cluster
aap-demo deploy 2.6             # Deploy latest release
aap-demo deploy aap-demo            # Deploy from source
aap-demo enable console            # Add OpenShift Console
```

## CRC OpenShift (Full Platform)

Full OpenShift Container Platform running in a CRC VM. Selected during `aap-demo create` when choosing the OpenShift preset.

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Disk | 60 GB | 100 GB |
| Memory | 14 GB | 20 GB |
| CPUs | 4 | 8 |

**When to use CRC OpenShift instead of MicroShift:**

- Testing features that require specific OpenShift operators (e.g., DevSpaces)
- Validating against the full operator ecosystem and OperatorHub
- Testing Machine Config Operator (MCO) or cluster-level features
- Final validation before deploying to production OpenShift

**Trade-offs vs MicroShift:**

- ~96 system pods vs ~10
- 5-8 min startup vs 3 min
- Higher memory usage
- Built-in console, OAuth, monitoring

## MINC (Container)

MicroShift running directly in a Podman container. Linux only — no VM overhead.

### Prerequisites

**Podman 4.0+ is required** for the MINC backend. Install from:

- [Podman Desktop](https://podman-desktop.io/) (recommended)
- [podman.io](https://podman.io/docs/installation) (CLI-only install)

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Disk | 30 GB | 50 GB |
| Memory | 10 GB | 14 GB |
| CPUs | 2 | 4 |

**Key characteristics:**

- No VM — runs as a Podman container
- Same OpenShift API compatibility as CRC MicroShift
- Fastest startup (~2 min)
- Shared Podman storage with CRI-O (no registry networking issues)
- Linux only (macOS/Windows developers should use CRC)

```bash
AAP_DEMO_INFRA=minc aap-demo create
aap-demo deploy
```

## Performance Comparison

| Phase | CRC MicroShift | CRC OpenShift | MINC |
|-------|----------------|---------------|------|
| Cluster start | ~3 min | ~5-8 min | ~2 min |
| OLM install | ~1 min | Built-in | ~1 min |
| AAP latest deploy | ~8-10 min | ~10-15 min | ~10 min |
| **Total (create + deploy)** | **~15 min** | **~20-30 min** | **~15 min** |

## Feature Comparison

| Feature | CRC MicroShift | CRC OpenShift | MINC |
|---------|----------------|---------------|------|
| OpenShift Routes | Yes | Yes | Yes |
| SCCs | Yes | Yes | Yes |
| OLM | Installed by aap-demo | Built-in | Installed by aap-demo |
| OpenShift Console | Via addon | Built-in | Via addon |
| OperatorHub | No | Yes | No |
| DevSpaces | No | Yes | No |
| LVMS Storage | Yes | Yes | No (local-path) |
| macOS support | Yes | Yes | No |
| Windows support | Yes | Yes | No |

## Use Case Recommendations

| If you need... | Use |
|----------------|-----|
| Default local dev environment | CRC MicroShift |
| Fastest possible startup | MINC (Linux) |
| Full OpenShift operator ecosystem | CRC OpenShift |
| DevSpaces (browser-based IDE) | CRC OpenShift |
| Cross-platform (macOS + Linux) | CRC MicroShift |
| Lowest resource usage | MINC |
| aap-demo from source | CRC MicroShift or MINC |
| latest release testing | CRC MicroShift |

## Switching Between Backends

```bash
# Check current backend
aap-demo status

# Switch to a different backend (requires destroy + create)
aap-demo destroy
echo "INFRA=minc" > ~/.aap-demo/config    # or INFRA=crc
aap-demo create
aap-demo deploy
```

The CRC preset (MicroShift vs OpenShift) is selected during `aap-demo create` and saved to `~/.aap-demo/config` as
`CRC_PRESET=microshift` or `CRC_PRESET=openshift`.

## Resuming an existing CRC demo

`aap-demo start` resumes the configured CRC environment without redeploying it.
It restores DNS routing and catalog connectivity, resumes idle AAP, waits for
installed infrastructure and enabled addon workloads, starts preserved Fleet
VMs, and reapplies addon integrations. It reports success only after readiness
checks pass. Healthy application pods are not forcibly restarted.

On each start, if CRC's `/var` filesystem is at least **90% used**, the existing
VM disk grows by **20%**, rounded up to whole GiB. For example, a 220 GiB disk
becomes 264 GiB. CRC performs disk and guest filesystem expansion through a brief
stop/start, preserving cluster data and the PV reservation. No destructive rebuild
or automatic forced power-off is performed. Host free space and the resulting
filesystem size are verified, and an interrupted resize retries the saved target.
This is a startup check, not continuous monitoring; there is no fixed
100 GiB free-space requirement. PVCs and separate persistent image-store disks
are not automatically expanded by this policy.

Use `AAP_START_TIMEOUT=900 aap-demo start` to allow up to 900 seconds per readiness
phase (default: 600). Resolve reported resource, storage or image-pull failures and
rerun `aap-demo start`; it does not silently resize memory or enable disabled addons.

Linux CRC/libvirt installations can opt into
[shutdown backup and boot restore](state-service.md) using `aap-demo service install`.
That service wraps `start`, `restart` and `stop` with full cold-state backup and
restore. It always brings the demo online after reboot and retains only the
latest completed state unless a different retention count is configured.

macOS/vfkit and native Windows instead use explicit cold checkpoints plus
restore/start at **user login**. They do not guarantee a backup during host
shutdown; checkpoint before reboot. See [native recovery](state-service.md#macos-and-windows-login-recovery).
