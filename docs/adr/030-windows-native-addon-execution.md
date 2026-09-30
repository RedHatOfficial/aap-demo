# ADR-030: Native PowerShell Addon Execution

**Status**: Proposed

**Date**: 2026-09-26

## Context

ADR-029 established a Git Bash adapter so Windows could expose the current Bash addon surface quickly. That provides short-term parity, but it leaves Git for Windows as a runtime prerequisite and preserves shell quoting and path conversion risks. The Windows CLI now needs a native implementation rather than another adapter layer.

## Decision

The Windows CLI will port addon deployment and wiring logic to PowerShell. PowerShell will invoke platform binaries directly through a structured process runner and use `oc`, `kubectl`, and `curl` for the native control path. APME will create and launch its deployment job through the AAP Controller API. The job uses a standard-library OCI publisher and bootstraps a pinned Helm client inside the execution environment when the selected EE does not include Helm. Windows does not reproduce that toolchain locally, and the native path will not invoke Bash, WSL, or shell command strings.

The port will preserve the existing addon dependency graph, state persistence rules, cleanup flags, credential handling, and idempotent wiring behavior. Fleet remains outside this decision and requires its own design.

The existing hybrid implementation remains available on `codex/windows-feature-parity` while this branch is developed. The native branch may temporarily port addon families in slices, but it must not claim full parity until every listed non-Fleet addon has a native handler and validation coverage.

## Consequences

Native execution removes Git Bash and shell quoting from the Windows runtime path, but it requires maintaining a second implementation for complex addon logic and increases the initial porting effort. AAP becomes the execution boundary for APME's deployment dependencies, so Windows does not need to reproduce that toolchain locally.

## Alternatives considered

- **Keep the Git Bash adapter:** rejected as the long-term Windows architecture because it leaves the runtime dependency and path boundary in place.
- **Invoke all Bash through WSL:** rejected because it adds another virtualization/runtime dependency and does not provide native Windows path semantics.
- **Port only the dispatcher:** rejected because deployment and wiring behavior live in the addon scripts and shared shell functions.

## References

- [ADR-029 — Windows Feature Parity Strategy](029-windows-feature-parity.md)
- [Native PowerShell Addon Port Plan](../plans/windows-native-addon-port.md)
