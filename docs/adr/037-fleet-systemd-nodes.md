# ADR-037: Fleet Nodes Run systemd as PID 1

**Status**: Accepted

**Date**: 2026-11-02

**Authors**: aap-demo maintainers

---

## Context

ADR-032 runs each Fleet node as a pod whose only process is `sshd`. With no init system,
`reboot`, `shutdown`, and `systemctl` all fail with `System has not been booted with systemd as init
system (PID 1)`. Playbooks that reboot a host or manage a service, which are common in demos, fail
on Fleet nodes.

The UBI 9 and UBI 10 images Fleet already uses include systemd, and it boots cleanly in a container.
Two things stop it on MicroShift:

- CRI-O prepares a systemd container (a writable cgroup and tmpfs mounts) only when the container's
  command is init itself, not a wrapper script that later runs init.
- SELinux on the CRC VM blocks the cgroup write until the `container_manage_cgroup` boolean is on.
  Without it, systemd exits at boot with `Failed to create /init.scope control group`.

## Decision

The node container runs `/sbin/init --unit=fleet.target`. The pod's ConfigMap supplies two units,
mounted into `/etc/systemd/system`:

- `fleet-setup.service` runs the entrypoint's setup at every boot: restore the saved `/etc`, install
  `sshd` if missing, write the `ansible` user's key and sudoers file, then start `sshd` and anything
  else the restored `/etc` enables. Its stop step saves `/etc` to the disk at every shutdown.
- `fleet.target` pulls in `multi-user.target` and `fleet-setup.service`.

A `preStop` hook sends `SIGRTMIN+3`, systemd's clean halt, because systemd ignores the `SIGTERM`
that Kubernetes sends.

`enable fleet` and `fleet add` turn on `container_manage_cgroup` on the CRC VM over SSH with
`setsebool -P`, so it stays on across VM restarts. A VM that already has it on is left alone.

The images, the security context constraint, and the disk layout from ADR-032 do not change.

## Consequences

### Positive

- `reboot`, `shutdown -r`, `systemctl`, and the `service` and `systemd_service` modules work.
- A reboot restarts the node's container. The disk, the saved `/etc`, and enabled services are back
  after it.
- `/etc` changes made while the node runs are kept across a clean reboot or a stopped pod. Before,
  `/etc` was saved only at boot.
- Existing node disks keep working, because the images already include systemd.

### Negative

- `ansible.builtin.reboot` needs `boot_time_command: cut -d' ' -f22 /proc/1/stat`. A container
  shares the cluster VM's kernel, so the default boot ID check never changes and the module times
  out after the node has rebooted.
- `container_manage_cgroup` lets every container on the VM write its own cgroup. This is a local
  demo cluster, so the wider permission is accepted.
- Kubernetes backs off a container that restarts often, so many reboots in a few minutes take longer
  each time.

### Neutral

- Packages that set file capabilities, such as `httpd`, still fail to install, as they did before.
- The bash QEMU Fleet is unchanged.

## Alternatives Considered

### Keep `sshd` as PID 1 and document killing it

`kill 1` restarts the container, but `systemctl`, the `service` module, and `reboot` still fail.

### A wrapper script that runs setup, then `exec /sbin/init`

CRI-O does not prepare the container for systemd when the command is a script, and systemd exits
at boot.

### Switch to the `ubi-init` images

The plain UBI images already include systemd. A new image would also need every existing node
disk to be reseeded.

### KubeVirt virtual machines

Real reboots, but a heavy operator on a small local cluster. ADR-032 already left KubeVirt out.

## References

- [ADR-032: Fleet v2 addon](032-fleet-v2-addon.md)
- [Issue #196](https://github.com/RedHatOfficial/aap-demo/issues/196): container-native fleet nodes
- [Add-ons guide](../guides/addons.md)
