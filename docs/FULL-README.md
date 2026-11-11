# aap-demo

Local cluster infrastructure for AAP 2.7 deployment, powered by OpenShift Local.
Deploy AAP in minutes on macOS, Linux, or Windows.

## Portability and idempotency

Lifecycle and addon commands are convergence operations: rerunning a successful
create, deploy, enable, start, wire, or full-demo command reuses or updates
managed resources rather than intentionally creating duplicates. Kubernetes
namespaces and managed secrets use apply-style updates, while persistent config
keys are replaced in place.

Bash state defaults to `~/.aap-demo` and its config defaults to
`~/.aap-demo/config`. Override these with `AAP_DEMO_DIR` and
`AAP_DEMO_CONFIG`; child addon processes inherit both. `NAMESPACE`,
`KUBECONFIG`, and `AAP_DEMO_KUBECONFIG` select non-default cluster targets.
`QUIET=true` is the noninteractive contract and fails with guidance if required
credentials or choices are unavailable.

Linux and macOS use Bash. Native Windows uses PowerShell, and WSL uses the
Windows-hosted wrapper. Addons select `amd64`/`x86_64` or `arm64`/`aarch64`
artifacts only where both are supported and fail explicitly otherwise. CRC
keeps its upstream-owned files in `~/.crc`. Linux systemd recovery intentionally
requires default state paths; custom paths are supported by ordinary CLI/addon
operations. A failed or interrupted remote API operation is not treated as
success and can be safely retried after connectivity is restored.

## Quick Start

### Prerequisites

#### System Requirements

