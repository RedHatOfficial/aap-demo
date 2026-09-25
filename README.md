# AAP Demo Quick Start

Deploy AAP to a local MicroShift cluster in minutes.

## SECURITY NOTICE — DEVELOPMENT ENVIRONMENT ONLY

**aap-demo is a LOCAL DEVELOPMENT tool and must NEVER be used in production.**

## Prerequisites

- **CRC (OpenShift Local)** — [Download](https://console.redhat.com/openshift/create/local)
- **16 GB RAM minimum** — default VM allocation is 16 GB (override with
  `CRC_MEMORY=24576 aap-demo create` for 24 GB). On Linux, `aap-demo create`
  prompts for optional temp swap on memory-constrained hosts (see
  [scripts/README.md](scripts/README.md))
- **Pull secret** — download from the
  [Red Hat console](https://console.redhat.com/openshift/install/pull-secret),
  then run:

```bash
mkdir -p ~/.aap-demo
cp ~/Downloads/pull-secret.txt ~/.aap-demo/pull-secret.txt
```

## Install

```bash
git clone https://github.com/RedHatOfficial/aap-demo.git && cd aap-demo && ./install.sh && aap-demo deploy
```

`aap-demo create` provisions the MicroShift VM only. `aap-demo deploy` installs OLM and AAP
(use `deploy` for the typical path; `create` alone is for cluster-only setup).

Cluster credentials live at `~/.aap-demo/kubeconfig.microshift` and are **not** merged into
`~/.kube/config`. If you relied on the old default kubeconfig behavior, run:

```bash
export KUBECONFIG=~/.aap-demo/kubeconfig.microshift
# or: aap-demo kubeconfig   # refresh file and print export command
```

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
  apme-eap        disabled
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
aap-demo enable apme-eap     # Early Access Program only for APME
aap-demo enable local-cache  # Caches AAP containers locally so you don't re-download after destroy/create

# Ansible Product Demos - Official demo content from ansible/product-demos
aap-demo enable product-demos        # Five domains at once (includes base; Satellite opt-in)
aap-demo enable product-demo-satellite  # Satellite demos (requires a Satellite server)
aap-demo disable addon_name  # Disables addon
```

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
./install.sh --uninstall  # Remove aap-demo CLI
```

## Documentation

- **[Full README](docs/FULL-README.md)** — Complete documentation, architecture, troubleshooting
- **[Architecture Decision Records](docs/adr/)** — Design decisions and rationale
- **[Contributing](docs/CONTRIBUTING.md)** — Development guidelines
- **[Linting](docs/LINTING.md)** — Ansible linting setup

### Versioning

Every PR to `main` that changes files (other than `VERSION` itself) must set the semver in
[`VERSION`](VERSION) to exactly one patch above the base branch. CI enforces this via
[`.github/workflows/version-check.yaml`](.github/workflows/version-check.yaml). The pre-commit
hook and pull-request CI automatically set and stage `VERSION` when they detect a required
bump. CI commits the generated bump back to same-repository PR branches.

```bash
aap-demo version              # show current version + git build info
cz bump --increment PATCH     # after ./scripts/setup-linting.sh (optional)
```
