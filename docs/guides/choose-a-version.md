---
type: Guide
title: Choose a version
description: Deploy the usual AAP 2.7 release, or ask for the 2.6 channel instead.
tags: [deploy, channel, aap]
status: draft
stale_after: 2027-01-28
generated:
  by: cursor-agent/grok-4.7
  at: 2026-10-29T00:30:00Z
resource: https://github.com/RedHatOfficial/aap-demo
---

# Choose a version

`aap-demo deploy` installs Ansible Automation Platform **2.7** unless you say otherwise.

The switch is `--channel`. It is the name of the release line in Red Hat's catalog.

## AAP 2.6

```bash
aap-demo deploy --channel stable-2.6
```

## Keep that choice

```bash
aap-demo config set deploy.channel stable-2.6
aap-demo deploy
```

The next deploy uses the saved channel. Set it back with:

```bash
aap-demo config set deploy.channel stable-2.7
```

The default, if you never set one, is `stable-2.7`. Any channel name the catalog publishes is accepted. If the name is wrong, the install fails when it cannot find that line.
