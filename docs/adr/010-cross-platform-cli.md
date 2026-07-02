# ADR-010: Cross-Platform CLI (Bash and PowerShell)

**Status**: Accepted

**Date**: 2026-06-15

**Authors**: aap-demo maintainers

## Context

aap-demo targets macOS and Linux (bash) and Windows (PowerShell). Windows lacks native bash,
CRC uses Hyper-V, and path conventions differ (`%USERPROFILE%` vs `$HOME`).

Requirements:

- Same command names and semantics across platforms
- Windows users should not require WSL for core workflow
- Ingress TLS must work in browsers on all platforms

## Decision

Maintain **two parallel CLI implementations** sharing behavior but not code:

| Platform | Implementation | Kube CLI |
|----------|----------------|----------|
| macOS / Linux | `aap-demo.sh` (bash) | `kubectl` + `oc` |
| Windows | `powershell/native/*.ps1` | `oc` only |

### Windows architecture

```text
powershell/aap-demo.ps1
      │
      ▼
AapDemo.psm1
      ├── Create.ps1    — CRC create, CoreDNS, OLM
      ├── Deploy.ps1    — OLM, Subscription, AAP CR
      ├── Status.ps1    — routes, credentials, addons
      ├── Diagnose.ps1  — health checks (parity with bash)
      ├── Commands.ps1  — idle, destroy, clean, must-gather
      └── Helpers.ps1   — oc wrappers, config, SCC grants
```

`powershell/install.ps1` registers `aap-demo` in `%USERPROFILE%\.local\bin` and installs `oc` via winget when missing.

### Parity scope

| Feature | Bash | PowerShell |
|---------|------|------------|
| create, deploy, status | ✓ | ✓ |
| diagnose | ✓ | ✓ |
| diagnose --ai | ✓ (claude CLI) | Delegates to Git Bash |
| enable mcp-server | ✓ | ✓ |
| enable portal | ✓ | Limited / Git Bash |
| test, watch | ✓ | Git Bash delegation |
| ingress CA trust | `ingress-ca-trust.sh` | `Install-AapIngressCaTrust` |

PowerShell uses **native CRC/OpenShift operations** for the critical path; Git Bash is optional for advanced commands.

### Ingress CA trust

MicroShift generates a self-signed ingress CA. Without trust, browsers and `curl` fail TLS validation.

- **macOS**: `security add-trusted-cert` to keychain
- **Linux**: copy to `/etc/pki/ca-trust/source/anchors/` + `update-ca-trust`
- **Windows**: `certutil -addstore` via UAC prompt in `aap-demo status`

CA saved to `~/.aap-demo/crc-ingress-ca.crt`; `CURL_CA_BUNDLE` exported for CLI tools.

Skip with `AAP_DEMO_TRUST_CA=false`.

See [ADR-015](015-ingress-ca-user-store-trust.md) for the user-store trust strategy
(Windows CurrentUser, Linux NSS, macOS keychain).

### Configuration parity

Both platforms read `%USERPROFILE%\.aap-demo\config` / `~/.aap-demo/config` with `CRC_PRESET`,
namespace preferences, and infra type.

## Consequences

### Positive

- Windows developers use PowerShell natively — no WSL required for deploy
- Ingress CA automation fixes the most common Windows TLS pain point
- Modular PowerShell files mirror bash command categories

### Negative

- **Dual maintenance** — behavior changes need updates in two codebases
- Feature parity gaps (portal, test) on Windows without Git Bash
- Subtle semantic differences risk drift (e.g., SCC grant timing)

### Neutral

- `install.sh` / `install.ps1` are separate but symmetric
- Shell completions only for bash/zsh today

## Alternatives Considered

### WSL-only on Windows

Rejected: excludes developers who cannot use WSL; Hyper-V conflict concerns.

### Single bash script via Git Bash on Windows

Rejected: poor UX; path and CRC integration awkward.

### Go/Rust rewrite

Deferred: high effort; shell matches target audience (Ansible/OpenShift admins).

## References

- [powershell/README.md](../../powershell/README.md)
- [includes/ingress-ca-trust.sh](../../includes/ingress-ca-trust.sh)
- [install.sh](../../install.sh)
- [powershell/install.ps1](../../powershell/install.ps1)
- [ADR-001](001-project-cli-architecture.md)
