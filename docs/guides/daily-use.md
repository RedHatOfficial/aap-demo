---
type: Guide
title: Daily use
description: Start, stop, pause, and check a cluster you already created.
tags: [operations, status]
status: draft
stale_after: 2027-01-28
generated:
  by: cursor-agent/grok-4.7
  at: 2026-10-29T00:30:00Z
resource: https://github.com/RedHatOfficial/aap-demo
---

# Daily use

After the first deploy, most days look like this.

```bash
aap-demo start       # turn the cluster on
aap-demo stop        # turn the cluster off
aap-demo status      # web address, password, and health
aap-demo ssh         # a shell on the cluster machine
```

## Pause AAP without shutting down

Idle leaves the virtual machine running and asks AAP to scale down, which frees memory inside the cluster.

```bash
aap-demo idle          # say whether it is paused
aap-demo idle true     # pause
aap-demo idle false    # wake it up
aap-demo watch         # follow the wake-up
```

`stop` is the one that returns the memory to your computer. Idle does not.

## When something looks wrong

```bash
aap-demo diagnose
aap-demo repair
aap-demo must-gather
```

`diagnose` prints a health report. It exits with an error only when it cannot reach the cluster at all.
`repair` is the one to try after the laptop sleeps and the site will not load. `must-gather` collects a folder
of logs you can hand to someone else.

`aap-demo diagnose --ai` adds a written guess from the Claude command-line tool, if you have that tool installed.

## Remove AAP, or remove everything

```bash
aap-demo clean      # remove AAP, keep the cluster
aap-demo destroy    # delete the cluster
```

`destroy --reset` also clears your saved settings file. `aap-demo redeploy` removes AAP and installs it again.
