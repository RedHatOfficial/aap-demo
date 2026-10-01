# ADR-031: Windows Git Bash Command Wrapper

**Status**: Accepted

**Date**: 2026-09-30

## Context

The repository's Bash CLI is the maintained source of truth for CRC lifecycle,
OLM recovery, addon dependencies, wiring, cleanup, and new feature additions.
Maintaining parallel native PowerShell implementations caused the Windows AO
path to lag behind the GA catalog behavior and made every addon addition a second
implementation task.

## Decision

Keep PowerShell as the Windows launcher and policy boundary, but delegate every
supported command to `aap-demo.sh` through Git Bash. The wrapper discovers a
Git-for-Windows `bash.exe`, forwards arguments and inherited environment values,
captures output and exit codes, and reports an actionable prerequisite error.

The wrapper continues to enforce the Windows addon surface. Fleet, APME, and
legacy Product Demo domain aliases are rejected even though their Bash code may
still exist for other platforms. Product Demos remains one aggregate Windows
entry point. Native PowerShell modules remain available for development and
future migration, but they are not the Windows launcher execution path.

Windows deploys and AO/Product Demo enablement run a PowerShell preflight for
the external tools required at the Bash boundary. `jq` is required for JSON
wiring, and Python is required for AAP demo provisioning and AO workflow
imports. When either runtime is missing, the preflight installs it with
winget (`jqlang.jq` and `Python.Python.3.13`) and reports the same commands if
installation fails. Direct Git Bash invocation performs the equivalent
Windows-only checks and leaves Linux and macOS behavior unchanged.

## Consequences

Windows behavior now stays aligned with Bash automatically, including AO's GA
catalog handling and future addon fixes. Git for Windows becomes a required
runtime dependency, and shell output/quoting remains part of the boundary. The
wrapper must keep forwarding arguments and environment values without leaking
secrets or changing addon state semantics. Windows demo enablement has a small
host-runtime install step, while the cluster itself remains the deployment
boundary; Linux and macOS do not inherit the Windows auto-install behavior.

## Alternatives considered

- **Maintain native PowerShell implementations:** rejected for now because it
  duplicates complex addon behavior and already drifted from the Bash AO flow.
- **Use a mixed native/Bash addon matrix:** rejected because it preserves the
  same split-brain behavior and makes troubleshooting dependent on the selected
  addon.
- **Run the entire PowerShell process through WSL:** rejected because it adds a
  second virtualization dependency; Git Bash is already the repository's Windows
  shell boundary.

## References

- [ADR-029 — Windows Feature Parity Strategy](029-windows-feature-parity.md)
- [ADR-030 — Native PowerShell Addon Execution](030-windows-native-addon-execution.md)
- [Windows Git Bash Wrapper Plan](../plans/windows-git-bash-wrapper.md)
