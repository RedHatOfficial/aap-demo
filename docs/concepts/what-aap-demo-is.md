---
type: Concept
title: What aap-demo is
description: A local way to run Ansible Automation Platform for demos, not a production installer.
tags: [overview, beta]
status: draft
stale_after: 2027-01-28
resource: https://github.com/RedHatOfficial/aap-demo
sources:
  - id: v2-to-main
    resource: https://github.com/RedHatOfficial/aap-demo/blob/v2/docs/v2-to-main.md
    title: v2 to main
    author: human:aknochow
    last_modified: 2026-10-28T00:00:00Z
---

# What aap-demo is

aap-demo puts Ansible Automation Platform on the computer in front of you, so you can click through a demo
or try an idea without asking for a shared cluster.

It is a community tool. Red Hat does not support it as a product, and the settings it chooses are for a laptop.
Do not copy them into a system other people depend on.

## This beta

The command you install with pipx is version **2.0.0.dev2**. That number means the beta of the new command.
A finished 2.0.0 release has not been published. Until that happens, treat what you install as a beta:
useful, still changing, and not the final download.

The usual deploy installs AAP 2.7. You can ask for 2.6 instead. See [Choose a version](../guides/choose-a-version.md).

## What you get

- A small local OpenShift cluster (the MicroShift preset of OpenShift Local).
- Ansible Automation Platform on that cluster.
- A web address on this computer, and an admin password from `aap-demo status`.

The full OpenShift preset is not available in this beta. The command will say so if you ask for it.
