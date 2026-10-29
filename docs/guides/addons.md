---
type: Guide
title: Add-ons
description: Fleet demo machines in the new command, and where the other extras still live.
tags: [addons, fleet]
status: draft
stale_after: 2027-01-28
generated:
  by: cursor-agent/grok-4.7
  at: 2026-10-29T00:30:00Z
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

`enable fleet` creates two machines by default, `fleet-ubi9` and `fleet-ubi10`, and registers them in AAP. Add `--no-import` if you want the machines without that registration.

`disable fleet` turns the machines off and leaves the registration in place. `fleet destroy` removes both.

## Everything else

Portal, Automation Orchestrator, product demos, a local cache of container images, and the MCP server are not in the new command yet. Asking the new command for one of them stops with a short error, and your cluster is left as it was.

Use [the older command](older-command.md) for those. For example, after you have renamed it:

```bash
aap-demo-v1 enable portal
```

Each of those extras will move to the new command on its own. Until a page says otherwise, the older command is the way to install them. Nothing you already run with the older command is being removed in this beta.
