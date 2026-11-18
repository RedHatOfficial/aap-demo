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
command. It also registers the repository Bash CLI as `aap-demo-v1`, so a
feature that has not moved can still be run explicitly. See the
[Windows install guide](../../powershell/README.md) for prerequisites and
commands.

## What runs where

| Capability | Windows implementation | Requirements |
| --- | --- | --- |
| Core cluster lifecycle and diagnostics | Python v2 (`aap-demo`) | Python 3.9+, pipx, CRC, and `oc` |
| Fleet addon | Python v2 | Python/CRC prerequisites |
| Product Demos, EDA Playground, AO, MCP Server, Ollama | Python v2 handler calling bundled Bash scripts | Git for Windows; each handler's declared tools such as `bash`, `curl`, `jq`, and `kubectl` |
| Commands/addons not implemented in Python v2 | Bash v1 (`aap-demo-v1`) | Registered aap-demo repository checkout and Git for Windows |

Python v2 reports its implemented addons with `aap-demo enable` and names the
v1 command for unsupported addons. It does not silently route an entire
command to Bash.

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
layout. The migration is resumable. Credentials move to the OS credential
store when a backend is available; if import cannot run, Python leaves the
source file and reports the recovery step. Hand-placed pull secrets stay in
`%USERPROFILE%\.aap-demo` for both commands. The migration does not delete the
legacy directory, CRC VM, or cluster.

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
   supported Windows PowerShell versions.
2. Verify create/start/stop/status/diagnose and kubeconfig behavior against an
   existing CRC cluster without redeploying it.
3. Verify Current User Root import and AAP route trust in Chrome, Edge, and
   Firefox; test a recreated cluster to ensure stale CA behavior is understood.
4. Publish an addon capability matrix from the registry and port remaining
   supported Windows addons incrementally, with native Python ownership where
   parity and maintenance cost justify it.
5. Add clean Windows and packaged-PyPI smoke coverage before calling the
   migration complete. Destructive lifecycle tests remain opt-in.
