# ADR-020: Full OpenShift Support and Resource-Aware Provisioning

**Status**: Accepted

**Date**: 2026-07-30

**Authors**: aap-demo maintainers

## Context

aap-demo originally targeted MicroShift exclusively. The CRC preset defaulted silently to
`microshift` with no user choice, no host resource detection, and no resource allocation
prompt. This created several problems:

- Users wanting full OpenShift (console, monitoring, OAuth, marketplace) had to manually
  set `CRC_PRESET=openshift` via environment variable — undiscoverable.
- The script applied a fixed 8 CPU / 16 GB RAM allocation without checking the host. On
  machines with limited resources, CRC would fail or thrash. On capable machines, the
  allocation left headroom unused.
- Full OpenShift ships resource-heavy platform components (Prometheus, console, image
  registry, Insights) that compete with AAP for CPU and memory. No mechanism existed to
  reclaim those resources short of manual `kubectl scale` commands.
- The PV default of 50 GB was insufficient for full OpenShift workloads with AAP.
- On full OpenShift CRC, the CSI hostpath provisioner creates root-owned volumes that
  cause permission failures for pods running as non-root UIDs (postgres, hub, redis).
- The CatalogSource image tag was hardcoded to `v4.20`, breaking deploys on newer CRC
  versions (e.g. 4.22).
- MicroShift 4.22+ enforces container image GPG signatures, causing CatalogSource pods
  to fail with `SignatureValidationFailed`.
- CoreDNS rewrite rules were not auto-configured during deploy, only warned.
- No mechanism to check for aap-demo updates.
- The hub `route_host` was hardcoded to a nip.io domain in the CR template, breaking
  full OpenShift where routes use the cluster's ingress domain (`apps-crc.testing`).

## Decision

### 1. Interactive preset prompt with OpenShift default

Replace the silent `microshift` default in `includes/crc-create.sh` with an interactive
prompt on every fresh creation (`CRC_STATUS=Unknown`):

```
Select cluster type:
  1) OpenShift  (full — includes console, monitoring, OAuth)
  2) MicroShift (lightweight — lower resources, faster startup)
  Choice [1]:
```

OpenShift is now the default. The saved value from `~/.aap-demo/config` becomes the
bracketed default on the prompt, but the user is always asked on fresh create.
Non-interactive environments (CI, piped stdin) fall through to the OpenShift default
silently.

### 2. Host resource detection and warnings

A new `_detect_host_resources` function queries the host OS:

| Platform | CPU | Memory |
|----------|-----|--------|
| macOS | `sysctl -n hw.ncpu` | `sysctl -n hw.memsize` |
| Linux | `nproc` / `/proc/cpuinfo` | `/proc/meminfo` |

After detection, the script displays available resources and applies warning thresholds:

| Preset | Condition | Severity |
|--------|-----------|----------|
| OpenShift | < 6 CPUs or < 14 GB | Red warning, suggest MicroShift |
| OpenShift | <= 8 CPUs and <= 16 GB | Yellow note, mention scale-down addon |
| MicroShift | < 4 CPUs or < 10 GB | Red warning |

Warnings are advisory only — they do not block creation.

### 3. Interactive resource allocation

On fresh creation with a TTY, the script prompts for CPU and memory in GB with
preset-aware defaults:

```
Resource allocation for CRC VM:
  Host: 10 CPUs, 32GB RAM

  CPUs [8]:
  Memory in GB [20]:
```

| Preset | Default CPUs | Default Memory |
|--------|-------------|----------------|
| OpenShift | 8 | 20 GB |
| MicroShift | 8 | 16 GB |

Users enter simple whole numbers (e.g. `20` for 20 GB). The GB-to-MB conversion
(`* 1024`) is handled automatically before saving to config and passing to
`crc config set memory`.

Chosen values are saved to `~/.aap-demo/config` via the new `_save_config_key` helper.
Subsequent creates reuse saved values without re-prompting. Env vars (`CRC_CPUS`,
`CRC_MEMORY`, `VM_CPUS`, `VM_MEMORY`) override saved values and suppress the prompt.
Note: env vars still use MB for backward compatibility with existing scripts.

