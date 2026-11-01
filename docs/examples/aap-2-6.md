---
type: Example
title: AAP 2.6
description: Deploy the stable-2.6 channel instead of the default 2.7.
tags: [example, channel]
status: draft
stale_after: 2027-01-28
resource: https://github.com/RedHatOfficial/aap-demo
---

# AAP 2.6

The cluster from [First cluster](first-cluster.md) already exists. Install 2.6 instead of 2.7:

```bash
aap-demo deploy --channel stable-2.6
aap-demo status
```

To make 2.6 the usual choice on this computer:

```bash
aap-demo config set deploy.channel stable-2.6
```

The background is in [Choose a version](../guides/choose-a-version.md).
