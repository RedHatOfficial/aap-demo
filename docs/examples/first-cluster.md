---
type: Example
title: First cluster
description: Copy-paste path from a new computer to an AAP page you can open.
tags: [example, deploy]
status: draft
stale_after: 2027-01-28
generated:
  by: cursor-agent/grok-4.7
  at: 2026-10-29T00:30:00Z
resource: https://github.com/RedHatOfficial/aap-demo
---

# First cluster

OpenShift Local is already installed, `kubectl` is on your `PATH`, and you have a pull secret downloaded.

```bash
pipx install aap-demo

mkdir -p ~/.local/state/aap-demo
cp ~/Downloads/pull-secret.txt ~/.local/state/aap-demo/pull-secret.txt

aap-demo create
aap-demo deploy
aap-demo status
```

Open the address `status` prints. Sign in with the admin password on that same screen.

A smaller virtual machine, if 24 GB is too much:

```bash
aap-demo create --memory 16384 --disk 80 --pv-size 60
```

Do that instead of the plain `create` above, not after it.
