# AAP Demo Quick Start

Deploy AAP to a local MicroShift cluster in minutes.

## SECURITY NOTICE — DEVELOPMENT ENVIRONMENT ONLY

**aap-demo is a LOCAL DEVELOPMENT tool and must NEVER be used in production.**

## Install

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

Download a pull secret from the
[Red Hat console](https://console.redhat.com/openshift/install/pull-secret).
The CLI stores it at `~/.local/state/aap-demo/pull-secret.txt`. Cluster
credentials live at `~/.local/state/aap-demo/kubeconfig.microshift`. Those
files are **not** merged into `~/.kube/config`.

```bash
mkdir -p ~/.local/state/aap-demo
cp ~/Downloads/pull-secret.txt ~/.local/state/aap-demo/pull-secret.txt
export KUBECONFIG=~/.local/state/aap-demo/kubeconfig.microshift
# or: aap-demo kubeconfig   # refresh file and print export command
```

`aap-demo create` provisions the MicroShift VM only. `aap-demo deploy` installs OLM and AAP
(use `deploy` for the typical path; `create` alone is for cluster-only setup).

## Prerequisites

- **CRC (OpenShift Local)** — [Download](https://console.redhat.com/openshift/create/local)
- **16 GB RAM minimum** — default VM allocation is 16 GB (override with
  `CRC_MEMORY=24576 aap-demo create` for 24 GB). On Linux, `aap-demo create`
  prompts for optional temp swap on memory-constrained hosts (see
  [scripts/README.md](scripts/README.md))

## Status

```bash
aap-demo version       # Tool version, commit, and build timestamp
aap-demo status        # Show routes and credentials
```

```text
AAP Demo Status
===============

Infra:       OpenShift Local (CRC)
Cluster:     running (crc-microshift)

Namespaces:
-----------
  aap-operator         27/29 pods   aap

AAP Deployments:
----------------
  https://aap-aap-operator.apps.127.0.0.1.nip.io

Credentials:
------------
  aap-operator: admin / <password>

Addons:
-------
  mcp-server      disabled
  portal          disabled
  portal-operator disabled (AMD64 only)
  setup-pah       disabled
  ao            disabled
  local-cache     disabled
  product-demos       disabled
  product-demo-satellite  disabled
```

## Addons to add additional functionality

```bash
aap-demo enable              # List all addons
aap-demo enable portal       # Installs Automation Portal
aap-demo enable portal-operator # Installs Operator-based Portal (Technology Preview; AMD64 only)
aap-demo enable setup-pah     # Configures Private Automation Hub Credentials
aap-demo enable mcp-server   # MCP server for AI assistants
aap-demo enable ao           # Automation Orchestrator (GA; no aapctl required — see addons/ao/README.md)
aap-demo enable local-cache  # Caches AAP containers locally so you don't re-download after destroy/create

# Ansible Product Demos - Official demo content from ansible/product-demos
aap-demo enable product-demos        # Five domains at once (includes base; Satellite opt-in)
aap-demo enable product-demo-satellite  # Satellite demos (requires a Satellite server)
aap-demo disable addon_name  # Disables addon
```

The Windows wrapper currently defers Fleet and local image caching; those
addons remain available through the Linux/macOS Bash workflow.

When destroying a running cluster, `aap-demo destroy` asks whether to save the
container images locally. Confirming lets the next `aap-demo deploy` reuse the
cached containers instead of downloading them again. Existing cached images are
loaded automatically at the start of the next deploy.

Normal destroy/recreate flow:

```bash
aap-demo destroy   # answer y at the cache prompt
aap-demo create
aap-demo deploy     # automatically loads the saved cache
```

You do not need to run `aap-demo enable local-cache load` for this normal flow.

To manage the cache manually:

```bash
aap-demo enable local-cache load   # one-shot reload into fresh VM
aap-demo enable local-cache        # restore auto-load on future deploys
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
aap-demo repair              # Fix after sleep/wake issues

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
aap-demo diagnose      # Quick health check — finds common issues
aap-demo diagnose --ai # AI-powered analysis (requires claude CLI)
aap-demo must-gather   # Collect full diagnostics for support
```

On MicroShift 4.22+, `aap-demo deploy` relaxes container signature verification for
`registry.redhat.io` inside the CRC VM so operator index images can pull. This is a
**demo-only** workaround and must not be used as a production pattern.

## Clean Up

```bash
aap-demo clean         # Remove AAP (keep cluster)
aap-demo destroy       # Delete everything
pipx uninstall aap-demo   # Remove the CLI
```

## Documentation

- **[Full README](docs/FULL-README.md)** — Complete documentation, architecture, troubleshooting
- **[Architecture Decision Records](docs/adr/)** — Design decisions and rationale
- **[Contributing](docs/CONTRIBUTING.md)** — Development guidelines
- **[Linting](docs/LINTING.md)** — Ansible linting setup

### Versioning

Feature PRs do not need to change [`VERSION`](VERSION). Update it deliberately when preparing
a release; CI only verifies that the checked-in value is valid semver. Development builds are
also identified by the commit SHA and build timestamp shown by `aap-demo version`.

```bash
aap-demo version              # show current version + git build info
cz bump --increment PATCH     # after ./scripts/setup-linting.sh (optional)
```
