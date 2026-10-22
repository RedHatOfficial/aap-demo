# Fleet

The Fleet addon runs local QEMU VMs and registers them as AAP managed nodes.
`aap-demo enable fleet` checks host tools, brings in a QCOW2 cloud image, creates
the VMs, and registers them with AAP.

## Prerequisites

Fleet needs QEMU, `qemu-img`, and `mkisofs` or `genisoimage` on the host.

When `aap-demo enable fleet` is run interactively, missing prerequisites can be
installed after confirmation:

- macOS: `brew install qemu cdrtools`
- Fedora/RHEL: `sudo dnf install -y qemu-kvm qemu-img genisoimage`

Automatic installation is disabled for `QUIET=true` and non-interactive runs.
Those runs print the platform-specific commands instead, so CI and scripts do
not unexpectedly invoke a package manager or `sudo`.

## Cloud image

Fleet needs a QCOW2 cloud image. In a terminal, `aap-demo enable fleet` asks
when `FLEET_IMAGE` is not already set:

1. Download CentOS Stream 9 GenericCloud for this machine (`x86_64` or `aarch64`)
2. Use a local `.qcow2` file
3. Download a `.qcow2` from a URL

The CentOS Stream image is larger than 1 GB. It is cached under
`~/.aap-demo/cache/fleet/` and checked against the SHA256 in the upstream
`CHECKSUM` file. `aap-demo fleet destroy` removes the VMs and does not delete
that cache. A later enable reuses the cached image when the checksum still
matches.

Non-interactive and `QUIET=true` runs do not download an image unless one is
selected:

```bash
FLEET_DOWNLOAD_IMAGE=true aap-demo enable fleet
FLEET_IMAGE=/path/to/image.qcow2 aap-demo enable fleet
FLEET_IMAGE=https://example.com/image.qcow2 aap-demo enable fleet
FLEET_IMAGE_URL=https://example.com/image.qcow2 aap-demo enable fleet
FLEET_IMAGE_SHA256=<sha256> FLEET_IMAGE_URL=https://example.com/image.qcow2 aap-demo enable fleet
```

`FLEET_IMAGE` may be a local path or an `http://` or `https://` URL. The
resolved path is saved and reused by the next enable and by `aap-demo fleet add`.
Set `FLEET_IMAGE_SHA256` when the URL is not a CentOS Stream GenericCloud image
and you want the download rejected unless it matches that digest.

```bash
aap-demo fleet add 1
aap-demo fleet add 1 --image ~/rhel9.qcow2
aap-demo fleet add 1 --image https://example.com/image.qcow2
```
