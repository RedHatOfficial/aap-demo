# aap-demo

Local cluster infrastructure for AAP 2.7 deployment, powered by OpenShift Local.
Deploy AAP in minutes on macOS, Linux, or Windows.

## Quick Start

### Prerequisites

#### System Requirements

A typical MicroShift and AAP 2.7 environment requires 24GB of RAM, 2 cores, and
100 GB of storage. We recommend having a total of 32GB RAM available on your system.
The 24GB default supports AAP plus EAP addons (AO, APME); use `CRC_MEMORY=16384` for 16GB if running AAP alone.

#### MacOS

- [Homebrew](https://brew.sh/) — Install with: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- [Operator SDK](https://sdk.operatorframework.io/docs/installation/) — Install with: `brew install operator-sdk`

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
before CPU and memory allocation (default yes on hosts with 36 GB RAM or less). The
script creates a `swapon` file at `/swapfile-aap-demo` by default and handles btrfs
(Fedora), xfs/ext4 (RHEL), and SELinux `swapfile_t`.

```text
Resource allocation for CRC VM:
  Host: 16 CPUs, 30GB RAM (8GB swap)

  Create temp swap for deploy? [Y/n]:
  Temp swap size in GB [16]:
  CPUs [8]:
  Memory in GB [16]:
```

Host prep for pull secret, libvirt, and CRC setup:

```bash
./scripts/local-prereq.sh
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

Python 3.9 or newer. While `v2` is in development, install that branch directly. No checkout is required. [pipx](https://pipx.pypa.io/) keeps the command isolated from the rest of your Python packages:

```bash
pipx install "git+https://github.com/RedHatOfficial/aap-demo.git@v2"
```

Pull the latest `v2` commit the same way:

```bash
pipx install --force "git+https://github.com/RedHatOfficial/aap-demo.git@v2"
```

pip and uv install the same branch:

```bash
pip install "git+https://github.com/RedHatOfficial/aap-demo.git@v2"
uv tool install "git+https://github.com/RedHatOfficial/aap-demo.git@v2"
```

`pipx install aap-demo` replaces the git URL after the package is published. Check out `v2` only if you are changing the code.

`./install.sh` links `~/.local/bin/aap-demo` to the bash script. pipx installs v2 at that same path, so move or remove the old command before installing v2.

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

#### Deploy

```bash
aap-demo deploy        # Deploy AAP 2.7
aap-demo status        # Check deployment status
```

Config lives at `~/.config/aap-demo/config.yaml`. Credentials such as the
Galaxy token go in the OS keyring (`aap-demo config secrets set galaxy-token`),
not in a file under your home directory.

Once deployed, `aap-demo status` shows routes, credentials, and cluster health:

```text
Infra:       crc
Cluster:     running

Namespaces:
-----------
  aap-operator         27/27 pods   aap  https://aap-aap-operator.apps.127.0.0.1.nip.io
  olm                  4/4 pods

Credentials:
------------
  aap-operator:        admin / <password>

Enabled Addons:
---------------
  console         https://console.apps.127.0.0.1.nip.io
  registry        https://registry.apps.127.0.0.1.nip.io
```

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

### Common Commands

```bash
# Deployment
aap-demo deploy              # Deploy AAP 2.7

# Cluster management
aap-demo status              # Show cluster status, routes, credentials
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
aap-demo clean               # Remove AAP deployment (keeps cluster)
aap-demo update              # Pull latest code and reinstall
aap-demo help                # Full command reference
```

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
CRC_DISK=100                 # VM disk size in GiB (default: 100)
CRC_PV_SIZE=70               # Storage reserved for LVMS PVCs in GiB (default: 70, must be < CRC_DISK)
NAMESPACE=aap-operator       # Target namespace
QUIET=true                   # Suppress disclaimer
```

## Troubleshooting

```bash
aap-demo diagnose              # Quick health check — identifies common issues
aap-demo diagnose --ai         # Health check + AI-powered analysis (requires claude CLI)
aap-demo must-gather           # Collect full diagnostics for support
aap-demo status                # Check cluster and AAP status
aap-demo ssh                   # SSH into cluster node for debugging
aap-demo repair                # Repair after crash/sleep
aap-demo destroy && aap-demo create && aap-demo deploy   # Full rebuild
```

`aap-demo diagnose` checks cluster connectivity, storage classes, SCCs, namespace
labels, AAP CR status, pod health, PVC binding, and DNS. It provides actionable fix
suggestions for any issues found.

`aap-demo diagnose --ai` runs the same checks, then sends the results plus pod logs
and events to [Claude](https://claude.ai) for AI-powered root cause analysis and fix
suggestions. Requires the `claude` CLI
([Claude Code](https://docs.anthropic.com/en/docs/claude-code)).

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
