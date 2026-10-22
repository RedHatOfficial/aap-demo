# ADR-034: Fleet Cloud Image Download

**Status**: Accepted

**Date**: 2026-10-22

**Authors**: aap-demo maintainers

## Context

`aap-demo enable fleet` creates local QEMU managed nodes, but it can only do
that when a QCOW2 cloud image is already on disk. New users do not have a
RHEL or CentOS cloud image, and the enable command used to stop at a prompt
for a local path.

RHEL cloud images on access.redhat.com require an account download and are not
authorized by the registry pull secret already stored for aap-demo. The image
also has to exist for both `x86_64` and `aarch64`, because Fleet runs on Linux
and on Apple Silicon Macs. A multi-gigabyte disk image must not be committed
to the repository, and `QUIET=true` or non-interactive runs must not start a
large download unless the caller asks for one.

## Decision

`aap-demo enable fleet` and `aap-demo fleet add` resolve a cloud image before
creating VMs:

1. Use `FLEET_IMAGE` when it is a local file or an `http://` / `https://` URL.
2. Otherwise use `FLEET_IMAGE_URL`.
3. Otherwise, when `FLEET_DOWNLOAD_IMAGE=true`, download CentOS Stream 9
   GenericCloud for the host architecture.
4. Otherwise, in an interactive terminal, offer that download, a local path,
   or a custom URL.
5. Otherwise fail and print the variables above.

The default images are:

- `https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2`
- `https://cloud.centos.org/centos/9-stream/aarch64/images/CentOS-Stream-GenericCloud-9-latest.aarch64.qcow2`

Downloads are stored in `~/.aap-demo/cache/fleet/`, outside the directory
removed by `aap-demo fleet destroy`. A cached CentOS image is reused when its
SHA256 still matches the `CHECKSUM` file published beside the image. If that
checksum changes, the cached file is replaced. Custom URLs are not checked
against a remote checksum unless `FLEET_IMAGE_SHA256` is set. The resolved
local path is saved as `FLEET_IMAGE` for the next enable or `fleet add`.

QEMU tools are still required before a download starts. Quiet and
non-interactive runs still do not install those tools automatically.

## Consequences

### Positive

- `aap-demo enable fleet` can bring in a bootable cloud image instead of
  requiring the user to find one first.
- The same image is reused across enable, `fleet add`, and fleet destroy.
- A truncated or swapped CentOS download is rejected when its digest does not
  match the published checksum.
- Scripted runs stay explicit: they download only when given an image, a URL,
  or `FLEET_DOWNLOAD_IMAGE=true`.

### Negative

- The default image is CentOS Stream, not a Red Hat subscription image.
- The first download is larger than 1 GB and needs network access to
  cloud.centos.org.
- The published checksum and the image live on the same host, so this checks
  integrity of the transfer. It does not verify a PGP signature.
- Fleet still copies the image into `~/.aap-demo/fleet/base.qcow2` for the VM
  overlay disks, so a successful enable uses the cache plus that copy.

### Neutral

- Callers who already have a QCOW2 keep passing it with `FLEET_IMAGE` or
  `--image`.
- Fleet remains unavailable on Windows.

## Alternatives Considered

### Keep requiring a pre-downloaded file

Rejected. Enable already creates the VMs, and stopping because the image is
absent is the failure this change removes.

### Vendor a QCOW2 in the repository

Rejected. The cloud image is larger than 1 GB and moves when CentOS Stream
publishes a new GenericCloud build.

### Download a RHEL image with the registry pull secret

Rejected. The pull secret authorizes container registries. It does not
authorize qcow downloads from access.redhat.com.

### Pin one CentOS digest forever

Rejected. The `latest` filename is updated in place. Re-checking the published
checksum lets a later enable pick up a new build without a code change, and
`FLEET_IMAGE_SHA256` remains available when a caller wants a pin.

## References

- [ADR-026](026-fleet-addon.md)
- [addons/fleet/deploy.sh](../../addons/fleet/deploy.sh)
- [addons/fleet/fleet.sh](../../addons/fleet/fleet.sh)
- Issue #194