The PV size default is increased from 50 GB to 70 GB.

### 4. Scale-down addon

A new `addons/scale-down/deploy.sh` addon scales non-AAP workloads to zero replicas,
freeing CPU and RAM for AAP. It follows the addon contract from ADR-008.

**Interactive checklist**: On deploy, the addon discovers namespaces with running workloads
and presents a numbered checklist:

```
Select namespaces to scale down:
  (AAP namespace 'aap-operator' is always excluded)

  1) [x] openshift-monitoring  (5 running)
  2) [x] openshift-console  (2 running)
  3) [x] openshift-insights  (1 running)
  4) [x] openshift-image-registry  (1 running)
  5) [x] automation-orchestrator  [ao-eap addon] (3 running)

  Enter numbers to toggle, a for all, n for none, or press Enter to confirm:
```

**Platform namespaces** (discovered on full OpenShift):
- `openshift-monitoring`
- `openshift-console`
- `openshift-insights`
- `openshift-image-registry`
- `openshift-marketplace`
- `openshift-multus`
- `openshift-network-diagnostics`
- `openshift-network-console`
- `openshift-cluster-samples-operator`
- `openshift-machine-api`
- `openshift-cluster-machine-approver`
- `openshift-kube-storage-version-migrator`

Note: most platform namespaces already run single-replica Deployments and DaemonSets
(1 pod per node on single-node CRC). The scale-down addon scales these to zero — there
is no intermediate "reduce to 1" option since they are already at 1.

**Addon namespaces** (included when their addon is enabled):
- `automation-orchestrator` (ao-eap)
- `apme` (apme-eap)
- `redhat-rhaap-portal` (portal)

**Safety**: The AAP namespace (`aap-operator`) is excluded via hard guard clause.

**State management**: Original replica counts are recorded in `~/.aap-demo/scale-down-state`
(pipe-delimited: `ns|kind|name|replicas`). Restore via `aap-demo disable scale-down`
reads the state file and scales each resource back to its original count.

