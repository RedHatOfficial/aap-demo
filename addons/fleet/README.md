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

## Registering nodes to the Satellite lab

When the Satellite lab is built (`aap-demo create --full-demo --satellite`),
register running Fleet nodes to it so they pull content from the local Pulp and
appear in the Satellite inventory:

```bash
aap-demo fleet satellite-register
```

This creates a `fleet-rhel9` activation key on the Satellite (bound to the
content view that has repositories), trusts the Satellite CA on each node, and
registers with `subscription-manager --activationkey`. It is idempotent and
handles two lab-specific cases: cloned nodes share a DMI UUID (each node writes
a unique `dmi.system.uuid` rhsm fact first), and a stale Insights `.registered`
file from a prior direct-to-Red-Hat attempt is cleared before re-registering.

Use `aap-demo fleet rhc-connect` instead when there is no Satellite and nodes
should enroll directly with Red Hat.
