---
type: Reference
title: Settings
description: Default cluster size, the AAP channel, and the folders aap-demo uses.
tags: [config, paths, channel]
status: draft
stale_after: 2027-01-28
generated:
  by: cursor-agent/grok-4.7
  at: 2026-10-29T00:30:00Z
resource: https://github.com/RedHatOfficial/aap-demo
---

# Settings

Change a setting for one run with a flag, or save it:

```bash
aap-demo config set deploy.channel stable-2.6
aap-demo config list
aap-demo config path
```

The file is `~/.config/aap-demo/config.yaml`.

## Cluster size

Defaults when you `create`:

| | Default | Flag | Environment variable |
| --- | --- | --- | --- |
| Processors | 8 | `--cpus` | `CRC_CPUS` |
| Memory | 24576 MB (24 GB) | `--memory` | `CRC_MEMORY` |
| Disk | 120 GB | `--disk` | `CRC_DISK` |
| Space for volumes | 100 GB | `--pv-size` | `CRC_PV_SIZE` |

`create` warns if the computer itself has fewer than 4 processors or 10 GB of memory. Set the size before
the virtual machine exists. Changing it later means `destroy` and `create` again.

```bash
aap-demo create --cpus 6 --memory 16384 --disk 80 --pv-size 60
```

## AAP version

| | |
| --- | --- |
| Default channel | `stable-2.7` |
| Flag | `--channel` on `deploy` |
| Saved key | `deploy.channel` |

See [Choose a version](../guides/choose-a-version.md).

## Where files go

| What | Where |
| --- | --- |
| Settings | `~/.config/aap-demo/config.yaml` |
| Pull secret | `~/.local/state/aap-demo/pull-secret.txt` |
| Kubeconfig | `~/.local/state/aap-demo/kubeconfig.microshift` |
| Cluster certificate | `~/.local/state/aap-demo/certs/` |
| Cache | `~/.cache/aap-demo` |

`AAP_DEMO_DIR` puts settings, state, and cache under one folder you choose. That is for CI and for unusual
layouts, not for a normal install.

The older bash command uses `~/.aap-demo` instead. The new command does not look there.
