# aap-demo on Windows (PowerShell)

Install and run [aap-demo](../README.md) on Windows using PowerShell. Core commands
run natively in PowerShell; everything else falls back to the bash scripts via Git
Bash.

**Branch:** `feature/powershell-native` (while this work is in progress)

## Requirements

| Requirement | Notes |
|-------------|--------|
| **PowerShell 5.1+** | Built into Windows 10/11. PowerShell 7 (`pwsh`) also works. |
| **OpenShift Local** | [Download](https://console.redhat.com/openshift/create/local). Hyper-V enabled. |
| **`kubectl`** | Bundled with OpenShift Local, or install separately. |
| **Red Hat pull secret** | [Download](https://console.redhat.com/openshift/install/pull-secret) |
| **Git for Windows** | Optional for `create` / `deploy` / `status`. Required for `diagnose`, `test`, `watch`, and other advanced commands. |
| **OpenSSH client** | Used during `create` to configure the cluster VM (`ssh` on PATH). |

Optional: `operator-sdk` (installer downloads it if missing), `python`, `jq`,
`ansible-playbook` (for ATF tests via bash).

### Install Git Bash (winget)

Required for advanced commands (`diagnose`, `test`, `watch`, `destroy`, …):

```powershell
winget install --id Git.Git -e --source winget
```

Open a new PowerShell window after install so `bash` is on PATH.

## Install

### 1. Clone and checkout

```powershell
git clone https://github.com/RedHatOfficial/aap-demo.git
cd aap-demo
git checkout feature/powershell-native
```

### 2. Save pull secret

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.aap-demo"
Copy-Item "$env:USERPROFILE\Downloads\pull-secret.txt" "$env:USERPROFILE\.aap-demo\pull-secret.txt"
```

### 3. Run installer

```powershell
.\powershell\install.ps1
```

The installer will:

- Verify `crc` and `kubectl` are on PATH
- Record the repo path in `%USERPROFILE%\.aap-demo\repo-path`
- Install an `aap-demo` launcher to `%USERPROFILE%\.local\bin`
- Add `%USERPROFILE%\.local\bin` to your user PATH
- Download `operator-sdk.exe` when not already installed

### 4. Open a new PowerShell window

PATH changes apply only in new sessions.

```powershell
aap-demo help
```

## Quick start

```powershell
aap-demo create        # Create OpenShift Local cluster (~10–20 min first time)
aap-demo deploy        # Deploy AAP 2.7 (~5–15 min)
aap-demo status        # Routes, credentials, pod counts
```

On first `create`, you are prompted to choose a CRC preset (MicroShift is
recommended). The choice is saved to `%USERPROFILE%\.aap-demo\config`.

## Commands

### PowerShell (no Git Bash required)

| Command | Description |
|---------|-------------|
| `aap-demo create` | Create OpenShift Local cluster (NFS, CoreDNS, OLM, metrics-server) |
| `aap-demo deploy` | Deploy AAP 2.7 operator and instance via OLM |
| `aap-demo deploy -Force` | Deploy even if an AAP CR already exists |
| `aap-demo status` | Cluster health, namespaces, routes, admin password |
| `aap-demo help` | Show PowerShell command help |

### Git Bash fallback (requires [Git for Windows](https://git-scm.com/download/win))

Any command not listed above is forwarded to `aap-demo.sh`, including:

| Command | Description |
|---------|-------------|
| `aap-demo watch` | Monitor deployment progress |
| `aap-demo diagnose` | Health checks |
| `aap-demo diagnose --ai` | Health checks + Claude analysis |
| `aap-demo clean` | Remove AAP deployment |
| `aap-demo destroy` | Delete cluster |
| `aap-demo start` / `stop` | Start or stop CRC |
| `aap-demo idle true` / `false` | Scale AAP down/up |
| `aap-demo enable mcp-server` | Enable addons |
| `aap-demo test` | Run ATF tests |
| `aap-demo must-gather` | Collect diagnostics |

Run `aap-demo help` in Git Bash context for the full list: use any bash-only
command name — the router delegates automatically.

## Environment variables

Set in PowerShell before running commands, or add to
`%USERPROFILE%\.aap-demo\config` as `KEY=value` lines.

| Variable | Default | Description |
|----------|---------|-------------|
| `CRC_CPUS` | `8` | VM CPU count |
| `CRC_MEMORY` | `16384` | VM memory (MiB) |
| `CRC_DISK` | `100` | VM disk (GiB) |
| `CRC_PV_SIZE` | `50` | Storage for PVCs (GiB) |
| `NAMESPACE` | `aap-operator` | Kubernetes namespace |
| `QUIET` | `false` | Suppress interactive prompts |
| `KUBECONFIG` | `%USERPROFILE%\.crc\machines\crc\kubeconfig` | Cluster kubeconfig |

Example:

```powershell
$env:CRC_MEMORY = 20480
$env:NAMESPACE = 'aap-operator'
aap-demo create
```

## File locations

| Path | Purpose |
|------|---------|
| `%USERPROFILE%\.aap-demo\config` | Saved preset, addons, preferences |
| `%USERPROFILE%\.aap-demo\repo-path` | Path to cloned aap-demo repo |
| `%USERPROFILE%\.aap-demo\pull-secret.txt` | Red Hat pull secret |
| `%USERPROFILE%\.crc\` | OpenShift Local VM data |
| `%USERPROFILE%\.local\bin\aap-demo.ps1` | Installed launcher |

## Uninstall

Removes the launcher and PATH entry only — does **not** delete cluster data:

```powershell
cd path\to\aap-demo
.\powershell\install.ps1 -Uninstall
```

To remove the cluster: `aap-demo destroy` (requires Git Bash).

## Troubleshooting

### `aap-demo` is not recognized

1. Confirm install completed: `Test-Path "$env:USERPROFILE\.local\bin\aap-demo.ps1"`
2. Confirm PATH: `[Environment]::GetEnvironmentVariable('Path','User')` contains `.local\bin`
3. Open a **new** PowerShell window

### `aap-demo is not installed` / repo path error

Re-run from the repo directory:

```powershell
.\powershell\install.ps1
```

Do not move or delete the cloned repo after install — the launcher points at it.

### Git Bash required for command X

Install Git for Windows, then retry:

```powershell
winget install --id Git.Git -e --source winget
```

Or download from [git-scm.com](https://git-scm.com/download/win). Commands like
`create`, `deploy`, and `status` do not need Git Bash.

### `crc start` or Hyper-V errors

- Enable Hyper-V (Windows Pro/Enterprise) or use WSL2 backend per OpenShift Local docs
- Run OpenShift Local setup from the Red Hat console installer first

### Browser TLS warnings

Ingress CA auto-trust is not configured on Windows yet. Accept the certificate
warning or import the CA from the cluster manually.

### PowerShell vs PowerShell 7

Scripts require **PowerShell 5.1+**. If `deploy` fails on encoding errors under
Windows PowerShell 5.1, install PowerShell 7:

```powershell
winget install Microsoft.PowerShell
```

Then run commands with `pwsh` instead of `powershell`.

## How it works

```
aap-demo (launcher in ~/.local/bin)
  └── powershell/aap-demo.ps1
        ├── create, deploy, status  →  powershell/native/AapDemo.psm1
        └── everything else         →  aap-demo.sh via Git Bash
```

See [native/README.md](native/README.md) for module layout and known gaps vs the
bash implementation.

## Updating

```powershell
cd path\to\aap-demo
git pull
# No reinstall needed unless install.ps1 changed
```

If you move the repo to a new path, re-run `.\powershell\install.ps1`.
