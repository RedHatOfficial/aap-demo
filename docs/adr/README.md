# Architecture Decision Records (ADR)

This directory contains Architecture Decision Records for the aap-demo project.

## What is an ADR?

An Architecture Decision Record (ADR) captures an important architectural decision made along with its
context and consequences. ADRs help us understand why certain decisions were made and provide a
historical record of the project's evolution.

## ADR Format

We use a simplified ADR format based on [Michael Nygard's template](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions):

- **Title**: Short noun phrase
- **Status**: Proposed | Accepted | Deprecated | Superseded
- **Context**: What is the issue we're seeing that motivates this decision?
- **Decision**: What is the change we're proposing/doing?
- **Consequences**: What becomes easier or more difficult because of this change?

## Architecture Overview

```text
┌─────────────────────────────────────────────────────────────────────────┐
│  aap-demo CLI (bash / PowerShell)                                       │
│    create │ deploy │ status │ diagnose │ enable <addon> │ destroy       │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
  CRC / MicroShift          OLM + Operator           Addons
  (ADR-003)                 (ADR-005, 009)          (ADR-008)
        │                       │                       │
        ├─ NFS RWX (006)        ├─ AAP CR              ├─ portal (002, 004)
        ├─ CoreDNS (007)        └─ SCC/PSA (012)       ├─ mcp-server (011)
        └─ Registry (013)                              ├─ fleet (016)
                                                       └─ registry (013)
```

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [001](001-project-cli-architecture.md) | Project Purpose and CLI Architecture | Accepted |
| [002](002-portal-helm-deployment.md) | Portal Helm Deployment Architecture (x86 and ARM) | Accepted |
| [003](003-infrastructure-backend-selection.md) | Infrastructure Backend Selection | Accepted |
| [004](004-portal-helm-addon.md) | Portal Helm Addon Architecture | Accepted |
| [005](005-olm-on-microshift.md) | OLM Installation on MicroShift | Accepted |
| [006](006-storage-architecture.md) | Storage Architecture | Accepted |
| [007](007-coredns-route-resolution.md) | CoreDNS Route Resolution for nip.io | Accepted |
| [008](008-addon-system.md) | Addon System Architecture | Accepted |
| [009](009-aap-operator-olm-deployment.md) | AAP Operator Deployment via OLM | Accepted |
| [010](010-cross-platform-cli.md) | Cross-Platform CLI (Bash and PowerShell) | Accepted |
| [011](011-mcp-server-addon.md) | MCP Server Addon | Accepted |
| [012](012-scc-and-pod-security.md) | Security Context Constraints and Pod Security | Accepted |
| [013](013-in-cluster-registry.md) | In-Cluster Container Registry | Accepted |
| [014](014-testing-strategy.md) | CLI Testing Strategy | Accepted |
| [015](015-ingress-ca-user-store-trust.md) | Ingress CA Trust via User Certificate Stores | Accepted |
| [016](016-fleet-addon.md) | Fleet Addon — Local QEMU VMs as Managed Nodes | Accepted |

## Creating a New ADR

1. Copy the template: `cp docs/adr/000-template.md docs/adr/XXX-title.md`
2. Increment the number (XXX)
3. Fill in the sections
4. Update this index
5. Commit with message: `docs(adr): Add ADR-XXX: Title`

Note: Numbers may not be sequential; gaps indicate removed or consolidated drafts.

## Reading Order

For new contributors, read ADRs in this order:

1. **001** — what aap-demo is and how the CLI is structured
2. **003** — why CRC MicroShift is the default backend
3. **005** + **009** — how AAP gets installed
4. **006** + **007** + **012** — common deploy failure areas
5. **008** — how optional components plug in
6. **002** + **004** — portal (if using Self-Service Portal)
7. **010** + **014** — Windows and testing
