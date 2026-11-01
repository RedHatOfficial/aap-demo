# AAP Demo

Ansible Automation Platform, on your own computer, for demos and trying things out.

This is a local tool. Do not use it for a real production system. The published command is a beta,
version **2.0.0.dev2**. A finished 2.0.0 release is not out yet.

## Start

Here is the short path from a new computer to a page you can open.

You will need three things:

- Python 3.9 or newer, and [pipx](https://pipx.pypa.io/). pipx keeps this
  command in its own corner, away from your other Python tools.
- [OpenShift Local](https://console.redhat.com/openshift/create/local), so you
  have the `crc` command, plus `kubectl`.
- A pull secret from the
  [Red Hat console](https://console.redhat.com/openshift/install/pull-secret).
  The cluster uses it to download Red Hat images.

Save the pull secret in the folder the command checks:

```bash
mkdir -p ~/.local/state/aap-demo
cp ~/Downloads/pull-secret.txt ~/.local/state/aap-demo/pull-secret.txt
```

A file named `pull-secret.json` in that same folder also works.

Give the machine about 8 processors and 24 GB of memory. The first `create`
builds a virtual machine, so give it a few quiet minutes. Smaller sizes, and
the extra Linux packages, are in [First deploy](docs/guides/first-deploy.md).

Install the command, build the cluster, and install Ansible Automation Platform:

```bash
pipx install aap-demo
aap-demo create
aap-demo deploy
aap-demo status
```

`create` builds the local cluster. `deploy` installs Ansible Automation Platform.
`status` prints the web address and the admin password.

To try AAP 2.6 instead of the usual 2.7 release:

```bash
aap-demo deploy --channel stable-2.6
```

With no `--channel` flag, `deploy` uses the default channel, `stable-2.7`.

Open the address `status` prints and sign in with the admin password on that
screen. `aap-demo version` should print `2.0.0.dev2`.

Tomorrow, `aap-demo start` turns the cluster on and `aap-demo stop` turns it
off. [Daily use](docs/guides/daily-use.md) covers later days, including a page
that will not load.

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
- [Contributing](CONTRIBUTING.md)
