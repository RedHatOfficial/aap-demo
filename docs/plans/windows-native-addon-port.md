# Native PowerShell Addon Port Plan

<!-- markdownlint-disable MD013 -->

**Branch:** `codex/windows-native-addons`

**Parent:** `codex/windows-feature-parity`

**Goal:** remove the Git Bash runtime dependency from the Windows CLI while preserving the current Bash behavior.

## Boundary

PowerShell will own addon deployment, deletion, wiring, status, and cleanup on Windows. It may invoke supported Windows binaries such as `oc`, `kubectl`, and `curl`, but it will not invoke `bash`, `sh`, WSL, or shell snippets. APME remains alpha and is intentionally excluded from the Windows build; Fleet remains out of scope.

## Work slices

Current progress: the native process runner, Kubernetes manifest helpers, Ollama deployment/removal, Automation Orchestrator operator/database/instance deployment and cleanup, AO-to-AAP/MCP/Ollama wiring, and AO demo provisioning/import have native PowerShell paths. Local-cache clear/validate are also native. APME is deferred while it remains alpha. Remaining addon families fail with an explicit native-port message until their ports land, so this branch does not silently invoke Bash.

1. Add a native process runner that captures stdout, stderr, exit status, cancellation, and redacted diagnostics without relying on shell quoting.
2. Port shared wiring primitives to PowerShell: route discovery, kube API calls, AAP authentication, CA handling, credentials, integrations, AO model binding, and idempotent retries.
3. Port addon lifecycle handlers in dependency order: MCP and portal-operator, Ollama and OPA, AO, aggregate Product Demos, setup-pah, and local-cache. Product Demos is one Windows deployment entry point; revisit APME after its alpha period.
4. Replace the Git Bash adapter from the Windows command path. `diagnose --ai` should report that the AI helper requires an explicitly installed provider rather than silently invoking Bash.
5. Add unit tests for process argument boundaries, environment/path handling, API request construction, state persistence, and failure cleanup. Keep CRC tests opt-in and destructive tests isolated.
6. Update help, README, ADR references, and the Windows validation matrix to describe native PowerShell ownership and remaining external executable prerequisites.

## Acceptance criteria

- `aap-demo enable`, `disable`, `wire`, `deploy`, `watch`, and `diagnose` run without Git Bash or WSL.
- Addon arguments containing spaces and Windows paths arrive unchanged at the target executable.
- A failed first deployment does not persist the addon as enabled.
- AO, aggregate Product Demos, portal-operator, OPA, Ollama, MCP, local-cache, and PAH setup have equivalent cleanup and dependency behavior. APME is deferred from Windows.
- No Fleet registry entry, lifecycle hook, or implementation is added.
- PowerShell 5.1 and PowerShell 7 parse and pass the static/native unit test suite.
