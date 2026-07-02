# ADR-011: MCP Server Addon

**Status**: Accepted

**Date**: 2026-07-02

**Authors**: aap-demo maintainers

## Context

AI assistants and automation tools increasingly interact with AAP via the **Model Context
Protocol (MCP)**. AAP operator 2.6+ ships an `AnsibleMCPServer` CRD managed by the operator.

aap-demo users need a one-command path to expose MCP tools against their local AAP instance for
Cursor, Claude Code, and similar clients.

## Decision

Add **`mcp-server` addon** that applies an `AnsibleMCPServer` CR via `addons/mcp-server/deploy.sh`.

### Deployment

```bash
aap-demo enable mcp-server
```

Applies `addons/mcp-server/mcp-server.yaml` with namespace and hostname substitution:

| Field | Value |
|-------|-------|
| `public_base_url` | `https://aap-<namespace>.apps.127.0.0.1.nip.io` |
| `hostname` / `route_host` | `aap-mcp-<namespace>.apps.127.0.0.1.nip.io` |
| `ingress_type` | Route (Edge TLS) |
| `allow_write_operations` | `true` (dev/test only) |

### Prerequisites

- AAP operator CSV running in target namespace
- `AnsibleMCPServer` CRD installed (bundled with operator 2.6+)
- `redhat-operators-pull-secret` for image pulls

Script warns and proceeds if operator or CRD not yet ready — CR reconciles when available.

### AAP interaction policy

The aap-demo skill explicitly **prohibits awxkit** for AAP operations. Preferred order:

1. MCP server tools (when enabled)
2. `kubectl`/`oc` for operator resources
3. Direct REST API via `curl`
4. Ansible modules (last resort)

This ADR positions MCP as the preferred programmatic interface for AI-assisted workflows.

### Endpoint

```text
https://aap-mcp-<namespace>.apps.127.0.0.1.nip.io/mcp
```

Documented in [docs/aap-mcp-server.md](../aap-mcp-server.md).

## Consequences

### Positive

- Single CR — operator handles Deployment, Service, Route
- Enables 100+ typed MCP tools for AI clients
- Consistent with production AAP MCP architecture
- PowerShell native support (`Invoke-AapDeployMcpServerAddon`)

### Negative

- `allow_write_operations: true` is unsafe for production — dev-only default
- Requires operator 2.6+; older channels lack CRD
- MCP route depends on CoreDNS nip.io fix (ADR-007)
- Additional pod resources (~512 Mi–1 Gi memory)

### Neutral

- MCP auth follows AAP gateway OAuth/token model
- Disable removes CR only — operator cleans up child resources

## Alternatives Considered

### Standalone MCP container outside operator

Rejected: duplicates operator logic; diverges from supported deployment.

### awxkit-based CLI bridge

Rejected: dependency conflicts, inconsistent tooling (see skill policy).

### Disable write operations by default

Deferred: reduces usefulness for dev automation; documented as dev-only risk.

## References

- [addons/mcp-server/deploy.sh](../../addons/mcp-server/deploy.sh)
- [addons/mcp-server/mcp-server.yaml](../../addons/mcp-server/mcp-server.yaml)
- [docs/aap-mcp-server.md](../aap-mcp-server.md)
- [ADR-008](008-addon-system.md)
- [ADR-009](009-aap-operator-olm-deployment.md)