The addon exits cleanly on MicroShift (those namespaces don't exist).

### 5. NFS storage on both presets

On full OpenShift CRC, the CSI hostpath provisioner (`kubevirt.io.hostpath-provisioner`)
creates volumes at `/var/lib/csi-hostpath-data/` owned by `root:root`. AAP pods run as
non-root UIDs under the `anyuid` SCC, which doesn't support `fsGroup`. This causes
`mkdir: cannot create directory: Permission denied` and CrashLoopBackOff for postgres
(UID 26), hub (UID 1000), and hub-redis (UID 1001).

Rather than patching volume permissions over SSH after every PVC bind (fragile — the
operator can recreate PVCs at any time), we deploy the same in-cluster NFS server on
full OpenShift that MicroShift already uses. NFS doesn't enforce UID ownership on
exported directories, so all AAP pods can write to their volumes regardless of UID.

The NFS deployment in `includes/crc-create.sh` now runs on **both presets**:
- MicroShift: NFS backing PVC uses `topolvm-provisioner` (default SC)
- Full OpenShift: NFS backing PVC uses `crc-csi-hostpath-provisioner` (default SC)

The NFS server itself runs privileged (SCC granted to `nfs-storage` namespace), and
the `nfs-local-rwx` StorageClass provides RWX volumes for hub file storage. Since only
the NFS server pod touches the CSI hostpath volume directly (as root), the UID ownership
problem is eliminated for all AAP workloads.

The `aap-minimal.yaml` CR template uses `nfs-local-rwx` for hub file storage on both
presets, so no conditional CR patching is needed. The only preset-specific CR adjustment
is injecting `route_host` on MicroShift for the nip.io domain.

### 6. Auto-detect OCP version for CatalogSource

Instead of hardcoding `AAP_OCP_VERSION=4.20`, the deploy command now auto-detects the
running OCP version from `crc status -o json` and uses it for the
`redhat-operator-index:v<version>` image tag. Falls back to `4.20` if detection fails.

### 7. Container signature policy relaxation

MicroShift 4.22+ enforces GPG signature verification for `registry.redhat.io` images.
The `redhat-operator-index` image fails this check. Before creating the CatalogSource,
the deploy command SSHs into the CRC VM and modifies `/etc/containers/policy.json` to
set `insecureAcceptAnything` for `registry.redhat.io`. This is acceptable in a
development/testing environment.

### 8. CoreDNS auto-fix during deploy

`verify_coredns()` previously only warned when the nip.io rewrite rule was missing. It
now auto-applies the fix using the existing `configure_coredns` function via the
`AAP_DEMO_CONFIGURE_COREDNS_ONLY=1` source guard.

### 9. Auto-update check

A `_check_for_updates()` function runs on every `aap-demo` invocation (except `help`,
`update`, and empty commands). It:

1. Resolves the real path of the `aap-demo` alias to find the git repository
2. Runs `git fetch --quiet` to check for upstream changes
3. If HEAD is behind upstream, prompts "Pull latest now? [Y/n]" with 10s auto-continue
4. Pulls if confirmed

Skipped when stdin is not a TTY (non-interactive/CI).

### 10. SSH hardening

Added `-o IdentitiesOnly=yes` to all SSH connections (3 locations: `infra-crc.sh`,
`crc-create.sh` configure_coredns, `crc-create.sh` SSH re-detection). This prevents
SSH agent key exhaustion when the agent has many keys loaded, which caused
"Too many authentication failures" before the CRC-specific key was tried.

### 11. Config persistence helper

A reusable `_save_config_key` function replaces the inline config-save pattern. It uses
`sed -i.bak && rm .bak` for macOS/Linux compatibility instead of the previous
`/usr/local/bin/sed -i` call that assumed Homebrew GNU sed.

### 12. Single-replica defaults for dev

The AAP operator defaults to 2 replicas for HA on several components (EDA workers, hub
content/workers). In a dev environment HA is unnecessary and wastes ~1.9 GB of memory.

The `aap-minimal.yaml` CR template now sets single replicas via nested sub-CR fields:

```yaml
eda:
  activation_worker:
    replicas: 1
  default_worker:
    replicas: 1
hub:
  content:
    replicas: 1
  worker:
    replicas: 1
```

**How it works**: The top-level AAP CRD uses `x-kubernetes-preserve-unknown-fields: true`,
so it accepts any nested structure. The gateway operator creates sub-CRs (EDA, AutomationHub)
and passes these fields through. The sub-operator CRDs (`edas.eda.ansible.com`,
`automationhubs.automationhub.ansible.com`) have explicit `replicas` fields under
`activation_worker`, `default_worker`, `content`, `worker`, and `web`.

**Note**: Top-level flat fields like `web_replicas` do not exist in any CRD — only the
nested object form works (e.g. `hub.content.replicas`).

| Component | Default | Dev setting | Memory saved |
|-----------|---------|-------------|-------------|
| EDA activation worker | 2 | 1 | ~300 Mi |
| EDA default worker | 2 | 1 | ~260 Mi |
| Hub content | 2 | 1 | ~1024 Mi |
| Hub worker | 2 | 1 | ~1024 Mi |
| **Total** | | | **~2.6 GB** |

### 13. Preset-aware hub route_host

The `route_host` field was removed from the `aap-minimal.yaml` CR template. On full
OpenShift, the operator auto-generates routes using the cluster's ingress domain
(`apps-crc.testing`), so no explicit `route_host` is needed.

On MicroShift, `route_host` is injected at deploy time via `sed` when the
`nfs-local-rwx` StorageClass is detected, setting it to
`aap-hub-<namespace>.apps.127.0.0.1.nip.io`.

### 14. Collection sources removed from status

The `aap-demo status` command no longer checks for ansible.cfg, galaxy tokens, PAH
config, or installed Ansible collections. These checks were noisy and not relevant to
cluster health.

### 15. Addon deployment removed from create

The `aap-demo create` command no longer automatically deploys addons. Addons are deployed
separately via `aap-demo enable <addon>`.

## Consequences

### Positive

- Full OpenShift is now a first-class, discoverable option
- Users are warned before allocating more resources than their host can support
- Resource allocation is interactive and saved — no more guessing env var names
- The scale-down addon can free ~2-3 GB RAM on constrained machines
- All changes are non-interactive-safe: env vars and config file override every prompt
- PV size increase (70 GB) prevents storage pressure on full OpenShift
- NFS storage on both presets eliminates CrashLoopBackOff for postgres, hub, and redis
  on full OpenShift CRC — no UID ownership issues since NFS doesn't enforce them
- CatalogSource version auto-detection eliminates breakage when CRC updates to a new
  OCP version
- CoreDNS auto-fix eliminates a manual step that users often missed
- Auto-update check keeps the tool current without requiring users to remember
- Single-replica defaults save ~2.6 GB memory — enough to fit AAP + OpenShift platform
  in 20 GB without scaling down platform components

### Negative

- Default changed from MicroShift to OpenShift — existing users who relied on the silent
  default will be prompted on next fresh create (saved configs are preserved)
- Scale-down is a one-time action, not persistent enforcement — OpenShift operators may
  reconcile some components back. Users may need to re-run after cluster restart
- The interactive prompts add ~10 seconds to the first-run experience
- Full OpenShift AAP deploys require ~20 GB RAM minimum (~9 GB for AAP with single
  replicas, ~8 GB for OpenShift platform). The scale-down addon is recommended on
  machines with 20 GB or less allocated to CRC

### Neutral

- Existing `~/.aap-demo/config` files with `CRC_PRESET=microshift` are honored without
  change — no migration needed
- The `idle` command continues to control AAP via `spec.idle_aap` independently of
  scale-down
- MicroShift-specific post-setup (nip.io, NFS, metrics-server) is unchanged
- Replica counts are set via nested sub-CR fields in the AAP CR (e.g.
  `eda.activation_worker.replicas`), not top-level flat fields. The CR template
  defaults to single replicas; users needing HA can override to 2+

## Alternatives Considered

### Auto-select preset based on host resources

Rejected: the choice between OpenShift and MicroShift is a functional decision (do you
need the console? OAuth? marketplace?) not purely a resource decision. Warnings inform;
the user decides.

### Persistent scale-down via operator patches

Rejected: patching cluster operators (e.g., disabling cluster-monitoring-operator) is
invasive and hard to reverse cleanly. Scaling deployments to zero is simple, reversible,
and sufficient for development use.

### Prompt for all resource values (disk, PV size)

Rejected: disk and PV size are rarely changed and add decision fatigue. Advanced users
can still set them via env vars. Only CPU and memory — the values users actually need to
tune — are prompted.

### SSH chown for CSI hostpath volumes

Rejected: an earlier iteration used `_fix_csi_hostpath_permissions` to SSH into the CRC
VM and `chown -R` each CSI hostpath volume to the correct UID (26 for postgres, 1000 for
hub, 1001 for redis). This was fragile — the AAP operator can recreate PVCs at any time
during reconciliation, each time creating a new root-owned PV that required re-fixing.
Deploying NFS on both presets eliminates the root cause.

### fsGroup via custom SCC or privileged SCC

Rejected: the AAP operator doesn't set `fsGroup` in the pod spec and reconciles away
manual StatefulSet patches. Even if the `privileged` SCC were forced (by removing the
`anyuid` binding), `fsGroup` would still need to be in the pod spec to take effect.

### Set AAP operator replica counts via top-level CR fields

Rejected: flat fields like `web_replicas`, `worker_replicas`, `content_replicas` are not
in the AAP CRD schema and are silently ignored. Replica counts must use the nested
sub-CR object form (e.g. `hub.content.replicas: 1`), which passes through to the
sub-operator CRDs via `x-kubernetes-preserve-unknown-fields`. Manual `kubectl scale`
works but is reverted on operator reconciliation.

## References

- [ADR-008](008-addon-system.md) — Addon system architecture
- [ADR-003](003-infrastructure-backend-selection.md) — Infrastructure backend selection
- [includes/crc-create.sh](../../includes/crc-create.sh)
- [addons/scale-down/deploy.sh](../../addons/scale-down/deploy.sh)
- [config/crs/aap-minimal.yaml](../../config/crs/aap-minimal.yaml) — Default AAP CR template
  (single-replica settings)
- [aap-demo.sh](../../aap-demo.sh) — `_check_for_updates`, `verify_coredns` auto-fix
