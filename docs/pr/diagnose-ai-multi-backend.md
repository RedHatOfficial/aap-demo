# PR: Multi-backend AI support for `aap-demo diagnose --ai`

## Summary

- Extend `aap-demo diagnose --ai` to support **Cursor Agent** (in-session), **Cursor CLI**, and **Claude CLI** instead of requiring Claude only
- Add `AAP_DIAGNOSE_AI_BACKEND` env var (`auto`, `embedded`, `cursor`, `claude`) for explicit backend selection
- Auto-patch gateway `supplementalGroups: [0]` during deploy/repair (fixes supervisord EACCES on OpenShift Local)
- Delegate PowerShell `diagnose --ai` to `aap-demo.sh` via Git Bash

## Motivation

`diagnose --ai` previously required the `claude` CLI and failed in Cursor Agent sessions where `CURSOR_AGENT=1` is set but no external CLI is configured. Users working inside Cursor or with the Cursor CLI installed could not use AI-assisted diagnostics without installing Claude separately.

Additionally, diagnose frequently reported gateway `supplementalGroups` missing on OpenShift Local — a known fix that deploy only partially addressed (NET_BIND_SERVICE only).

## Changes

### `aap-demo.sh`

| Area | Change |
|------|--------|
| `_diagnose_ai_resolve_backend()` | Select backend: `embedded` when `CURSOR_AGENT=1`, else Cursor CLI, else Claude CLI |
| `_build_diagnose_ai_context()` | Shared diagnostic context (pods, PVCs, events, problem pod logs) |
| `_run_diagnose_ai_analysis()` | Dispatch to embedded / cursor / claude backends with fallback |
| `_patch_gateway_supplemental_groups()` | New helper; patches `supplementalGroups: [0]` on gateway deployment |
| `_patch_gateway_net_bind_service()` | Extracted from `_patch_gateway_capability()` |
| `cmd_repair` | Applies gateway capability + supplementalGroups patches |
| Help text | Documents backends and `AAP_DIAGNOSE_AI_BACKEND` |

### Backend behavior

| Backend | Trigger | Behavior |
|---------|---------|----------|
| `embedded` | `CURSOR_AGENT=1` or `AAP_DIAGNOSE_AI_BACKEND=embedded` | Prints diagnostic context + prompt for the active Cursor agent; saves to `~/.aap-demo/diagnose-ai-context.txt` |
| `cursor` | `cursor` in PATH or `AAP_DIAGNOSE_AI_BACKEND=cursor` | Runs `cursor agent --print --mode ask`; falls back to Claude or prints context on auth failure |
| `claude` | `claude` in PATH or `AAP_DIAGNOSE_AI_BACKEND=claude` | Existing `claude -p` flow |
| `auto` (default) | — | `embedded` → `cursor` → `claude` → error with install hints |

### PowerShell (`Diagnose.ps1`)

- `diagnose --ai` delegates to `aap-demo.sh diagnose --ai` via Git Bash (same as addon deploy scripts)
- Passes `NAMESPACE` env var when set

### Documentation

- `README.md`, `docs/FULL-README.md`, `SKILL.md`, `.claude/CLAUDE.md`
- `docs/adr/010-cross-platform-cli.md`, `powershell/README.md`

## Test plan

- [ ] `bash -n aap-demo.sh` — syntax check passes
- [ ] `aap-demo diagnose` — health checks run without `--ai`
- [ ] `CURSOR_AGENT=1 aap-demo diagnose --ai` — prints "AI Analysis (Cursor Agent)" and saves context file
- [ ] `AAP_DIAGNOSE_AI_BACKEND=claude aap-demo diagnose --ai` — uses Claude CLI when installed
- [ ] `AAP_DIAGNOSE_AI_BACKEND=cursor aap-demo diagnose --ai` — uses Cursor CLI when logged in
- [ ] `aap-demo repair` — patches gateway supplementalGroups if missing
- [ ] Fresh `aap-demo deploy` — gateway gets both NET_BIND_SERVICE and supplementalGroups
- [ ] PowerShell: `aap-demo diagnose --ai` delegates to bash (Windows/Git Bash)

## Example usage

```bash
# Default: auto-select backend
aap-demo diagnose --ai

# Inside Cursor Agent session (CURSOR_AGENT=1 set automatically)
aap-demo diagnose --ai

# Force a specific backend
AAP_DIAGNOSE_AI_BACKEND=cursor aap-demo diagnose --ai
AAP_DIAGNOSE_AI_BACKEND=claude aap-demo diagnose --ai
```

## Out of scope

Ingress CA trust hardening (`includes/ingress-ca-trust.sh`, `includes/crc-create.sh`) is a separate fix and not included in this PR.
