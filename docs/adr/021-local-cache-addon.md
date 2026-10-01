# ADR-021: Local Cache Addon

**Status**: Accepted

**Date**: 2026-07-30

**Last updated**: 2026-10-01

**Authors**: Chad Ferman

## Context

Deploying AAP on OpenShift Local requires pulling ~50 container images from `registry.redhat.io`
and `registry.k8s.io`. On a typical connection this takes 10–15 minutes per deploy. After a
`crc delete && crc start` cycle (common during development), all images must be pulled again
because CRI-O's image store lives inside the CRC VM and is destroyed with it.

For developers iterating on aap-demo itself, this pull time dominates the create-deploy-test
loop. The images rarely change between iterations — the same AAP 2.7 operator, gateway,
hub, EDA, and platform images are pulled repeatedly.

## Decision

Add a `local-cache` addon that saves container images from a running CRC VM to the local
filesystem and reloads them into a fresh VM, bypassing registry pulls entirely.

### Addon interface

The addon follows the contract from ADR-008 and supports subcommands via positional args:

```
aap-demo enable local-cache          # save images from running cluster
aap-demo enable local-cache load     # load cached images into cluster
aap-demo enable local-cache clear    # delete cache
aap-demo disable local-cache         # alias for clear
```

### Save flow

1. SSH into the CRC VM and run `crictl images -o json` to enumerate all images in CRI-O
2. Filter to images from `registry.redhat.io` and `registry.k8s.io` (skip pause, base, and
   builder images that ship with the VM)
3. For each image, export the current CRC platform via
   `skopeo copy --remove-signatures containers-storage:'<ref>'
   oci-archive:/tmp/aap-demo-local-cache.oci:<tag>` on the VM, then stream the OCI
   archive to a local file. The export is single-platform because CRI-O can retain a
   multi-architecture index whose other manifests are not present locally; OCI archives
   also cannot store the Red Hat signature store, so signatures are intentionally removed.
4. Each image is stored as three files: `<md5>.tar` (the OCI archive), `<md5>.ref`
   (the original image reference), and `<md5>.local-ref` (the digest address of the
   imported archive in the CRC image store)
5. When the image is the Red Hat operator index, save also records the OCP version,
   original catalog digest, and local platform digest in `catalog-digests`
6. Images already cached (all three archive and sidecar files exist) are skipped

### Load flow

1. For each `.tar` file in the cache directory, read the corresponding `.ref` file
2. Stream the OCI archive to a temporary file on the CRC VM, then run `skopeo copy
   --all --preserve-digests oci-archive:<temporary-file>:<tag>
   containers-storage:'<ref>'`; remove the temporary file afterward
3. Import under the `.local-ref` platform digest and report per-image success/failure
4. Rewrite matching CatalogSource and workload-template image references to `.local-ref`

### Self-healing cache behavior

The cache is an optimization, not a prerequisite for deployment. A cache entry can be
valid on disk but unavailable in a newly created CRC VM, for example when an import
failed, an archive was incomplete, or the recorded local digest came from an older VM.
The loader therefore verifies every successful import with `crictl inspecti`. Entries
that fail import or do not expose the expected digest are removed together with their
sidecars. In quiet/automatic deploy mode, those failures are reported but do not abort
the deployment; Kubernetes can pull the original registry reference instead.

The rewrite phase independently verifies that the cached digest is present before it
changes any workload. Unavailable entries are skipped, leaving the original registry
reference untouched. Rewrites are idempotent and handle both the original and already
rewritten image reference. They also change `imagePullPolicy: Always` to
`IfNotPresent`; otherwise Kubernetes contacts the registry even when the image is
already in CRI-O, defeating the purpose of the cache.

Patching only generated Deployments is insufficient because OLM and AAP component
operators recreate them from their source templates. The rewrite therefore updates the
CSV install strategy as well as live workload templates. The CSV is the source of truth
for the AAP operator deployment; keeping its image and pull policy aligned prevents an
operator reconciliation loop from restoring `Always` and the original registry image.

The cache stores a single-platform OCI archive and its imported archive digest. This is
the platform that the current CRC VM can execute. An experiment that attempted to
re-import multi-architecture archives directly under the original platform digest failed
because the local CRI-O store did not contain every manifest in the list. Exporting the
current platform and removing unsupported signatures avoids that failure. The supported
behavior is consequently: preserve the archive digest during import, verify its actual
availability, and fall back to the original registry reference when it is not usable.

### Auto-load during deploy

