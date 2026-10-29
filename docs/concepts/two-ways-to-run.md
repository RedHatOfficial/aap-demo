---
type: Concept
title: Two ways to run aap-demo
description: The new command is the one to install. The older command still covers what has not moved yet.
tags: [compatibility, bash, beta]
status: draft
stale_after: 2027-01-28
generated:
  by: cursor-agent/grok-4.7
  at: 2026-10-29T00:30:00Z
resource: https://github.com/RedHatOfficial/aap-demo
sources:
  - id: v2-to-main
    resource: https://github.com/RedHatOfficial/aap-demo/blob/v2/docs/v2-to-main.md
    title: v2 to main
    author: human:aknochow
    last_modified: 2026-10-28T00:00:00Z
---

# Two ways to run aap-demo

There are two commands, on purpose.

| | New command | Older command |
| --- | --- | --- |
| How you get it | `pipx install aap-demo` | Clone the repo and run `./install.sh` |
| What it is | The Python beta, version 2.0.0.dev1 | The bash script `aap-demo.sh` |
| Where your files go | `~/.local/state/aap-demo` | `~/.aap-demo` |
| What to use it for | Create the cluster, deploy AAP, day-to-day start and stop, Fleet | Anything the new command does not do yet |

You can keep both. If the older command is installed as `aap-demo`, rename it to `aap-demo-v1` before you
install the new one, so the new command is the one that runs. The steps are in
[The older command](../guides/older-command.md).

## Nothing is being switched off

Features move one at a time. When the new command cannot do something yet, use the older command for that job.
We will say so on the page for that feature when a move happens. There is no list of removals in this beta.

The bash scripts stay in the project through the move onto the main download. Taking them out is a later
cleanup, after the work has actually moved. That cleanup is not part of publishing this beta.

## Where the engineering note lives

[v2 to main](../v2-to-main.md) is the record of the two install paths for people reviewing that move.
The guides in this folder are the pages to follow when you just want the product running.
