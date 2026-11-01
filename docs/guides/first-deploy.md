---
type: Guide
title: First deploy
description: Create a local cluster, install Ansible Automation Platform, and open it.
tags: [deploy, cluster, pull-secret]
status: draft
stale_after: 2027-01-28
generated:
  by: cursor-agent/grok-4.7
  at: 2026-10-29T00:30:00Z
resource: https://github.com/RedHatOfficial/aap-demo
---

# First deploy

Plan on a machine that can spare about 8 processors and 24 GB of memory for the virtual machine.
Those are the defaults. Smaller sizes are in [Settings](../reference/settings.md).

## What to install first

- [OpenShift Local](https://console.redhat.com/openshift/create/local) (the `crc` command)
- `kubectl`
- On Linux: `libvirt-daemon`, `libvirt-daemon-driver-storage`, and `qemu-kvm`

On Linux, if `create` says the CRC daemon socket is missing, start it:

```bash
crc daemon
```

## 1. Save your pull secret

A pull secret lets the cluster download Red Hat images. Download one from the
[Red Hat console](https://console.redhat.com/openshift/install/pull-secret), then:

```bash
mkdir -p ~/.local/state/aap-demo
cp ~/Downloads/pull-secret.txt ~/.local/state/aap-demo/pull-secret.txt
```

A file named `pull-secret.json` in that same folder also works. The command does not look in `~/.aap-demo`.

To point at a file somewhere else:

```bash
aap-demo config set pull-secret ~/secrets/pull-secret.txt
```

## 2. Create the cluster

```bash
aap-demo create
```

This builds the virtual machine only. It does not install AAP yet. If a cluster is already running,
`create` stops and tells you to deploy or destroy first.

`create` downloads CRC 2.64.0 when the `crc` command on your PATH is older. That release's
`crc setup` uses sudo to run `setcap cap_net_bind_service=+ep` on the binary. The capability
is `CAP_NET_BIND_SERVICE`, so CRC can bind low ports without staying root. aap-demo does not
run `setcap` itself. If sudo cannot prompt, `create` stops.

To keep an older CRC that is already installed, lower the MicroShift floor for this command.
This is the same override `deploy` accepts:

```bash
CRC_VERSION=4.21 aap-demo create
```

## 3. Install AAP

```bash
aap-demo deploy
aap-demo status
```

`deploy` installs AAP 2.7 unless you [choose another version](choose-a-version.md). It creates a cluster
if there is none and starts one that was stopped. It does not add extra demo content.

`status` prints the web address and the admin password. Open that address in your browser.

## Your cluster login file

`create` saves a kubeconfig file at:

`~/.local/state/aap-demo/kubeconfig.microshift`

It also adds a context named `aap-demo` to `~/.kube/config` and selects it, so `kubectl` and `oc` see this
cluster. Your other clusters in that file stay. Run `aap-demo kubeconfig` later if you recreated the virtual
machine and need a fresh login.

```bash
aap-demo oc get nodes
```
