---
type: Reference
title: Commands
description: What each aap-demo command does in the 2.0.0.dev1 beta.
tags: [cli, reference]
status: draft
stale_after: 2027-01-28
generated:
  by: cursor-agent/grok-4.7
  at: 2026-10-29T00:30:00Z
resource: https://github.com/RedHatOfficial/aap-demo
---

# Commands

These are the commands in the new `aap-demo` (version 2.0.0.dev1). Jobs that are not listed as working here
still run with [the older command](../guides/older-command.md).

## You will use these

| Command | What it does |
| --- | --- |
| `create` | Build the local MicroShift cluster. |
| `deploy` | Install AAP. Default channel is `stable-2.7`. See [Choose a version](../guides/choose-a-version.md). |
| `status` | Show the web address, the admin password, and whether things are up. |
| `start` / `stop` | Turn the cluster on or off. |
| `idle true` / `idle false` | Pause or wake AAP. No word after `idle` prints the current state. |
| `watch` | Follow an install or a wake-up until it settles. |
| `ssh` | Open a shell on the cluster machine. |
| `oc …` | Run `oc` against this cluster. Everything after `oc` is passed through. |
| `kubeconfig` | Refresh the login file and the `aap-demo` context in `~/.kube/config`. |
| `diagnose` | Print a health report. `--ai` asks the Claude command-line tool to comment. |
| `repair` | Fix the usual breakage after the laptop sleeps. |
| `must-gather` | Collect logs into a folder. An optional path picks the folder. |
| `clean` | Remove AAP and keep the cluster. |
| `redeploy` | `clean`, then `deploy`. |
| `redeploy-all` | Delete the cluster, create it again, and install AAP. |
| `destroy` | Delete the cluster. `--reset` also clears saved settings. |
| `update` | Upgrade the pipx install of the command. |
| `version` | Print `2.0.0.dev1` and how this copy was installed. |
| `enable fleet` | Add the practice machines. `--no-import` skips registering them in AAP. |
| `disable fleet` | Turn those machines off. Leaves their AAP registration. |
| `fleet list` | Show the practice machines. |
| `fleet add --os ubi9` | Add one machine. `--name` picks the name. `ubi10` is the other choice. |
| `fleet remove NAME` | Remove that one machine. |
| `fleet destroy` | Remove the machines and the AAP records this add-on created. |
| `config …` | Read and write settings. See [Settings](settings.md). |
| `redhat-status` | Show public Red Hat service incidents. `rh-status` is the short name. |

## Accepted, then refused

These names exist so old habits are not a mystery, and they stop with "not implemented" rather than doing the old work:

`addon`, `playbooks`, `gui`, `completion`

`enable` and `disable` with a name other than `fleet` stop with "only fleet is implemented."
`enable` with no name prints `fleet`.

Use the older command for portal, Automation Orchestrator, product demos, and the image cache.
