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

After `aap-demo destroy`, reload cached images with:

```bash
aap-demo enable local-cache load   # one-shot reload into fresh VM
aap-demo enable local-cache        # restore auto-load on future deploys
```

## Fleet — Local Managed Nodes

Fleet spins up lightweight QEMU virtual machines on your host as managed nodes for AAP.
Each VM runs a RHEL/CentOS cloud image with an `ansible` user and SSH key pre-injected,
so AAP can run automation against real hosts without any external infrastructure.

### Requirements

- **QEMU** — `brew install qemu` (macOS) or `dnf install qemu-kvm` (Linux)
- **mkisofs** — `brew install cdrtools` (macOS) or `dnf install genisoimage` (Linux)
- **A RHEL/CentOS QCOW2 cloud image** matching your host architecture (aarch64 for Apple Silicon, x86_64 for Intel/AMD)
- **macOS firewall** must allow QEMU connections (System Settings → Network → Firewall → allow `qemu-system-*`)

### Resource Usage

Each fleet node uses **1 GB RAM** and **2 vCPUs** by default (configurable via
`FLEET_NODE_MEM` and `FLEET_NODE_CPUS`). Disk usage is minimal — the base QCOW2
image is copied once (~700 MB–2 GB depending on the image), and each node gets a
thin copy-on-write overlay (~200 KB initially, grows as the VM writes data).

With the default CRC VM (16 GB RAM), 2–3 fleet nodes is a comfortable fit. Larger
fleets may require increasing host memory or reducing node sizes.

### Usage

```bash
# Deploy AAP with fleet nodes in one command
aap-demo deploy --fleet 3 --image ~/rhel9.qcow2

# Or add nodes to an existing AAP deployment
aap-demo fleet add 2 --image ~/rhel9.qcow2
aap-demo fleet list
aap-demo fleet remove 1
aap-demo fleet destroy
```

The `--image` path is saved to `~/.aap-demo/config`, so subsequent `fleet add`
commands don't need it again.

### What Happens on Deploy

1. The base QCOW2 image is copied to `~/.aap-demo/fleet/base.qcow2`
2. Each node gets a thin overlay disk and a cloud-init ISO (creates the `ansible` user with an auto-generated SSH key)
3. QEMU launches each VM with a host port forward for SSH (ports 2200, 2201, …)
4. Nodes are registered in AAP as an inventory called **"Fleet"** with a credential called **"Fleet SSH Key"**
5. An ad-hoc ping verifies end-to-end connectivity

### Using Fleet Nodes in AAP

Fleet nodes appear in the **Fleet** inventory in the AAP UI. To run automation
against them, create a Job Template and assign:

- **Inventory:** Fleet
- **Credential:** Fleet SSH Key

The "Fleet SSH Key" credential is created automatically during registration with
the generated SSH private key. You must select it on any Job Template that targets
fleet nodes — it is not applied by default.

### Lifecycle

Fleet nodes are **ephemeral** — `aap-demo stop` kills all VMs, and `aap-demo destroy`
removes them entirely. After a stop/start cycle, re-create nodes with `aap-demo fleet add`.
This is by design: no VM state to corrupt, and fresh nodes spin up in seconds.

### Fleet Environment Variables

```bash
FLEET_NODE_MEM=1024      # VM memory in MB (default: 1024)
FLEET_NODE_CPUS=2        # VM CPU count (default: 2)
FLEET_IMAGE=~/rhel9.qcow2  # Default QCOW2 image path
```

### Common Commands

```bash
aap-demo start         # Start the cluster (after stop or reboot)
aap-demo stop          # Stop gracefully
aap-demo idle true     # Scale down AAP to save resources
aap-demo idle false    # Scale back up
aap-demo ssh           # SSH into the cluster node
aap-demo status        # Check everything
aap-demo repair        # Fix after sleep/wake issues
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
