# Windows Feature Parity Plan

**Scope:** Windows parity follow-up to [PR #95](https://github.com/RedHatOfficial/aap-demo/pull/95)

**Branch:** `codex/windows-feature-parity`

**Date:** 2026-09-26

> This hybrid/native plan is superseded for the current implementation by
> [`windows-git-bash-wrapper.md`](windows-git-bash-wrapper.md) and ADR-031.

## Goal

Bring the PowerShell CLI and its Windows addon workflow up to date with the current Bash CLI while preserving the native Windows experience for the core cluster lifecycle. Fleet remains out of scope for this effort.

## Current state

The existing PowerShell implementation has native handlers for the core lifecycle, status, diagnostics, deployment, cleanup, PAH setup, portal, and MCP server. Its addon registry contains the supported Windows addons; the alpha APME addon is intentionally excluded.

Since the previous Windows work, `main` has added or changed:

- addon auto-wiring for AAP, MCP, Automation Orchestrator, and Product Demos;
- the GA `ao` flow with Ollama or external LLM selection and agentic workflow model binding;
- the `ollama` and `opa` addons;
- the operator-based `portal-operator` addon;
- the Product Demos base, aggregate, and domain addons;
- local-cache lifecycle integration with destroy and deploy;
- CRC version checks, catalog fallbacks, readiness changes, and newer status paths.

The PowerShell launcher also advertises `start` without dispatching it, has no `wire` command, and does not forward the full set of addon flags and positional arguments. The generic addon bridge invokes Bash scripts, but it does not yet provide a deliberate Windows adapter for environment propagation, path conversion, prerequisite diagnostics, or cleanup options.

## Implementation phases

### 1. Establish the command contract

- Add native `start` behavior that restores CRC, refreshes the isolated kubeconfig, reapplies MicroShift DNS, and restores ingress CA environment state.
- Add `wire` dispatch with strict failure reporting and the same post-deploy/enable wiring semantics as Bash.
- Keep aliases aligned (`deploy-all`, `ao-eap`, `rh-status`, version flags) and make help output reflect actual dispatch.
- Extend argument parsing and forwarding for `--force`, `--refresh-catalog`, `--skip-cache`, `--purge-data`, `--purge-creds`, `CR`, `PUBLIC_URL`, `NAMESPACE`, and addon-specific positional arguments.
- Preserve PowerShell 5.1 compatibility and avoid requiring WSL for the core lifecycle.

### 2. Define one Windows addon registry

Expose every current non-fleet addon that has a supported Bash deployment path:

`mcp-server`, `portal`, `portal-operator`, `setup-pah`, `ao`/`ao-eap`, `local-cache`, `product-demos`, `opa`, and `ollama`. Product Demos is a single aggregate deployment on Windows; APME is deferred while it remains alpha.

- Normalize aliases before saving `ADDONS`.
- Keep dependency behavior explicit: AO must ensure MCP and its selected LLM provider; Product Demos deploys its base and domains as one aggregate operation.
- Save an addon only after a successful deployment and remove it only after a successful disable operation, including purge options.
- Keep `fleet` out of the registry, help, tests, and acceptance criteria for this branch.

### 3. Harden the Windows addon execution adapter

Keep addon implementations in their existing `deploy.sh` files for this pass, but make the PowerShell bridge a supported adapter:

- resolve Git Bash once and report an actionable prerequisite error when it is unavailable;
- pass the synchronized Windows kubeconfig, namespace, CA variables, and relevant environment overrides into Git Bash;
- convert Windows paths used by addon workflows, pull secrets, token files, plugin archives, and purge credentials to Git Bash-compatible paths;
- forward `--delete`, `--force`, `--refresh-catalog`, `--purge-data`, `--purge-creds`, `load`, `clear`, and other addon arguments without quoting loss;
- capture stdout/stderr and exit codes so failed first-time enables do not remain marked as enabled;
- make `local-cache` load/clear one-shot actions match Bash and keep cache state across destroy/recreate.

### 4. Bring status, help, and diagnostics to parity

- Show the complete addon registry and distinguish disabled, enabled, not deployed, and route-ready states.
- Surface AO, portal-operator, Ollama, OPA, MCP, and Product Demos routes or actionable status hints where those addons expose them.
- Add wiring status and remediation hints to `status`/`diagnose` without exposing secrets.
- Align CRC version checks, AAP readiness checks, SCC/PSA checks, catalog health, and local-cache diagnostics with the current Bash behavior.
- Delegate `diagnose --ai` to Git Bash with the same explicit prerequisite and failure message used by the Windows adapter, rather than silently claiming native support.

### 5. Validate each parity slice on Windows

Use a Windows/CRC validation matrix. The tests should be non-destructive by default and reserve clean/destroy cycles for an explicitly labeled integration job.

| Area | Acceptance checks |
|---|---|
| Core lifecycle | `create`, `deploy`, `status`, `stop`, `start`, `repair`, `kubeconfig`, `redeploy`, `redeploy-all`, `clean`, `destroy` |
| Wiring | `deploy`/`watch` auto-wire; explicit `wire` is idempotent and reports failures |
| AO | `enable ao` with Ollama, external provider, and no-LLM paths; `ao-eap` alias; `disable ao --purge-data` |
| Product Demos | aggregate enable/disable path; credential and auto-wiring hints |
| Other addons | MCP, Helm portal, portal-operator (AMD64 guard), OPA, Ollama, and local-cache save/load/clear |
| Failure handling | missing Git Bash/tooling, bad paths, failed deploy, interrupted cleanup, and stale kubeconfig |
| Documentation | Windows README, help output, ADR-010 cross-reference, and this plan stay consistent |

Run static PowerShell parsing/lint checks on every change. Record at least one real Windows/CRC pass for each addon family before implementation is considered complete.

## Risks and controls

- **Dual implementation drift:** keep the registry, command matrix, and acceptance table explicit; update the parity documentation with every Bash feature addition.
- **Git Bash boundary errors:** centralize environment and path conversion in one adapter and test both PowerShell 5.1 and PowerShell 7.
- **Secrets in diagnostics:** redact tokens, passwords, and API keys from captured output; preserve existing file permissions and purge semantics.
- **Resource pressure:** portal-operator and Ollama need CPU-aware preflight and clear Windows guidance; do not hide failed scheduling behind a generic addon error.
- **Fleet scope creep:** do not add fleet registry entries, lifecycle hooks, or Windows QEMU behavior in this branch.

## Deliverables

1. PowerShell command and addon parity implementation.
2. Windows adapter and focused tests for argument/environment propagation.
3. Updated Windows README/help and parity references.
4. ADR-029 documenting the architecture and the deliberate fleet exclusion.
