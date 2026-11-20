---
type: Reference
title: Windows Python migration
description: Windows Python v2 command, state migration, capability boundaries, and rollback.
tags: [windows, python, migration, compatibility]
status: draft
stale_after: 2027-05-17
resource: https://github.com/RedHatOfficial/aap-demo
---

# Windows Python migration

The PowerShell installer makes the PyPI Python CLI the default `aap-demo`
command and registers the repository Bash CLI as `aap-demo-v1` as a temporary
compatibility path. Its script only locates or bootstraps Python; the Python
setup module installs `aap-demo` through pipx and manages prerequisites and
launchers. The migration target is native Python
implementations for every supported Windows command and addon, followed by a
PowerShell bootstrap that only starts Python and hands off all setup work to
Python.
See the [Windows install guide](../../powershell/README.md) for the current
transition setup.

## What runs where

| Capability | Windows implementation | Requirements |
| --- | --- | --- |
| Core cluster lifecycle and diagnostics | Python v2 (`aap-demo`) | Python 3.11+, pipx, CRC, and `oc` |
| Fleet addon | Python v2 | Python/CRC prerequisites |
| Automation Orchestrator and OPA addons | Native Python v2 handlers | Cluster access and addon configuration; AO also enables MCP Server and usually Ollama through Git Bash handlers |
| Product Demos, EDA Playground, MCP Server, Ollama | Python v2 handler calling bundled Bash scripts | Git for Windows; each handler's declared tools such as `bash`, `curl`, and `jq`; `oc` supplies kubectl compatibility when needed |
| Commands/addons not implemented in Python v2 | Bash v1 (`aap-demo-v1`) | Registered aap-demo repository checkout and Git for Windows |

During the transition, Python v2 reports its implemented addons with
`aap-demo enable` and names the v1 command for unsupported addons. It does not
silently route an entire command to Bash.

## Target Windows runtime

All supported Windows commands and addons will have native Python owners.
Python command and addon implementations will not launch bundled Bash scripts,
and users will not need Git for Windows to run them. Features that are not
supported on Windows will fail clearly rather than falling back to the v1
command.

PowerShell will only locate or bootstrap Python and invoke Python setup
tooling. Python will own pipx installation and use pipx to install, upgrade,
and uninstall `aap-demo`. Python setup tooling will also own prerequisite
checks, launchers, user data, and product commands. Once command and addon
parity is accepted, Windows setup will stop registering `aap-demo-v1` and
remove the PowerShell native CLI.

## State and first-run migration

Python v2 uses XDG-style paths under `%USERPROFILE%` by default:

| Data | Python v2 location |
| --- | --- |
| Configuration | `%USERPROFILE%\.config\aap-demo\config.yaml` |
| Kubeconfig and runtime state | `%USERPROFILE%\.local\state\aap-demo\` |
| Ingress CA | `%USERPROFILE%\.local\state\aap-demo\certs\crc-ingress-ca.crt` |
| Legacy Bash state | `%USERPROFILE%\.aap-demo\` |
| CRC VM data | `%USERPROFILE%\.crc\` |

The first Python command checks for legacy `~/.aap-demo` state and migrates
supported settings, kubeconfig, certificates, and credentials into the Python
layout. The migration is resumable. While `aap-demo-v1` remains available on
Windows, state files are copied and credential files are imported into the OS
credential store without deleting their legacy sources. This keeps v1 and
rollback able to read the original files. Hand-placed pull secrets stay in
`%USERPROFILE%\.aap-demo` for both commands. The migration does not delete the
legacy directory, CRC VM, or cluster.

## Release dependency

The Windows bootstrap installs the published `aap-demo` package from PyPI.
Before directing Windows users to this cutover, publish a package containing
the migration and trust changes, then verify a clean Windows install receives
that build. Changes present only on the installer branch are not included in
the package users install.

## Roll back or uninstall

From the repository checkout, restore Bash v1 as the default command with:

```powershell
.\powershell\install.ps1 -RollbackToV1
```

This removes the pipx Python package, retains `aap-demo-v1`, and makes
`aap-demo` forward to it. It leaves CRC and user state in place. Run
`install.ps1` again to reinstall Python v2 as the default.

To remove the Python package and launchers without deleting state:

```powershell
.\powershell\install.ps1 -Uninstall
```

## Remaining migration work

1. Validate install, upgrade, PATH resolution, rollback, and uninstall on
   supported Windows PowerShell versions during the transition.
2. Verify create/start/stop/status/diagnose and kubeconfig behavior against an
   existing CRC cluster without redeploying it.
3. Verify Current User Root import and AAP route trust in Chrome, Edge, and
   Firefox; test a recreated cluster to ensure stale CA behavior is understood.
4. Inventory the supported v1 Windows commands and addons, then port each to
   native Python. Replace shell-backed addon handlers and maintain the
   capability matrix from the Python registries.
5. Run the complete supported Windows command/addon workflow on a clean system
   without Git for Windows. Keep cluster-destroying tests opt-in for routine CI.
6. After parity is accepted, remove the Windows v1 launcher and PowerShell
   native CLI; Python setup already owns pipx setup and management of
   `aap-demo`, prerequisite handling, launchers, rollback, and uninstall.
7. Add clean Windows and packaged-PyPI checks and publish the supported
   Windows/Python/CRC combination with each release.
