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
3. For each image, export via `skopeo copy --remove-signatures containers-storage:'<ref>'
   docker-archive:/dev/stdout`, streaming the tarball to a local file
4. Each image is stored as two files: `<md5>.tar` (the image archive) and `<md5>.ref`
   (the original image reference for reload)
5. Images already cached (both `.tar` and `.ref` exist) are skipped

### Load flow

1. For each `.tar` file in the cache directory, read the corresponding `.ref` file
2. Stream the tarball into the CRC VM via `skopeo copy docker-archive:/dev/stdin
   containers-storage:'<ref>'` over SSH
3. Report per-image success/failure

### Auto-load during deploy

The `_load_local_cache()` function in `aap-demo.sh` is called during `aap-demo deploy`
after the operator CSV reaches `Succeeded` phase and before the AAP CR is created.
It runs only when the `local-cache` addon is listed in `~/.aap-demo/config` (`ADDONS=...`)
or when `AAP_DEMO_LOAD_CACHE=1` is set. When triggered, it loads cached images that are
not already present in CRI-O (checked via `crictl inspecti`). This is silent when no
cache exists or the addon is not enabled.

### Preset isolation

aap-demo creates MicroShift clusters only (`CRC_PRESET=microshift`). The cache is stored at:

```
~/.aap-demo/local-cache/microshift/
```

The directory layout retains a preset segment for compatibility if additional presets are
reintroduced later.

### Technical details

- **SSH `-n` flag**: The save loop reads image refs from a heredoc via `while read`. Without
  `-n`, SSH consumes stdin from the heredoc, causing the loop to exit after 1-2 images.
- **`--remove-signatures`**: Required for `skopeo copy` to `docker-archive:` format.
  Without it, skopeo fails with "Storing signatures for docker tar files is not supported".
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
- Auto-load during deploy is transparent — no extra step required after initial save

### Negative

- Cache is ~30 GB on disk for a full AAP deployment (~50 images)
- Save operation takes 10–15 minutes (same as pulling — images must be exported from CRI-O)
- Images are stored uncompressed in docker-archive format; no deduplication of shared layers
  across images

### Neutral

- The addon is listed in `AVAILABLE_ADDONS` and visible in `aap-demo enable` output
- `aap-demo destroy` clears `ADDONS=` from config but does not delete on-disk cache files.
  After recreate, run `aap-demo enable local-cache load` then `aap-demo enable local-cache`
  to reload images and restore auto-load on deploy. Use `aap-demo enable local-cache clear`
  or `aap-demo disable local-cache` to reclaim disk space

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
- [ADR-020](020-full-openshift-support.md) — Full OpenShift support (preset detection)
- [addons/local-cache/deploy.sh](../../addons/local-cache/deploy.sh)
- [aap-demo.sh](../../aap-demo.sh) — `_load_local_cache()` auto-load function
