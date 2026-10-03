# Windows Git Bash Wrapper Plan

**Branch:** `codex/git-bash-addon-wrapper`

**Goal:** Keep the PowerShell launcher as the Windows entrypoint while using the
repository's Bash CLI as the single implementation for supported commands.

## Scope

- Discover Git for Windows from standard install locations.
- Forward every supported command, positional argument, flag, and inherited
  environment value to `aap-demo.sh`.
- Preserve Bash stdout, stderr, and exit status through the PowerShell wrapper.
- Keep the Windows policy surface explicit: Product Demos is aggregate-only;
  Fleet, APME, and legacy Product Demo aliases are rejected.
- Add offline tests for discovery, quoting, environment propagation, delegation,
  exit codes, and policy enforcement.

## Implementation

1. Centralize Git Bash process execution in the native helper module.
2. Make `powershell/aap-demo.ps1` delegate before the legacy native dispatcher.
3. Keep the existing native functions available for future migration, but do not
   run them from the Windows launcher.
4. Update Windows requirements, ADRs, and troubleshooting text to make Git for
   Windows a required dependency for the wrapper.

## Validation

- Run the bridge test with arguments containing spaces and a forwarded variable.
- Run the wrapper through `version` and verify a blocked APME invocation fails.
- Run PowerShell parse/parity checks and `git diff --check`.
- Run the existing Bash unit/static tests where their host dependencies are
  available.