The `_load_local_cache()` function in `aap-demo.sh` is called near the start of
`aap-demo deploy`, after Kubernetes API connectivity and MicroShift OVN readiness have
been verified but before the operator and AAP resources begin pulling images. The
readiness gate is intentional: loading into the CRI-O runtime before the cluster and
CNI are ready can race cluster startup and make a clean deploy appear to have a
working cache when the runtime is not yet usable. It always checks for an existing
cache, so a destroy/recreate cycle does not require the `local-cache` addon to remain in
`~/.aap-demo/config` (`ADDONS=...`). It loads cached images that are not already present
in CRI-O (checked via `crictl inspecti`) and remains silent when no cache exists. Before
creating the CatalogSource, deployment uses the cached catalog's local platform digest
for the matching OCP version. This pins OLM to the catalog that produced the cached
operator bundle instead of following a mutable `vX.Y` tag. Caches created before this
metadata was added remain compatible but use the tagged catalog until refreshed.

### Save prompt during destroy

Before `aap-demo destroy` displays its destructive warning, an interactive invocation
asks whether to save the current AAP images to the local cache. The prompt is opt-in:
answering `y` runs the save flow, while `n`, a timeout, or a non-interactive
`QUIET=true` invocation skips it. A save failure is reported but does not prevent the
cluster from being deleted.

### Preset isolation

aap-demo creates MicroShift clusters only (`CRC_PRESET=microshift`). The cache is stored at:

```
~/.aap-demo/local-cache/microshift/
```

The directory layout retains a preset segment (`microshift/`) for compatibility if
additional presets are reintroduced later.

### Opt-in persistent CRI-O image storage

The archive cache remains the portable fallback. For repeated CRC recreate cycles, an opt-in
mode keeps CRI-O's native image store on a persistent host-managed virtual disk:

```bash
AAP_PERSISTENT_IMAGE_STORE=true
# Linux/libvirt only. macOS/vfkit uses the OCI image cache instead.
# Omit AAP_IMAGE_STORE_DISK to use the Linux platform default:
# ~/.aap-demo/storage/crio-images.qcow2
AAP_IMAGE_STORE_SIZE_GB=60
# Required only for first-time initialization of a blank disk:
AAP_IMAGE_STORE_FORMAT=true
```

Lifecycle:

1. Create the Linux qcow2 disk once. A blank disk is formatted only when
   `AAP_IMAGE_STORE_FORMAT=true` is explicitly set. macOS/vfkit does not use
   this persistent-store path; use the OCI image cache there.
2. Attach the disk to the CRC system-libvirt VM.
3. Mount it at `/var/lib/containers/storage`, persist the filesystem UUID in the guest's
   `fstab`, install a CRI-O mount dependency, apply SELinux labels, and restart CRI-O and
   MicroShift before deployment.
4. Verify that `crictl images` sees the persistent store; image loading should then be near
   zero because the native image metadata and layers already exist.
5. Before `crc delete`, stop CRI-O, unmount and detach the Linux disk, and
   retain the host disk.

The implementation must never mount the host's overlay/container-storage directory directly
through NFS or virtiofs. It must refuse to format an existing disk without explicit approval,
verify the attached source and filesystem identity, and fall back to the OCI archive cache when
attach or mount setup fails. Acceptance testing should cover three destroy/recreate cycles,
image visibility before deployment, no image-layer pulls, and a fallback path with the
persistent disk disabled.

### Technical details

- **SSH `-n` flag**: The save loop reads image refs from a heredoc via `while read`. Without
  `-n`, SSH consumes stdin from the heredoc, causing the loop to exit after 1-2 images.
- **OCI archives**: The save/load path uses single-platform OCI archives instead of
  Docker archives. Saving removes signatures because OCI archives do not support the
  source signature store, and avoids `--all` because CRI-O may have only the current
  platform manifest for a multi-architecture image list. Loading uses
  `--preserve-digests` and fails when the archive cannot represent the recorded digest;
  importing under a synthetic tag would not satisfy Kubernetes' digest pull request.
