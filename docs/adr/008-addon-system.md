# ADR-008: Addon System Architecture

**Status**: Accepted

**Date**: 2026-07-02

**Authors**: aap-demo maintainers

## Context

Core aap-demo delivers AAP on MicroShift. Optional capabilities — portal, MCP server,
in-cluster registry, DevSpaces, console — should be:

- Opt-in (not installed by default)
- Independently deployable and removable
- Discoverable via `aap-demo enable` without bloating the main script

## Decision

Implement addons as **self-contained directories** under `addons/<name>/` with a standard `deploy.sh` contract.

### Directory contract

```text
addons/<addon>/
├── deploy.sh          # Required: deploy and --delete
├── *.yaml             # Optional: Kubernetes manifests
├── values.yaml.template  # Optional: Helm values (portal)
└── README.md          # Optional: operator documentation
```

### deploy.sh interface

| Invocation | Behavior |
|------------|----------|
| `./deploy.sh` | Install or upgrade addon |
| `./deploy.sh --delete` | Remove addon resources |

Optional header comment for prerequisites:

```bash
# ADDON_REQUIRES_AAP=true
```

### CLI integration

`aap-demo.sh` maintains `AVAILABLE_ADDONS` and dispatches:

```text
aap-demo enable <addon>  →  bash addons/<addon>/deploy.sh
aap-demo disable <addon> →  bash addons/<addon>/deploy.sh --delete
aap-demo status <addon>  →  built-in case per addon (routes, pods)
```

Current first-class addons in `AVAILABLE_ADDONS`:

| Addon | Requires AAP | Mechanism |
|-------|--------------|-----------|
| `mcp-server` | Yes | AnsibleMCPServer CR |
| `portal` | Yes | Helm chart |

Additional addons invoked via `enable` but not in `AVAILABLE_ADDONS` list:

| Addon | Mechanism |
|-------|-----------|
| `olm` | operator-sdk (called from create, not user-facing enable) |
| `registry` | Namespace + Deployment |
| `console` | OpenShift console (OpenShift preset or manifest) |
| `devspaces` | CheCluster CR |
| `prometheus` | Monitoring stack |

### Design rules

1. Addons **must not** modify core AAP CR unless documented
2. Addons use `NAMESPACE` env var when AAP-scoped
3. Addons check `kubectl cluster-info` before applying resources
4. Idempotent: re-enable upgrades in place
5. `--delete` cleans up cluster resources; user-local state (e.g., `~/.aap-demo/portal/`) documented per addon

## Consequences

### Positive

- New addons added without restructuring `aap-demo.sh` — one line in `AVAILABLE_ADDONS` + status case
- Each addon is testable in isolation
- Users install only what they need
- Portal complexity isolated in `addons/portal/` (see ADR-002, ADR-004)

### Negative

- No formal addon metadata schema (version, dependencies) — convention only
- `AVAILABLE_ADDONS` list can drift from `addons/` directory contents
- Status reporting is per-addon switch/case, not auto-discovered

### Neutral

- Windows PowerShell implements subset of addons natively (`mcp-server`); others may delegate to Git Bash or remain Unix-only

## Alternatives Considered

### Subcommands in monolithic script only

Rejected: portal deploy alone is 700+ lines — unmaintainable inline.

### Helm umbrella chart for all addons

Rejected: addons have heterogeneous lifecycles (CR vs Helm vs operator-sdk).

### OLM-managed addon operators

Rejected: overkill for optional dev components.

## References

- [addons/](../../addons/)
- [ADR-002](002-portal-helm-deployment.md)
- [ADR-004](004-portal-helm-addon.md)
- [ADR-011](011-mcp-server-addon.md)
- [ADR-013](013-in-cluster-registry.md)
