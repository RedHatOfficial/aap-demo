# ADR-045: Python CLI as the Windows Default

**Status**: Accepted

**Date**: 2026-11-17

**Authors**: aap-demo maintainers

## Context

The Python CLI is the actively developed cross-platform implementation, but
Windows installation and architecture documentation still presented a native
PowerShell CLI as the default. That split entry point duplicated lifecycle
behavior and made Windows capability boundaries unclear. A full port of every
legacy command and addon is larger than the initial cutover.

Windows users need one supported default command, a clear path for features
that remain in Bash, and a reversible transition that preserves existing CRC
and user state.

## Decision

- Install the PyPI Python package through pipx as `aap-demo` on Windows.
- Keep the checkout-based Bash CLI as the explicit `aap-demo-v1` compatibility
  command. Do not silently switch Python commands to Bash.
- Keep PowerShell as the installation and Windows administration interface;
  it is not a second command implementation.
- Treat addon support by its actual handler: Fleet is native Python; the
  currently registered product demo, EDA Playground, AO, MCP Server, and Ollama
  handlers invoke bundled Bash scripts and require Git for Windows plus their
  declared tools. Unimplemented names direct users to `aap-demo-v1`.
- Migrate legacy config, kubeconfig, ingress CA, and supported credentials via
  the Python CLI's existing one-time migration. Leave hand-placed pull secrets
  in `~/.aap-demo` so both commands can find them.
- Support `install.ps1 -RollbackToV1` to uninstall the Python package and make
  `aap-demo` forward to `aap-demo-v1`. Uninstalling commands or rolling back
  must not remove cluster or user configuration state.
- Import the ingress CA into Windows Current User Root without elevation and
  verify the certificate thumbprint. Keep browser trust behavior in the Windows
  acceptance checklist because the certificate-store check alone does not
  replace end-to-end browser validation.

## Consequences

### Positive

- Windows and Unix users share the Python lifecycle implementation.
- There is one default command and a versioned, explicit compatibility path.
- Rollback does not require rebuilding CRC or redeploying AAP.

### Negative

- Some Python v2 addon handlers still require Git for Windows and Bash tools.
- The Python command does not yet replace every Bash command or addon.
- Windows-specific lifecycle, installer, credential migration, and browser
  trust behavior still need validation on Windows hosts.

### Neutral

- The legacy checkout and its state remain available during the migration.
- Python v2 uses XDG-style configuration and state directories under the user
  profile; the old command continues to use `~/.aap-demo`.

## Alternatives Considered

### Continue maintaining a separate native PowerShell CLI

Rejected because it duplicates lifecycle behavior and delays a shared Python
implementation.

### Require Git Bash for every Windows command

Rejected because the Python CLI already provides a Windows-capable core and
native Fleet implementation.

### Remove the Bash command during cutover

Rejected because some commands and addon implementations still depend on it.

## References

- [Windows Python migration guide](../reference/windows-python-migration.md)
- [Windows installer guide](../../powershell/README.md)
- [ADR-010](010-cross-platform-cli.md) (superseded)
- [ADR-015](015-ingress-ca-user-store-trust.md)
- [ADR-040](040-addon-framework-and-bash-fallback.md)