- **`containers-storage:` transport**: CRI-O images are accessed via skopeo's
  `containers-storage:` transport, not `crictl export` (which doesn't exist) or `ctr`
  (not available on CRC VMs).
- **md5 filenames**: Image references contain `/`, `@`, and `:` characters that are
  problematic in filenames. The md5sum of the reference is used as the filename, with the
  original reference stored in the `.ref` sidecar file.
- **Preset detection**: Shared helper `_detect_crc_preset()` in `includes/infra-crc.sh`
  resolves preset in order: `CRC_PRESET` env var → `CRC_PRESET` in `~/.aap-demo/config` →
  `crc config get preset` → default `microshift`. Avoids mis-parsing CRC's "not set"
  message (which mentions openshift as CRC's default, not aap-demo's).

### Failure analysis and automation outcome

The cache appeared not to work after a destroy/recreate cycle for two independent
reasons:

1. A stale local digest mapping was reused after the corresponding image was no longer
   available in the new CRC VM. The deploy path attempted to use that mapping without
   validating the imported image.
2. Images that were already present in CRI-O still had `imagePullPolicy: Always`, so the
   kubelet contacted `registry.redhat.io` and failed with `manifest unknown` instead of
   using the local image.

The fresh-cache test then exposed a third export defect: `skopeo copy --all` attempted to
copy Red Hat signatures into an OCI archive and failed with `Pushing signatures for OCI
images is not supported`. After removing signatures, multi-architecture exports still
failed when a local CRI-O image list referenced a manifest that was not present in the
VM. The exporter now saves only the current platform image without signatures.

The automated fix keeps good cache entries, evicts only entries that fail validation,
skips unusable rewrites, and repairs the operator CSV/workload pull policy. This makes
the cache a partial accelerator with safe registry fallback rather than an all-or-nothing
deployment dependency.

The implementation is covered by regression tests for failed import eviction, digest
availability checks, quiet fallback, stale-reference skipping, idempotent rewrites,
`IfNotPresent` policy repair, and CSV source-of-truth repair.

Validation on 2026-10-01 included a destructive CRC destroy/recreate cycle, a clean AAP
deployment attempt, shell syntax and ShellCheck validation, the local-cache regression
suite, and the repository CLI tests. The CRC version integration test passed with host
filesystem access; an unprivileged sandbox run could not remove existing user cache files
and was not considered a product failure. The ingress CA suite retained one pre-existing
environment-sensitive failure (`combined_bundle_verifies_github`) unrelated to local
cache behavior. A follow-up fresh-cache validation that also requested Automation
Orchestrator and portal images was blocked before AAP deployment by CRC's LVMS operator:
its certificate secrets were not created, leaving the NFS backing PVC `Pending` and
causing cluster setup to time out. The failed disposable cluster was removed. This is an
infrastructure readiness failure, not evidence that the cache load path succeeded.

## Consequences

### Positive

- Subsequent deploys after `aap-demo destroy` skip ~10-15 minutes of image pulls when
  the on-disk cache is reloaded
- Cache persists across VM lifecycles — only needs to be rebuilt when AAP version changes
- Auto-load during deploy is transparent — after accepting the destroy save prompt,
  the normal `create` then `deploy` flow needs no manual cache-load command

### Negative

- Cache is ~30 GB on disk for a full AAP deployment (~50 images)
- Save operation takes 10–15 minutes (same as pulling — images must be exported from CRI-O)
- Images are stored as OCI archives; no deduplication of shared layers
  across images

### Neutral

- The addon is listed in `AVAILABLE_ADDONS` and visible in `aap-demo enable` output
- `aap-demo destroy` clears `ADDONS=` from config but does not delete on-disk cache files.
  If the save prompt was accepted, the next `deploy` loads the cache automatically.
  `aap-demo enable local-cache load` remains available for manual loading, while
  `aap-demo enable local-cache clear` or `aap-demo disable local-cache` reclaims disk
  space.

## Alternatives Considered

### Registry mirror / pull-through cache

A local registry (e.g. `registry:2` with pull-through) would cache images transparently.
Rejected because: (a) requires running a persistent local registry process outside the VM,
(b) CRC's CRI-O config must be modified to add the mirror, which doesn't survive
`crc delete`, (c) adds complexity for a dev-only optimization.

### `podman save` / `podman load` on the host

Export images via podman on the host rather than skopeo over SSH. Rejected because the
images exist inside the CRC VM's CRI-O store, not in a host-accessible podman store.
Getting them out requires SSH regardless.

### `crictl checkpoint` / `crictl restore`

CRI checkpoint/restore operates on running containers, not images. Not applicable.

### Compress cached tarballs

Gzip or zstd compression would reduce the ~30 GB cache to ~15 GB. Rejected for now because
compression/decompression adds time to both save and load, and disk space is typically not
the bottleneck on development machines. Can be added later if needed.

## References

- [ADR-008](008-addon-system.md) — Addon system architecture
- [ADR-020](020-full-openshift-support.md) — Full OpenShift support evaluation (declined; MicroShift-only)
- [addons/local-cache/deploy.sh](../../addons/local-cache/deploy.sh)
- [includes/persistent-crio-store.sh](../../includes/persistent-crio-store.sh) — opt-in CRI-O disk lifecycle
- [aap-demo.sh](../../aap-demo.sh) — `_load_local_cache()` auto-load function
