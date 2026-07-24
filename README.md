# AAP Demo Quick Start

Deploy AAP to a local MicroShift cluster in minutes.

## Install

```bash
git clone https://github.com/RedHatOfficial/aap-demo.git
cd aap-demo && ./install.sh
```

## System Requirements

- **RAM**: 16GB minimum (32GB recommended)
- **CPU**: 2 cores minimum (8 vCPU allocated by default)
- **Storage**: 100GB disk space
- **OS**: macOS, Linux, or Windows 11 Pro/Enterprise/Server (Hyper-V required for Windows)

## Prerequisites

- **CRC (OpenShift Local)** — [Download](https://console.redhat.com/openshift/create/local)
- **Pull secret** (required for all deploys):

```bash
mkdir -p ~/.aap-demo
# Download from: https://console.redhat.com/openshift/install/pull-secret
cp ~/Downloads/pull-secret.txt ~/.aap-demo/pull-secret.txt
```

## Deploy

```bash
aap-demo create        # Create cluster (~3 min)
aap-demo deploy        # Deploy AAP 2.7 (~10 min)
aap-demo status        # Show routes and credentials
```

## What You Get

```text
AAP Demo Status
===============

Infra:       crc (MicroShift 4.21.0)
Cluster:     running

Namespaces:
-----------
  aap-operator         27/29 pods   AAP: aap (Successful)

AAP Deployments:
----------------
  https://aap-aap-operator.apps.127.0.0.1.nip.io

Credentials:
------------
  aap-operator: admin / <password>
```

## Daily Use

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

## Addons

```bash
aap-demo enable console      # OpenShift Console (web UI)
aap-demo enable registry     # In-cluster container registry
aap-demo enable mcp-server   # MCP server for AI assistants
aap-demo enable              # List all addons
```

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
