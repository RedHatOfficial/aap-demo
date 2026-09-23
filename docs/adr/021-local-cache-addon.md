# ADR-021: Local Cache Addon

**Status**: Accepted

**Date**: 2026-07-30

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
3. For each image, export via `skopeo copy --all containers-storage:'<ref>'
   oci-archive:/tmp/aap-demo-local-cache.oci:<tag>` on the VM, then stream the OCI
   archive to a local file
4. Each image is stored as three files: `<md5>.tar` (the OCI archive), `<md5>.ref`
   (the original image reference), and `<md5>.local-ref` (the archive's actual
   platform digest)
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

### Auto-load during deploy

The `_load_local_cache()` function in `aap-demo.sh` is called near the start of
`aap-demo deploy`, before the operator and AAP resources begin pulling images. It always
checks for an existing cache, so a destroy/recreate cycle does not require the
`local-cache` addon to remain in `~/.aap-demo/config` (`ADDONS=...`). It loads cached
images that are not already present in CRI-O (checked via `crictl inspecti`) and remains
silent when no cache exists. Before creating the CatalogSource, deployment uses the
cached catalog's local platform digest for the matching OCP version. This pins OLM to
the catalog that produced the cached operator bundle instead of following a mutable
`vX.Y` tag. Caches created before this metadata was added remain compatible but use the
tagged catalog until refreshed.

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
# Omit AAP_IMAGE_STORE_DISK to use the platform default:
# Linux: ~/.aap-demo/storage/crio-images.qcow2
# macOS: ~/.aap-demo/storage/crio-images.raw
AAP_IMAGE_STORE_SIZE_GB=60
# Required only for first-time initialization of a blank disk:
AAP_IMAGE_STORE_FORMAT=true
```

Lifecycle:

1. Create the host disk once. Linux uses qcow2; macOS uses a sparse raw image
   because Apple Virtualization/vfkit does not support qcow2. A blank disk is
   formatted only when `AAP_IMAGE_STORE_FORMAT=true` is explicitly set.
2. On Linux, attach the disk to the CRC system-libvirt VM. On macOS, configure
   CRC's machine config to launch vfkit through a wrapper that adds
   `--device virtio-blk,path=...`; the VM is relaunched once so the disk is
   present before CRI-O starts.
3. Mount it at `/var/lib/containers/storage`, persist the filesystem UUID in the guest's
   `fstab`, install a CRI-O mount dependency, apply SELinux labels, and restart CRI-O and
   MicroShift before deployment.
4. Verify that `crictl images` sees the persistent store; image loading should then be near
   zero because the native image metadata and layers already exist.
5. Before `crc delete`, stop CRI-O, unmount the disk, and retain the host disk.
   Linux detaches it through libvirt; macOS retains the raw image and restores
   the original vfkit path if the machine remains available.

The implementation must never mount the host's overlay/container-storage directory directly
through NFS or virtiofs. It must refuse to format an existing disk without explicit approval,
verify the attached source and filesystem identity, and fall back to the OCI archive cache when
attach or mount setup fails. Acceptance testing should cover three destroy/recreate cycles,
image visibility before deployment, no image-layer pulls, and a fallback path with the
persistent disk disabled.

### Technical details

- **SSH `-n` flag**: The save loop reads image refs from a heredoc via `while read`. Without
  `-n`, SSH consumes stdin from the heredoc, causing the loop to exit after 1-2 images.
- **OCI archives**: The save/load path uses OCI archives instead of Docker archives so
  signatures and manifest metadata are retained. Loading uses `--preserve-digests` and
  fails when the archive cannot represent the recorded digest; importing under a
  synthetic tag would not satisfy Kubernetes' digest pull request.
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
