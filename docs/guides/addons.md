---
type: Guide
title: Add-ons
description: Fleet demo machines in the new command, and where the other extras still live.
tags: [addons, fleet]
status: draft
stale_after: 2027-01-28
resource: https://github.com/RedHatOfficial/aap-demo
---

# Add-ons

Add-ons are optional extras on top of AAP: a self-service portal, demo job templates, a local model, and practice machines.

## Practice machines (Fleet)

The new command can add small Linux machines that show up as hosts in AAP. They run inside the same local cluster.

```bash
aap-demo enable fleet
aap-demo fleet list
aap-demo fleet add --os ubi9
aap-demo fleet remove fleet-ubi9
aap-demo disable fleet
aap-demo fleet destroy
```

`enable fleet` creates two machines by default, `fleet-ubi9` and `fleet-ubi10`, and registers them in AAP.
Registering needs a [subscription](subscription.md) in AAP. Without one, use `aap-demo enable fleet --no-import`.
Add `--no-import` if you want the machines without that registration.

`disable fleet` turns the machines off and leaves the registration in place. `fleet destroy` removes both.

### Reboots and services

Each machine runs systemd, so `sudo reboot`, `systemctl`, and the `service` and `systemd_service` modules work.
A reboot restarts the machine's container, usually within two minutes. Installed packages, `/etc`, and enabled services are
still there afterward. `enable fleet` turns on the `container_manage_cgroup` SELinux setting on the cluster VM,
which systemd needs.

`ansible.builtin.reboot` needs one extra option. The machines share the cluster's kernel, so the boot ID the module
checks by default never changes, and the module waits until it times out:

```yaml
- name: Reboot a Fleet machine
  ansible.builtin.reboot:
    boot_time_command: cut -d' ' -f22 /proc/1/stat
```

Packages that set file capabilities, such as `httpd`, do not install on these machines.

## Everything else

Portal, Automation Orchestrator, product demos, a local cache of container images, and the MCP server are not
in the new command yet. Asking the new command for one of them stops with a short error, and your cluster is
left as it was.

Use [the older command](older-command.md) for those. For example, after you have renamed it:

```bash
aap-demo-v1 enable portal
```

Each of those extras will move to the new command on its own. Until a page says otherwise, the older command
is the way to install them. Nothing you already run with the older command is being removed in this beta.
