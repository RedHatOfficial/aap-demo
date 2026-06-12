# AAP Demo Quick Start

Deploy AAP to a local MicroShift cluster in minutes.

## Install

```bash
git clone https://github.com/ansible-automation-platform/aap-demo.git
cd aap-demo && ./install.sh
```

## Prerequisites

- **CRC (OpenShift Local)** — [Download](https://console.redhat.com/openshift/create/local)
- **OpenShift client** (`oc`/`kubectl`):

```bash
# macOS ARM
curl -LO https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-mac-arm64.tar.gz
tar -xzf openshift-client-*.tar.gz && sudo cp oc kubectl /usr/local/bin/

# Pull secret (required for all deploys)
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

## More Info

See [README.md](README.md) for full documentation.
