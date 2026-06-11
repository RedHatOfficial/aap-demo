# aap-demo

Local cluster infrastructure for AAP 2.7 deployment, powered by OpenShift Local.
Deploy AAP in minutes on macOS, Linux, or Windows.

## Overview

aap-demo deploys Ansible Automation Platform 2.7 to OpenShift Local (MicroShift) for development, testing, and demonstration.

**Key characteristics:**

- One command setup: `aap-demo create && aap-demo deploy`
- Full OpenShift API compatibility (OLM, Routes, CRDs)
- Shared Podman/CRI-O storage — locally built images are immediately available to pods
- In-cluster registry at `registry.apps.127.0.0.1.nip.io`
- Valid TLS certificates (auto-trusted on macOS/Linux)
- Addon system: `aap-demo enable console`, `aap-demo enable registry`, `aap-demo enable mcp-server`
- Reproducible — destroy and recreate in minutes

## Quick Start

### Prerequisites

**OpenShift Local:**

- OpenShift Local — [Download](https://console.redhat.com/openshift/create/local)
- On Linux: also install `libvirt-daemon`, `libvirt-daemon-driver-storage`, `libvirt-daemon-driver-network`, `qemu-kvm`

**OpenShift client:**

```bash
# Download OpenShift client (pick your platform)
# macOS ARM:   curl -LO https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-mac-arm64.tar.gz
# macOS Intel: curl -LO https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-mac.tar.gz
# Linux:       curl -LO https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-linux.tar.gz

tar -xzf openshift-client-*.tar.gz
sudo cp oc kubectl /usr/local/bin/

# Download pull secret from https://console.redhat.com/openshift/install/pull-secret
mkdir -p ~/.aap-demo
cp ~/Downloads/pull-secret.txt ~/.aap-demo/pull-secret.txt
```

### Install

```bash
git clone https://github.com/ansible-automation-platform/aap-demo.git
cd aap-demo && ./install.sh
```

### Deploy

```bash
aap-demo create        # Create the cluster
aap-demo deploy        # Deploy AAP 2.7
aap-demo status        # Check deployment status
```

On first run, you'll be prompted to select an infrastructure backend (CRC recommended). The choice is saved to `~/.aap-demo/config`.

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

# Addons
aap-demo enable console      # Enable OpenShift console addon
aap-demo enable registry     # Enable in-cluster container registry
aap-demo enable mcp-server   # Enable MCP server for AI assistants

# Maintenance
aap-demo clean               # Remove AAP deployment (keeps cluster)
aap-demo update              # Pull latest code and reinstall
aap-demo help                # Full command reference
```

## Credentials

A Red Hat pull secret is required:

```bash
mkdir -p ~/.aap-demo
# Download from: https://console.redhat.com/openshift/install/pull-secret
# Save as: ~/.aap-demo/pull-secret.txt
```

## Architecture

### macOS  / Linux (CRC backend) / Windows (in development)

```text
Host
└── CRC (OpenShift Local) VM
    ├── MicroShift or full OpenShift (user choice)
    ├── CRI-O (container runtime)
    ├── Podman (shared storage with CRI-O)
    └── AAP pods
```

- **VM lifecycle:** Managed by CRC (`crc start`, `crc stop`, `crc delete`)
- **Networking:** SSH (2222), API (6443), HTTP/HTTPS (443) — all on localhost
- **Routes:** `*.apps.127.0.0.1.nip.io` (nip.io DNS, no /etc/hosts needed)
- **TLS:** MicroShift's ingress CA auto-trusted on macOS keychain / Linux ca-trust

## Addons

```bash
aap-demo enable                # List all addons with status
aap-demo enable registry       # In-cluster container registry
aap-demo enable mcp-server     # MCP server for AI assistants (requires AAP)
```

Addons are saved to `~/.aap-demo/config` and auto-deployed on `aap-demo create`.

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

## Contributing

For questions or contributions, open an issue or pull request on GitHub.
