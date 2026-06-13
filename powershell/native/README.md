# PowerShell module (Windows)

PowerShell implementation of core aap-demo commands on Windows. Installed via
`.\powershell\install.ps1` as the `aap-demo` command.

## Commands

| Command | Runtime |
|---------|---------|
| `create`, `deploy`, `status`, `diagnose`, `help` | PowerShell |
| `diagnose --ai`, `test`, `watch`, `clean`, `destroy`, `enable`, … | Git Bash → `aap-demo.sh` |

## Layout

```
powershell/
  aap-demo.ps1           # CLI router (PowerShell + bash fallback)
  install.ps1
  native/
    AapDemo.psm1
    Private/
      Helpers.ps1
      Create.ps1
      Deploy.ps1
      Status.ps1
      Diagnose.ps1
```

## Install

```powershell
.\powershell\install.ps1
```

## Gaps vs bash (in progress)

- No `watch`, `must-gather`, `test`, addons in PowerShell yet
- No ingress CA auto-trust on Windows
- No podman remote connection setup
- Simpler deploy (no gateway capability patch loop)

Use `aap-demo <command>` for unsupported commands — routes to bash automatically
when Git for Windows is installed.
