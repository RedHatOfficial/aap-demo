# aap-demo

Local cluster infrastructure for AAP 2.7 deployment, powered by OpenShift Local.
Deploy AAP in minutes on macOS, Linux, or Windows.

## Quick Start

### Prerequisites

#### System Requirements

A typical Microshift and AAP 2.7 environment requires 16GB of RAM, 2 cores, and
100 GB of storage. We recommend having a total of 32GB RAM available on your system.

#### MacOS

- [Homebrew](https://brew.sh/) — Install with: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- [Operator SDK](https://sdk.operatorframework.io/docs/installation/) — Install with: `brew install operator-sdk`

#### Windows

- Windows 11 Pro, Enterprise, or Server (Hyper-V is not available on Windows 11 Home)
- [OpenShift Local](https://console.redhat.com/openshift/create/local) — includes `crc`; Hyper-V must be enabled
- [Git for Windows](https://git-scm.com/download/win) — optional for `create`/`deploy`/`status`;
  required for `diagnose`, `test`, `watch`, and other advanced commands

  ```powershell
  winget install --id Git.Git -e --source winget
  ```

- PowerShell 5.1 or later (included with Windows 10/11)

#### OpenShift Local

- OpenShift Local — [Install](https://console.redhat.com/openshift/create/local)
- On Linux: also install `libvirt-daemon`, `libvirt-daemon-driver-storage`, `libvirt-daemon-driver-network`, `qemu-kvm`
- On Windows: Hyper-V enabled (OpenShift Local requirement)
- Obtain a **Pull Secret** from the [Red Hat Console](https://console.redhat.com/openshift/install/pull-secret)

### macOS / Linux

#### Download your pull secret from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret) and save it

```bash
mkdir -p ~/.aap-demo
cp ~/Downloads/pull-secret.txt ~/.aap-demo/pull-secret.txt
```

#### Install

```bash
git clone https://github.com/RedHatOfficial/aap-demo.git
cd aap-demo && ./install.sh
```

#### Deploy

```bash
aap-demo deploy        # Deploy AAP 2.7
aap-demo status        # Check deployment status
```

### Windows

See the **[Windows installer guide](powershell/README.md)** for full install and usage
instructions. Summary:

#### Save your pull secret

Download from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret) and save as:

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.aap-demo"
Copy-Item "$env:USERPROFILE\Downloads\pull-secret.txt" "$env:USERPROFILE\.aap-demo\pull-secret.txt"
```

#### Install

```powershell
git clone https://github.com/RedHatOfficial/aap-demo.git
cd aap-demo
.\powershell\install.ps1
```

This registers the repo path, installs the `aap-demo` launcher to
`%USERPROFILE%\.local\bin`, adds that directory to your user PATH, and downloads
`operator-sdk` if needed.

Open a **new** PowerShell window after install so PATH changes take effect.

#### Deploy

```powershell
aap-demo create        # Create the cluster
aap-demo deploy        # Deploy AAP 2.7
aap-demo status        # Check deployment status
```

#### Uninstall

```powershell
.\powershell\install.ps1 -Uninstall
```

This removes the wrapper and PATH entry. It does not delete `%USERPROFILE%\.crc\` or
other cluster data.

#### Windows notes

- Kubeconfig default: `%USERPROFILE%\.crc\machines\crc\kubeconfig`
- Config file: `%USERPROFILE%\.aap-demo\config`
- If `aap-demo` is not recognized, confirm `%USERPROFILE%\.local\bin` is on PATH and
  restart PowerShell
- `create`, `deploy`, and `status` are PowerShell-native; install Git for Windows for
  other commands (`diagnose`, `test`, `watch`, …)
- See [powershell/README.md](powershell/README.md) for full Windows install and usage

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

**Requirements:** AAP deployed, Helm 3.10+, `registry.redhat.io` credentials for OCI plugins.

**Profiles:** x86 clusters use Red Hat RHDH chart images; arm64 clusters (e.g. CRC on Apple
Silicon) use community multi-arch RHDH overrides. See
[ADR-002](docs/adr/002-portal-helm-deployment.md) and [addons/portal/README.md](addons/portal/README.md).

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

- **Red Hat Certified Collections**: Offline token from console.redhat.com in `~/.aap-demo/galaxy-token`
- **Private Automation Hub**: Configure URL and credentials in `~/.aap-demo/pah-config.yml`
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
CRC_MEMORY=16384             # VM memory in MiB (default: 16384)
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
