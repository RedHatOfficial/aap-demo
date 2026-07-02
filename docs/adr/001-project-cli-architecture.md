# ADR-001: Project Purpose and CLI Architecture

**Status**: Accepted

**Date**: 2026-06-10

**Authors**: aap-demo maintainers

## Context

Developers and testers need a reproducible local environment for Ansible Automation Platform
(AAP) 2.7 on OpenShift-compatible infrastructure. Production OpenShift clusters are expensive,
slow to provision, and unsuitable for day-to-day feature work.

The project must:

- Deploy AAP in minutes with a single entry point (`aap-demo`)
- Work on macOS, Linux, and Windows
- Support cluster lifecycle (create, deploy, idle, clean, destroy)
- Offer optional components (portal, MCP server, registry) without complicating the default path
- Remain maintainable as a shell-first tool with minimal dependencies

## Decision

Build **aap-demo** as a CLI wrapper around OpenShift Local (CRC/MicroShift) that orchestrates
cluster provisioning, OLM installation, AAP operator deployment, and optional addons.

### CLI structure

| Layer | Path | Role |
|-------|------|------|
| Entry point (Unix) | `aap-demo.sh` | Bash dispatcher; symlinked to `~/.local/bin/aap-demo` by `install.sh` |
| Entry point (Windows) | `powershell/aap-demo.ps1` | PowerShell launcher importing `powershell/native/AapDemo.psm1` |
| Infrastructure | `includes/infra-api.sh`, `includes/infra-crc.sh` | Backend abstraction for SSH and kubeconfig |
| Cluster create | `includes/crc-create.sh` | CRC VM setup, NFS, CoreDNS, OLM bootstrap |
| Manifests | `config/manifests/`, `config/olm/`, `config/crs/` | Kubernetes/OpenShift resources applied at deploy time |
| Addons | `addons/<name>/deploy.sh` | Pluggable optional components |
| User state | `~/.aap-demo/` | Config, pull secrets, portal OAuth creds, ingress CA |

### Command categories

1. **Lifecycle** — `create`, `deploy`, `stop`, `start`, `destroy`, `clean`, `redeploy-all`
2. **Observability** — `status`, `watch`, `diagnose`, `must-gather`
3. **Operations** — `idle`, `ssh`, `repair`, `update`
4. **Addons** — `enable <addon>`, `disable <addon>`, `status <addon>`
5. **Testing** — `test` (delegates to AAP ATF via Ansible)

### Configuration model

- `~/.aap-demo/config` stores `INFRA`, `CRC_PRESET`, and user preferences
- Environment variables override defaults: `NAMESPACE`, `CRC_CPUS`, `CRC_MEMORY`, `QUIET`, `AAP_OCP_VERSION`
- `KUBECONFIG` defaults to CRC path when unset

### Design principles

- **Delegate, don't reimplement** — Cluster operations use `crc`, `kubectl`/`oc`, `helm`, and
  `operator-sdk`; the CLI wires them together
- **Idempotent commands** — Re-running `deploy` or `enable` updates state safely
- **Fail with fixes** — `diagnose` outputs actionable remediation, not just errors
- **Destructive guardrails** — `destroy`, `clean`, and `redeploy-all` require confirmation unless `QUIET=true`

## Consequences

### Positive

- One command (`aap-demo deploy`) covers the full happy path
- Clear separation between core CLI, infrastructure backends, and addons
- User state isolated under `~/.aap-demo/` — repo stays read-only after install
- Skill and docs can reference a stable command surface

### Negative

- `aap-demo.sh` is large (~2,500 lines) — high cognitive load for contributors
- Bash and PowerShell implementations must stay in sync manually
- Monolithic script resists unit testing without grep-based integration tests

### Neutral

- No long-running daemon; each invocation is a shell process
- Ansible used only for ATF test execution, not core deploy flow

## Alternatives Considered

### Ansible playbook as primary interface

Rejected: slower feedback loop, harder for Windows users, and obscures imperative cluster
steps (CRC start, CoreDNS patch) that need explicit ordering.

### Helm chart for entire aap-demo stack

Rejected: AAP itself is operator-managed; wrapping CRC + OLM + operator in one chart adds
indirection without simplifying user workflow.

### Docker Compose / kind

Rejected: lacks OpenShift Routes, SCCs, and OLM — required for faithful AAP operator testing.

## References

- [README.md](../../README.md) — user-facing overview
- [ADR-003](003-infrastructure-backend-selection.md) — CRC backend selection
- [ADR-008](008-addon-system.md) — addon plugin pattern
- [ADR-010](010-cross-platform-cli.md) — PowerShell parity
