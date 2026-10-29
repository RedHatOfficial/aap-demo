---
type: Guide
title: Install
description: Install the aap-demo command with pipx, and update it later.
tags: [install, pipx]
status: draft
stale_after: 2027-01-28
generated:
  by: cursor-agent/grok-4.7
  at: 2026-10-29T00:30:00Z
resource: https://github.com/RedHatOfficial/aap-demo
---

# Install

You need Python 3.9 or newer.

## New install

[pipx](https://pipx.pypa.io/) keeps aap-demo in its own corner, away from your other Python tools.

```bash
pipx install aap-demo
aap-demo version
```

You should see version `2.0.0.dev1`.

These install the same beta:

```bash
pip install 'aap-demo==2.0.0.dev1'
uv tool install aap-demo
```

If a plain `pip install aap-demo` says it cannot find a version, use the `2.0.0.dev1` line above. pip often skips beta versions unless you name them.

## Update

```bash
aap-demo update
aap-demo version
```

That upgrades the pipx install. It does not rebuild your cluster.

## If an older aap-demo is already on this computer

The older installer puts a bash script on your `PATH` at `~/.local/bin/aap-demo`. pipx wants that same spot. Move the old command out of the way first:

```bash
mv ~/.local/bin/aap-demo ~/.local/bin/aap-demo-v1
pipx install aap-demo
```

Keep `aap-demo-v1` if you still need a feature the new command does not have. See [The older command](older-command.md).

If both are installed and the bash one still runs, the new command will offer to rename it. Set `AAP_DEMO_KEEP_BASH=1` if you want that prompt skipped.

## Remove the command

```bash
pipx uninstall aap-demo
```

Your cluster files stay on disk until you delete them with `aap-demo destroy` first, or remove the folders yourself.
