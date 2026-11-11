# AAP Demo

[![PyPI](https://img.shields.io/pypi/v/aap-demo)](https://pypi.org/project/aap-demo/)

Ansible Automation Platform, on your own computer, for demos and trying things out.

This is a local tool. Do not use it for a real production system. The published command is a release
candidate, a prerelease of 2.0.0. A finished 2.0.0 release is not out yet. The
[PyPI page](https://pypi.org/project/aap-demo/) and the badge above show the current version.

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

[Install](docs/guides/install.md) has more on getting the command and updating it.

Save the pull secret in the folder the command checks:

```bash
mkdir -p ~/.config/aap-demo
cp ~/Downloads/pull-secret.txt ~/.config/aap-demo/pull-secret.txt
```

A file named `pull-secret.json` in that same folder also works. To keep it somewhere else, see
[Save your pull secret](docs/guides/first-deploy.md#1-save-your-pull-secret).

Give the machine about 8 processors and 24 GB of memory. The first `create`
builds a virtual machine, so give it a few quiet minutes. Smaller sizes, and
the extra Linux packages, are in [First deploy](docs/guides/first-deploy.md).

Install the command, build the cluster, and install Ansible Automation Platform:

Download your pull secret to `~/Downloads/pull-secret.txt`, then run:

```bash
pipx install aap-demo
aap-demo create
aap-demo deploy
aap-demo status
```

`create` builds the local cluster. `deploy` installs Ansible Automation Platform.
`status` prints the web address and the admin password. [First deploy](docs/guides/first-deploy.md)
walks through each step.

To try AAP 2.6 instead of the usual 2.7 release:

```bash
aap-demo deploy --channel stable-2.6
```

With no `--channel` flag, `deploy` uses the default channel, `stable-2.7`. See
[Choose a version](docs/guides/choose-a-version.md).

Open the address `status` prints and sign in with the admin password on that
screen.

AAP runs without a subscription, but it needs one before it can add hosts. Nothing
is applied unless you choose to. [Subscription](docs/guides/subscription.md) shows
how to apply one, by signing in to AAP or by giving `aap-demo` a manifest file.

`aap-demo version` prints the version you installed.

Tomorrow, `aap-demo start` turns the cluster on and `aap-demo stop` turns it
off. [Daily use](docs/guides/daily-use.md) covers later days, including a page
that will not load.

## Addons to add additional functionality

```bash
aap-demo enable              # List all addons
aap-demo enable portal       # Installs Automation Portal
aap-demo enable portal-operator # Installs Operator-based Portal (Technology Preview; AMD64 only)
aap-demo enable setup-pah     # Configures Private Automation Hub Credentials
aap-demo enable mcp-server   # MCP server for AI assistants
aap-demo enable ao           # Automation Orchestrator (GA; no aapctl required — see addons/ao/README.md)
aap-demo enable lightspeed   # Ansible Lightspeed assistant, backed by the local Ollama LLM
aap-demo enable apme-eap     # Early Access Program only for APME
aap-demo enable local-cache  # Caches AAP containers locally so you don't re-download after destroy/create

# Ansible Product Demos - Official demo content from ansible/product-demos
aap-demo enable product-demos        # Five domains at once (includes base; Satellite opt-in)
aap-demo enable product-demo-satellite  # Satellite demos (requires a Satellite server)

# Satellite lab
aap-demo enable satellite-manifest   # Create + download a Satellite subscription manifest
                                     # via the RHSM API (for satellite-lab/03-content-hammer.sh)
aap-demo fleet satellite-register    # Register running Fleet nodes to the Satellite lab
                                     # (content from local Pulp; hosts appear in the Satellite inventory)
aap-demo disable addon_name  # Disables addon
```

### Common commands

```bash
# Deployment
aap-demo deploy              # Deploy AAP 2.7
aap-demo create --full-demo  # Create AAP + Ollama/AO + three RHEL 9 Fleet nodes + boot recovery + dashboard
aap-demo create --full-demo --satellite
                             # Also build/configure the Satellite lab and Satellite Demo

# Cluster management
aap-demo status              # Show cluster status and routes; secrets stay hidden
aap-demo status --show-secrets # Reveal credentials interactively
aap-demo stop                # Stop the cluster
aap-demo start               # Resume the configured demo and wait for readiness
aap-demo ssh                 # SSH into the cluster node
aap-demo watch               # Monitor deployment progress
aap-demo destroy             # Delete entire cluster

# Maintenance
aap-demo maintenance         # Preview reclaimable VM runtime data
aap-demo maintenance --apply # Remove exited containers, unused images, and old caches/logs
aap-demo maintenance uninstall         # Preview complete environment removal
aap-demo maintenance uninstall --apply # Remove VMs, caches, trust, CLI, and residual state
                                       # (keeps the credential Vault for rebuilds)
aap-demo maintenance uninstall --apply --reconfigure
                                       # Also strip the aap_demo entries from the shared Vault
aap-demo clean               # Remove AAP deployment (keeps cluster)
aap-demo update              # Pull latest code and reinstall
aap-demo help                # Full command reference
```

`aap-demo create --full-demo` is a fail-fast demo bootstrap.
It creates a cluster sized for the included addons, deploys AAP 2.7, configures
Automation Hub, enables the offline-token keepalive, enables Ollama and
Automation Orchestrator, then enables Fleet, attaches the AAP subscription, and
reconciles three started and registered RHEL 9 nodes. Product Demos is installed
after licensing succeeds. A final strict `aap-demo wire` runs after all
components are present, then automatic boot recovery is installed and the
dashboard launches. Recovery installation and dashboard startup must both succeed
before full-demo reports success. Fleet image download
and AAP subscription attachment require Red Hat credentials. Full-demo checks
them first and starts the secure `fleet auth` prompts when they are missing or
invalid. Runs with `QUIET=true` remain noninteractive and require credentials to
be configured in advance. If the Automation Hub token is not configured,
setup-pah prompts for that distinct token. Customer Portal and Automation Hub
tokens remain separate in encrypted storage. Reruns reuse existing Fleet nodes
instead of creating duplicates. Use `--no-open` to run the dashboard without
opening a browser.

### Dashboard

`aap-demo dashboard` starts the localhost dashboard **in the background** and
returns to your terminal after its HTTP listener is ready. It opens your browser
unless you pass `--no-open`. Running the command again reuses the dashboard for
this checkout rather than starting a duplicate.

The Environment Overview shows the host OS, the CRC guest OS when available,
and the AAP subscription selected during automatic licensing. The small
**Restart dashboard** button reloads the dashboard server and reconnects the
page without restarting CRC, AAP or Fleet. Restart is blocked during an active
dashboard add-on operation.

The default address is `http://127.0.0.1:8765`; set `AAP_DEMO_DASHBOARD_PORT`
to choose another port. Logs go to `~/.aap-demo/dashboard.log` (or
`$AAP_DEMO_DIR/dashboard.log`). It also starts automatically after `aap-demo create`,
`start` and `restart` (set `AAP_DEMO_DASHBOARD_AUTOSTART=false` to disable).
On Linux the first run also adds a desktop login entry
(`~/.config/autostart/aap-demo-dashboard.desktop`) so the dashboard opens after
reboot. For foreground debugging, run `python3 dashboard/server.py --no-open`.
Background mode does not install a boot/login service.

### OpenShift web console (single-node OpenShift preset)

MicroShift, the default preset, has no web console. For the full single-node
OpenShift console, create the cluster with the OpenShift preset:

```bash
CRC_PRESET=openshift aap-demo create --full-demo
```

The preset is saved as `CRC_PRESET` in `~/.aap-demo/config`, so later `start`,
`restart` and boot recovery keep using it. `create`, `start`, `restart` and
`create --full-demo` open the console automatically; run `aap-demo console` (add
`--no-open` to only print the URL) at any time. Set
`AAP_DEMO_CONSOLE_AUTOOPEN=false` to disable the automatic open. Routes use
`*.apps-crc.testing` on this preset instead of nip.io. It needs more RAM than
MicroShift (see ADR-020).

To pick the tier automatically from host hardware, use
`scripts/aap-demo-tier-select.sh`. It inspects vCPUs, RAM and root disk space,
then deploys SNO (`CRC_PRESET=openshift`, >= 8 vCPUs / 16 GB RAM / 100 GB disk)
or MicroShift (>= 2 vCPUs / 2 GB RAM / 10 GB disk). When both are supported it
shows an interactive menu; otherwise it falls back to MicroShift or exits with
the missing prerequisites. Use `--tier sno|microshift` to skip the menu,
`--yes` for non-interactive runs, and `--dry-run` to preview.

`aap-demo create` also prompts for the tier directly when the preset is not
already pinned: it prints whether the hardware supports SNO or only MicroShift
and asks for a y/n confirmation. For hands-free runs, pass `--sno` or
`--microshift` to choose the tier and skip the prompt (`--sno` fails fast with
the unmet requirements when the host is too small):

```bash
aap-demo create --full-demo --satellite --sno        # hands-free SNO
aap-demo create --full-demo --satellite --microshift # hands-free MicroShift
```

### Automatic boot recovery

On Linux with CRC/libvirt, `aap-demo create --full-demo` automatically installs
a system service that resumes the latest CRC disks, settings, credentials and
demo configuration in place at boot. It starts AAP, enabled addons/Fleet and the
dashboard HTTP server before login; the browser opens at graphical login.
There is no manual checkpoint step before reboot and no automatic rollback to an
older backup. Recovery installation failures fail the full-demo command.

```bash
aap-demo service install             # Retain only the latest completed state
aap-demo service install --force-stop --stop-timeout 120  # Linux: opt in to crash-consistent CRC fallback
aap-demo service retention 3         # Optionally keep three states instead
aap-demo restart                     # Save and restart the latest persistent demo
```

This uses full cold backups of CRC/Fleet disks, configuration and required
keys/credentials. It briefly stops the demo for each backup and requires host
disk space. While enabled, `start`, `restart` and `stop` route through systemd.
Starting uses the live persistent state and brings the demo fully online; it does
not overwrite newer state with a checkpoint. Install it separately with
`aap-demo service install` for an existing demo. Windows currently has only
login-time checkpoint recovery, not pre-login full-demo parity.
See [shutdown backups and boot recovery](docs/state-service.md)
for retention, security, recovery and disabling instructions.

## Guides

| I want to… | Read this |
| --- | --- |
| Install or update the command | [Install](docs/guides/install.md) |
| Put a cluster and AAP on this computer | [First deploy](docs/guides/first-deploy.md) |
| Choose AAP 2.6 or 2.7 | [Choose a version](docs/guides/choose-a-version.md) |
| Apply a subscription to AAP | [Subscription](docs/guides/subscription.md) |
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
- [Full README](docs/FULL-README.md) — complete documentation, architecture, and troubleshooting
- [Changelog](docs/CHANGELOG.md) — successful changes since the original 1.0.48 baseline
- [Roadmap](docs/ROADMAP.md) — prioritized project evolution and measurable milestones
- [Design decisions](docs/adr/README.md)
- [Contributing](CONTRIBUTING.md)
