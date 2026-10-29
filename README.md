# AAP Demo

Ansible Automation Platform, on your own computer, for demos and trying things out.

This is a local tool. Do not use it for a real production system. The published command is a beta, version **2.0.0.dev1**. A finished 2.0.0 release is not out yet.

## Start

You need Python 3.9 or newer, and [pipx](https://pipx.pypa.io/).

```bash
pipx install aap-demo
aap-demo create
aap-demo deploy
aap-demo status
```

`create` builds the local cluster. `deploy` installs Ansible Automation Platform. `status` prints the web address and the admin password.

To try AAP 2.6 instead of the usual 2.7 release:

```bash
aap-demo deploy --channel stable-2.6
```

## Guides

| I want to… | Read this |
| --- | --- |
| Install or update the command | [Install](docs/guides/install.md) |
| Put a cluster and AAP on this computer | [First deploy](docs/guides/first-deploy.md) |
| Choose AAP 2.6 or 2.7 | [Choose a version](docs/guides/choose-a-version.md) |
| Start, stop, and check on it later | [Daily use](docs/guides/daily-use.md) |
| Add demo machines or other extras | [Add-ons](docs/guides/addons.md) |
| Keep using a feature the new command does not have yet | [The older command](docs/guides/older-command.md) |

## Look something up

| | |
| --- | --- |
| Every command | [Commands](docs/reference/commands.md) |
| Memory, disk, and where files are saved | [Settings](docs/reference/settings.md) |
| A copy-paste first run | [Example: first cluster](docs/examples/first-cluster.md) |

## About this project

- [What aap-demo is](docs/concepts/what-aap-demo-is.md)
- [How the new command and the older one fit together](docs/concepts/two-ways-to-run.md)
- [Notes for the move onto the main download](docs/v2-to-main.md)
- [Design decisions](docs/adr/README.md)
- [Contributing](docs/CONTRIBUTING.md)
