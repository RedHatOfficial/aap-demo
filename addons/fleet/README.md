# Fleet prerequisites

The Fleet addon runs local QEMU VMs and therefore needs QEMU, `qemu-img`, and
`mkisofs` or `genisoimage` on the host.

When `aap-demo enable fleet` is run interactively, missing prerequisites can be
installed after confirmation:

- macOS: `brew install qemu cdrtools`
- Fedora/RHEL: `sudo dnf install -y qemu-kvm qemu-img genisoimage`

Automatic installation is disabled for `QUIET=true` and non-interactive runs.
Those runs print the platform-specific commands instead, so CI and scripts do
not unexpectedly invoke a package manager or `sudo`.

After installing the tools, create a Fleet node with a readable RHEL/CentOS
QCOW2 cloud image:

```bash
aap-demo fleet add 1 --image ~/rhel9.qcow2
```