A typical MicroShift and AAP 2.7 environment requires 16GB of RAM, 2 cores, and
100 GB of storage. We recommend having a total of 32GB RAM available on your system.
The 16GB default (`CRC_MEMORY=16384`) runs AAP alone; `create --full-demo`
raises the VM to 32GB automatically because AAP + AO + Ollama + Fleet + product
demos do not fit in 16GB (AO's UI pod is OOM-starved at 99% memory requests).
Override with `CRC_MEMORY=<MiB>`.

#### MacOS

- [Homebrew](https://brew.sh/) — Install with: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- [Operator SDK](https://sdk.operatorframework.io/docs/installation/) — Install with: `brew install operator-sdk`

#### Core Python tools (manual Linux/macOS setup)

Use a Python 3.11 virtual environment (the tested setup and CI baseline) from the
repository root to avoid changing system-managed packages:

```bash
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
python -m pip check
```

The root [requirements.txt](../requirements.txt) provides `ansible-core`,
`PyYAML`, and the Kubernetes Python client. Ansible collections remain in
[requirements.yml](../requirements.yml); version ranges are not a lockfile.
Activate the environment in each CLI shell; `deactivate` restores the prior
shell environment. `.venv` is ignored by Git. System tools still require the
platform-specific prerequisites above/below.
Other Python versions require compatible Ansible releases: pip resolution alone
does not guarantee CLI compatibility. Stable `ansible-core` 2.21.5 failed its CLI
startup check on this host's Python 3.15; use the tested interpreter instead.

APME continues to manage its own environment using its addon-specific manifests;
dashboard npm dependencies and system-installed RHC/Insights tools are separate.
See the [manual Python setup](../README.md#python-dependencies-manual-virtual-environment-setup).

#### Windows

- Windows 11 Pro, Enterprise, or Server (Hyper-V is not available on Windows 11 Home)
- [OpenShift Local](https://console.redhat.com/openshift/create/local) — includes `crc`; Hyper-V must be enabled
- [Git for Windows](https://git-scm.com/download/win) — required by the PowerShell wrapper
  for deploys and addon commands

  ```powershell
  winget install --id Git.Git -e --source winget
  ```

- PowerShell 5.1 or later (included with Windows 10/11)
- `jq` — used by the Bash deployment and addon wiring paths
- Python 3.12 — used to provision AAP demos and import AO demo workflows

The Windows deploy and AO/Product Demo preflight installs `jq` and Python with
winget when they are missing:

```powershell
winget install --id jqlang.jq -e --source winget
winget install --id Python.Python.3.12 -e --source winget
```

#### OpenShift Local

- OpenShift Local — [Install](https://console.redhat.com/openshift/create/local)
- On Linux: also install `libvirt-daemon`, `libvirt-daemon-driver-storage`, `libvirt-daemon-driver-network`, `qemu-kvm`
- On Windows: Hyper-V enabled (OpenShift Local requirement)
- Obtain a **Pull Secret** from the [Red Hat Console](https://console.redhat.com/openshift/install/pull-secret)

#### Host prep for memory-constrained systems (Linux)

CRC defaults to 16–24 GB of VM RAM. On a 32 GB workstation, image pulls and operator
reconciliation can exhaust host memory.

During interactive `aap-demo create` on **Linux**, you are prompted for temporary swap
before CPU, memory, and disk allocation (default yes on hosts with 36 GB RAM or less). The
script creates a `swapon` file at `/swapfile-aap-demo` by default and handles btrfs
(Fedora), xfs/ext4 (RHEL), and SELinux `swapfile_t`.

```text
Resource allocation for CRC VM:
  Host: 16 CPUs, 30GB RAM (8GB swap)

  Create temp swap for deploy? [Y/n]:
  Temp swap size in GB [16]:
  CPUs [8]:
  Memory in GB [16]:
  Disk in GB [120]:
  Persistent volume storage in GB [70]:
```

Host prep for pull secret, libvirt, and CRC setup:

```bash
./scripts/local-prereq.sh
./scripts/local-prereq.sh --deploy  # prepare and deploy from this checkout
```

Manual swap management (non-interactive or after deploy):

```bash
./scripts/enable-temp-swap.sh                              # 16 GB temp swap file
AAP_ENABLE_TEMP_SWAP=true AAP_SWAP_SIZE_GB=24 aap-demo create   # scripted create
./scripts/enable-temp-swap.sh disable                      # remove after deploy
```

Swap files are not added to `/etc/fstab`. Remove after deploy with
`./scripts/enable-temp-swap.sh disable` or `aap-demo destroy`.
See [scripts/README.md](../scripts/README.md) for Linux-only details.

### Install

Python 3.9 or newer. [pipx](https://pipx.pypa.io/) keeps the command isolated from the rest of your Python packages:

```bash
pipx install aap-demo
```

Update the installed command with:

```bash
aap-demo update
```

That checks how this command was installed, then runs `pipx upgrade aap-demo`.

pip and uv install the same release:

```bash
pip install aap-demo
uv tool install aap-demo
```

This installs the published release candidate from v2. Check out `v2` only if you are changing the code.
If you already installed from the git URL, switch with `pipx install --force aap-demo`.

`./install.sh` links `~/.local/bin/aap-demo` to the bash script. pipx installs v2 at that same path,
so move or remove the old command before installing v2.

```bash
mv ~/.local/bin/aap-demo ~/.local/bin/aap-demo-v1
```

Or remove it without deleting cluster data:

```bash
rm -f ~/.local/bin/aap-demo \
  ~/.zsh/completions/_aap-demo \
  ~/.local/share/bash-completion/completions/aap-demo
```

If a bash `aap-demo` is still earlier on `PATH`, the first v2 command asks whether to uninstall it or rename it to `aap-demo-v1`.

#### Save your pull secret

Download from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret).
The CLI reads `~/.local/state/aap-demo/pull-secret.txt`. Cluster credentials
live at `~/.local/state/aap-demo/kubeconfig.microshift` and are not merged
into `~/.kube/config`.

```bash
mkdir -p ~/.local/state/aap-demo
cp ~/Downloads/pull-secret.txt ~/.local/state/aap-demo/pull-secret.txt
export KUBECONFIG=~/.local/state/aap-demo/kubeconfig.microshift
```

On Windows the same paths are under your user profile:

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.local\state\aap-demo"
Copy-Item "$env:USERPROFILE\Downloads\pull-secret.txt" "$env:USERPROFILE\.local\state\aap-demo\pull-secret.txt"
```

With the older bash command, the next create/deploy imports this file into encrypted
`~/.ansible/conf/env.yml` and removes the managed plaintext copy. Delete the
original download after successful import. When the pull secret is missing but
the encrypted Vault contains a valid Customer Portal offline token,
`aap-demo create` exchanges that token for short-lived access and retrieves a
fresh pull secret from Red Hat's official API without writing plaintext to disk.
This implements the REST automation documented in Red Hat Solution
[4844461](https://access.redhat.com/solutions/4844461); direct username/password
grants are intentionally not used.

#### Deploy

```bash
aap-demo deploy        # Deploy AAP 2.7
aap-demo status        # Check deployment status
```

Config lives at `~/.config/aap-demo/config.yaml`. Credentials such as the
Galaxy token go in the OS keyring (`aap-demo config secrets set galaxy-token`),
not in a file under your home directory.

Once deployed, `aap-demo status` shows routes and cluster health without
printing credentials. Use `aap-demo status --show-secrets` in an interactive
terminal when credentials must be revealed:

On the Bash CLI, this output also includes `crc_ip`, the detected SSH identity
file in a direct SSH command, and `aap-demo ssh`. Generated `system-info`
reports include the same CRC access information alongside the credentials;
JSON reports expose `cluster.crc_ip` and `cluster.ssh`. CRC's IP can be internal
to user-mode networking, so use `aap-demo ssh` or the forwarded
`core@127.0.0.1` endpoint on port 2222 from the host. SSH private key contents
are never printed or included in the report.

```text
Infra:       crc
Cluster:     running

Namespaces:
-----------
  aap-operator         27/27 pods   aap  https://aap-aap-operator.apps.127.0.0.1.nip.io
  olm                  4/4 pods

Credentials: hidden (run 'aap-demo status --show-secrets' in a terminal to reveal)

Enabled Addons:
---------------
  mcp-server      https://aap-mcp-aap-operator.apps.127.0.0.1.nip.io/mcp
```

On the OpenShift preset (`CRC_PRESET=openshift`), routes use
`*.apps-crc.testing` and the full OpenShift web console is available via
`aap-demo console`.

### Self-Service Portal (AAP 2.7)

Deploy the Ansible Automation Portal (Red Hat Developer Hub + AAP plugins) as a Helm addon:

```bash
aap-demo enable portal       # Auto-detects cluster CPU (amd64 vs arm64)
aap-demo disable portal
aap-demo status portal       # Portal route URL
```

**Requirements:** AAP deployed and `registry.redhat.io` credentials for OCI plugins.
Helm 3.10+ is installed automatically if missing.

**Profiles:** x86 clusters use Red Hat RHDH chart images; arm64 clusters (e.g. CRC on Apple
Silicon) use community multi-arch RHDH overrides. See
[ADR-002](adr/002-portal-helm-deployment.md) and [addons/portal/README.md](../addons/portal/README.md).

## Overview

aap-demo deploys Ansible Automation Platform 2.7 to OpenShift Local (MicroShift) for development, testing, and demonstration.

**Key characteristics:**

- One command setup: `aap-demo deploy`
- Full OpenShift API compatibility (OLM, Routes, CRDs)
- Shared Podman/CRI-O storage — locally built images are immediately available to pods
- In-cluster registry at `registry.apps.127.0.0.1.nip.io`
- Valid TLS certificates (auto-trusted on macOS/Linux)
- Addon system: `aap-demo enable mcp-server`
- Reproducible — destroy and recreate in minutes

## Collection Authentication

aap-demo automatically configures Ansible Galaxy authentication for downloading certified and private collections:

- **Red Hat Certified Collections**: offline token from console.redhat.com, stored with `aap-demo config secrets set galaxy-token`
- **Private Automation Hub**: `aap-demo config secrets set pah-token`
- **Priority-based fallback**: PAH → console.redhat.com → galaxy.ansible.com (community)

Collections are installed automatically during deployment from `config/requirements.yml`. Skip with `SKIP_COLLECTIONS=true`.

**Status**: View configured sources with `aap-demo status`
**Diagnostics**: Validate authentication with `aap-demo diagnose`
**Documentation**: See [docs/collection-authentication.md](docs/collection-authentication.md)

## Deploy MCP Server

```bash
aap-demo enable mcp-server     # MCP server for AI assistants
aap-demo disable mcp-server
```

## Ansible Lightspeed (local LLM)

The `lightspeed` addon deploys the Ansible Lightspeed intelligent assistant
into AAP, backed by the local Ollama LLM (`qwen2.5:3b`) instead of a cloud
model. It requires the `ollama` addon:

```bash
aap-demo enable ollama       # provides the model endpoint
aap-demo enable lightspeed   # deploy Lightspeed wired to Ollama
```

Access the assistant from the AAP console → Lightspeed intelligent assistant.
See [addons/lightspeed/README.md](../addons/lightspeed/README.md) for
configuration and the SNO postgres note.

## Satellite Lab

The `satellite-lab/` folder builds a Satellite 6 demo lab (Satellite VM +
PXE-provisioned fleet) on the same KVM host. The `satellite-manifest` addon
creates and downloads the required subscription manifest programmatically via
the RHSM API, so no manual portal download is needed:

```bash
aap-demo enable satellite-manifest   # writes ~/.aap-demo/satellite/manifest.zip
```

The addon reuses the credential Vault's Red Hat offline token. The account must
hold the **"View/Renew Subscription Information"** permission
(console.redhat.com → Settings → User Access); without it the RHSM allocations
API returns 401 and the addon stops with guidance. See
[satellite-lab/README.md](../satellite-lab/README.md) for the full lab run order
(network setup → VM provision → installer → content → provisioning → bootc →
integrations → AAP inventory).

**Full demo integration:** `aap-demo create --full-demo --satellite` builds and
configures the Satellite lab automatically when the Satellite VM does not yet
exist (via `satellite-lab/build-and-configure.sh`), then installs the Satellite
Demo content (`product-demo-satellite`) against it. The RHEL 9.x DVD ISO is
downloaded automatically from the Red Hat CDN using the host's RHSM entitlement
cert (`satellite-lab/00a-fetch-rhel-iso.sh`) — no portal login. The Satellite VM
uses a minimal 40 GB OS disk with `/var/lib/pulp` mounted from the host over NFS
(`satellite-lab/00b-host-nfs-storage.sh` sets up the export, firewalld, and
SELinux booleans), a VNC graphical console viewable in virt-manager, and a
hashed root password with the invoking user's SSH key injected for access. The
Satellite appears in the dashboard Routes list (pending during the build,
admitted once it serves HTTPS) and as an external `satellite-lab` entry in
Namespaces. The build also trusts the Satellite's Katello CA on the host
(system ca-trust plus the Chrome/Firefox NSS stores) so the UI and CLI tools
stop warning about the self-signed certificate, and surfaces the Satellite
admin credentials in interactive `aap-demo status --show-secrets`.

**Fleet registration:** with the lab built, `aap-demo fleet satellite-register`
registers running Fleet nodes to the Satellite (content from the local Pulp,
hosts in the Satellite inventory). See
[satellite-lab/README.md](../satellite-lab/README.md#registering-fleet-nodes).

### Common Commands

```bash
# Deployment
aap-demo deploy              # Deploy AAP 2.7
aap-demo create --full-demo  # Create AAP + Ollama/AO + three RHEL 9 Fleet nodes + dashboard

# Cluster management
aap-demo status              # Show cluster status and routes without secrets
aap-demo status --show-secrets # Reveal credentials interactively
aap-demo stop                # Stop the cluster
aap-demo start               # Start the cluster
aap-demo ssh                 # SSH into the cluster node
aap-demo watch               # Monitor deployment progress
aap-demo destroy             # Delete entire cluster

# AAP Operator Idle
aap-demo idle true           # Scale down AAP to save resources
aap-demo idle false          # Scale back up
aap-demo idle                # Check current idle state

# Troubleshooting
aap-demo diagnose            # Quick health check (cluster, storage, SCCs, pods)
aap-demo must-gather         # Collect full diagnostics (AAP + cluster)
aap-demo must-gather /tmp/d  # Collect to specific directory

# Maintenance
aap-demo maintenance         # Preview reclaimable VM runtime data
aap-demo maintenance --apply # Remove exited containers, unused images, and old caches/logs
aap-demo maintenance uninstall         # Preview complete environment removal
aap-demo maintenance uninstall --apply # Remove VMs, caches, trust, CLI, and residual state
                                       # (keeps the credential Vault for rebuilds)
aap-demo maintenance uninstall --apply --reconfigure
                                       # Also strip the aap_demo entries from the shared Vault
aap-demo clean               # Remove AAP deployment (keeps cluster)
aap-demo update              # Update the pipx install to the latest release
aap-demo help                # Full command reference
```

`aap-demo create --full-demo` is a fail-fast demo bootstrap.
It creates a cluster sized for the included addons, deploys AAP 2.7, configures
Automation Hub, enables the offline-token keepalive, enables Ollama and
Automation Orchestrator, then enables Fleet, attaches the AAP subscription, and
reconciles three started and registered RHEL 9 nodes. Product Demos is installed
after licensing succeeds. A final strict `aap-demo wire` runs after all
components are present, then the dashboard launches. Fleet image download
and AAP subscription attachment require Red Hat credentials. Full-demo checks
them first and starts the secure `fleet auth` prompts when they are missing or
invalid. Runs with `QUIET=true` remain noninteractive and require credentials to
be configured in advance. If the Automation Hub token is not configured,
setup-pah prompts for that distinct token. Customer Portal and Automation Hub
tokens remain separate in encrypted storage. Reruns reuse existing Fleet nodes
instead of creating duplicates. Use `--no-open` to run the dashboard without
opening a browser.

`aap-demo dashboard` now starts in the background and returns after its localhost
listener is ready. Repeating it reuses this checkout's running dashboard.
Logs are written to `~/.aap-demo/dashboard.log` (or `$AAP_DEMO_DIR/dashboard.log`).
The Environment Overview shows the host OS, CRC guest OS when available, and
the AAP subscription selected during automatic licensing. Use the small
**Restart dashboard** button to restart only the dashboard and reconnect the
page; it is blocked during dashboard add-on operations and does not restart
CRC, AAP or Fleet. For foreground debugging, use
`python3 dashboard/server.py --no-open` from the repository root.

`maintenance --apply` keeps running containers, images used by workloads,
namespaces, PVCs, and the optional local image cache. It also vacuums system
journals older than seven days and reports the VM disk space reclaimed.

`maintenance uninstall --apply` requires typing `UNINSTALL` and removes the CRC
cluster, Fleet VMs and images, CRC downloads, generated credentials and caches,
temporary swap, ingress trust entries, MCP/shell integration, CLI symlink, and
completions. It also stops the dashboard, removes recovery services and backups,
and deletes `~/.aap-demo`. The encrypted credential Vault is preserved intact —
including the `aap_demo` entries — so a later `create` does not re-prompt for
pull secrets or tokens. Add `--reconfigure` to strip the `aap_demo` entries from
the Vault so the next `create` starts fresh; even then the shared Vault files
(`~/.ansible/conf/env.yml` and `~/.ansible/conf/.vaultpass.txt`) are never
deleted, because other products and projects use them — only the aap-demo
entries are removed. The source repository, shared command-line tools/packages,
unrelated Vault keys, and libvirt group membership are preserved. For
noninteractive use, also set `AAP_DEMO_UNINSTALL_CONFIRM=UNINSTALL`.

Retained passwords and tokens are stored under the `aap_demo` namespace and
the `ah_offline_token` key in Ansible Vault-encrypted `~/.ansible/conf/env.yml`, using
`~/.ansible/conf/.vaultpass.txt`. Existing unrelated YAML is preserved during
updates and migration. The directory is mode `0700`; both files are mode
`0600`, and the password is generated automatically for a new Vault only.
Existing password contents are never replaced; uninstall preserves the shared
password for other products. Co-locating
the encrypted Vault and password protects against accidental
publication, not compromise of the local user account.

Fleet node access is reconciled by `aap-demo fleet register`, Product Demos
installation (when nodes exist), and `aap-demo wire`. The AAP **Fleet** inventory
in the **Default** organization and **Fleet SSH Key** credential are updated to
use the bootstrap `ansible` account for unattended automation. Interactive admin
sudo requires its Vault-backed password, with the exact rule
`admin     ALL=(ALL)       ALL`. Registration verifies connectivity with an AAP
ad-hoc ping and fails explicitly if verification fails.

Fleet add/start/remove and registration reconcile unique per-node admin Ed25519
keys, public-key exchange, pinned SSH aliases, and managed `/etc/hosts` blocks.
From a Fleet VM, `ssh aap-fleet-node-2` or
`ssh aap-fleet-node-2.fleet.aap-demo.test` uses the proper forwarded port.
Hosts blocks include Fleet, host, cluster machines, and exposed routes, while
preserving unmanaged/localhost/IPv6 entries and Kubernetes DNS. Private keys
are never copied between nodes. The host and cluster are not modified.
Because Fleet uses isolated QEMU networking, its hosts entries share the gateway
IP; this enables named SSH through aliases, not direct IP networking between VMs.
Run `aap-demo fleet register` after route or host-address changes.

Red Hat system enrollment is a separate, explicit opt-in command:
`aap-demo fleet rhc-connect`. It uses Vault-backed CDN credentials to connect
running Fleet VMs to RHSM, Insights reporting, and Remote Host Configuration.
Credentials travel through encrypted SSH stdin and interactive prompts, not
process arguments or logs. Complete connections are reused, partial Insights
registration is completed, and final status must verify all components.
New nodes are not automatically enrolled. This associates machines with the
Red Hat account; it does not identify individual demo users. CRC is deferred:
the OSTree appliance lacks RHC/Insights packages and is left unchanged.
See [manual enrollment](../README.md#red-hat-system-enrollment-manual-opt-in).

Use `aap-demo fleet ssh 1` for key-based SSH, or
`ssh -p 2201 admin@127.0.0.1` for password login to the first node.
`aap-demo status --show-secrets` displays each node's IP, forwarded SSH port,
username, and Vault-backed password only in an interactive terminal. Default
status, JSON inventory, and dashboard status omit passwords.

The dashboard **Application Access / Routes** panel has a browser SSH terminal
link for each node. Install its pinned renderer with `npm ci --prefix dashboard`
after a fresh checkout. SSH authentication remains on the host, never in a URL
or browser response; terminals are localhost-only, same-origin/session-protected,
bounded to four sessions, and expire after five minutes without requests.
See [Fleet inventory and node access](../README.md#fleet-inventory-and-node-access)
for networking and SSH host-key details.

`aap-demo status --show-secrets` reveals available AAP and addon login
passwords only in an interactive terminal; redirected output is rejected. The
Customer Portal token from `https://access.redhat.com/management/api` is stored
as `aap_demo.redhat.offline_token`. The distinct Automation Hub token from
`https://console.redhat.com/ansible/automation-hub/token` is stored as
`ah_offline_token` (the older `aap_demo.galaxy.offline_token` key remains readable).
They are validated and maintained separately.

If Customer Portal authentication fails, run `aap-demo fleet auth configure`
in an interactive terminal and paste the Customer Portal offline token at the
hidden prompt, not into chat or a shell command. `invalid_grant` means SSO
rejected the token; generate a replacement on the Customer Portal API page.
Network failures, server errors, and malformed SSO responses are reported
separately and do not trigger replacement of an existing stored token.

Offline tokens can expire after 30 days without use. The optional keepalive
reads configured Customer Portal and Automation Hub tokens directly from the
encrypted Vault once daily, exchanges them for short-lived access tokens, and
discards the results without logging secrets:

```bash
aap-demo credentials keepalive enable
aap-demo credentials keepalive setup    # Alternative Hub-only four-day cron workflow
aap-demo credentials keepalive status
aap-demo credentials keepalive run
aap-demo credentials keepalive disable
```

Linux uses a persistent systemd user timer so a missed run executes after wake
or boot. macOS uses a LaunchAgent. Invalid tokens can generate desktop
notifications; temporary network failures wait for the next scheduled retry.
The `setup` action securely validates/stores the Hub token and installs an
idempotent `0 0 */4 * *` user cron job. See
[collection authentication](collection-authentication.md) for password-file
configuration, retry behavior, and cron timing details.

## Architecture

Architecture decisions are documented in [docs/adr/](docs/adr/README.md) (14 ADRs covering CLI
design, storage, OLM, addons, and cross-platform support).

### macOS / Linux / Windows

- **Networking:** SSH (2222), API (6443), HTTP/HTTPS (443) — all on localhost
- **Routes:** `*.apps.127.0.0.1.nip.io` (nip.io DNS, no /etc/hosts needed)
- **TLS:** MicroShift's ingress CA auto-trusted on macOS keychain / Linux ca-trust;
  on Windows, run `aap-demo deploy` from an elevated PowerShell (see
  [powershell/README.md](powershell/README.md#ingress-ca-and-browser-tls))

## Environment Variables

```bash
CRC_CPUS=8                   # VM CPU count (default: 8)
CRC_MEMORY=24576             # VM memory in MiB (default: 24576, use 16384 for AAP-only)
CRC_DISK=120                 # VM disk size in GiB (default: 120, minimum 31; prompted on create)
CRC_PV_SIZE=70               # Persistent-volume pool in GiB (default: 70, minimum 15, must be < CRC_DISK; prompted on create)
NAMESPACE=aap-operator       # Target namespace
QUIET=true                   # Suppress disclaimer
```

## Troubleshooting

```bash
aap-demo diagnose              # Quick health check — identifies common issues
aap-demo must-gather           # Collect full diagnostics for support
aap-demo status                # Check cluster and AAP status
aap-demo ssh                   # SSH into cluster node for debugging
aap-demo repair                # Repair after crash/sleep
aap-demo destroy && aap-demo create && aap-demo deploy   # Full rebuild
```

`aap-demo diagnose` checks cluster connectivity, storage classes, SCCs, namespace
labels, AAP CR status, pod health, PVC binding, and DNS. It provides actionable fix
suggestions for any issues found.

If `oc login` has switched `~/.aap-demo/kubeconfig.microshift` to a remote API,
cluster commands stop with `Kubeconfig points at a remote cluster` instead of
deploying there. Switch back with `kubectl config use-context microshift`, or
refresh the local file with `aap-demo kubeconfig`.

`aap-demo must-gather` collects aap-demo config, CRC status, storage/PVC/pod/event
data, and runs the official [AAP must-gather](https://github.com/ansible/aap-must-gather)
image for operator-level diagnostics.

### AI-Assisted Development

This repository includes a `.claude/CLAUDE.md` file that provides Claude Code with
full aap-demo context. When running Claude Code in the aap-demo directory, it
automatically understands the architecture, common issues, and troubleshooting patterns.

## References

- [MicroShift](https://microshift.io/)
- [OpenShift Local](https://console.redhat.com/openshift/create/local)
- [AAP Documentation](https://access.redhat.com/documentation/en-us/red_hat_ansible_automation_platform/)

## Testing

Test suite validates core aap-demo commands without requiring cluster operations:

```bash
./test/test-core-commands.sh
```

Tests verify:

- `status` - execution and output format
- `start` - CRC startup + CoreDNS reconfiguration (fixes DNS after restarts)
- `stop` - CRC shutdown
- `destroy` - warning messages and cleanup logic
- `create` - script delegation and OLM setup

All tests use grep verification or command mocking to avoid destructive operations.

## Contributing

For questions or contributions, open an issue or pull request on GitHub.
