# AAP Demo Quick Start

Deploy AAP to a local OpenShift Local VM in minutes.

## SECURITY NOTICE — DEVELOPMENT ENVIRONMENT ONLY

**aap-demo is a LOCAL DEVELOPMENT tool and must NEVER be used in production.**

## Prerequisites

- **CRC (OpenShift Local)** — [Download](https://console.redhat.com/openshift/create/local)
- **Pull secret** (download from https://console.redhat.com/openshift/install/pull-secret). Once downloaded run the following command:

```bash
mkdir -p ~/.aap-demo
cp ~/Downloads/pull-secret.txt ~/.aap-demo/pull-secret.txt
```

## Install

```bash
git clone https://github.com/RedHatOfficial/aap-demo.git && cd aap-demo && ./install.sh && aap-demo deploy
```

**NOTE:** You will be prompted for OpenShift or MicroShift on initial install. OpenShift requires substantially more resources than MicroShift so please take that into consideration.

## Status

```bash
aap-demo status        # Show routes and credentials
```

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
## Addons to add additional fuctionality

```bash
aap-demo enable              # List all addons
aap-demo enable portal       # Installs Automation Portal
aap-demo enable pah          # Configures Private Automation Hub Credentials
aap-demo enable mcp-server   # MCP server for AI assistants
aap-demo enable scale-down   # Scales down pods to save resources
aap-demo enable ao-eap       # Early Access Program only for Automation Orchestrator
aap-demo enable apme-eap     # Early Access Program only for APME
aap-demo disable addon_name  # Disables addon
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
