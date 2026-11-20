# aap-demo on Windows (PowerShell)

Install and run [aap-demo](../README.md) on Windows using the Python package from
PyPI. The legacy repository Bash implementation remains available as
`aap-demo-v1` for commands that have not moved to Python yet.

## Requirements

| Requirement                 | Notes                                                                           |
| --------------------------- | ------------------------------------------------------------------------------- |
| **PowerShell 5.1+**         | Built into Windows 10/11. PowerShell 7 (`pwsh`) also works.                     |
| **OpenShift Local (`crc`)** | [Download](https://console.redhat.com/openshift/create/local). Hyper-V enabled. |
| **OpenShift CLI (`oc`)**    | Installed by Python setup via winget when missing.                              |
| **Red Hat pull secret**     | [Download](https://console.redhat.com/openshift/install/pull-secret)            |
| **Python 3.11+**            | Required by current pipx; the installer bootstraps Python, then setup installs pipx. |
| **Git for Windows**         | Required by `aap-demo-v1` and Python v2 addons whose installers still use Bash. |
| **OpenSSH client**          | Used during `create` to configure the cluster VM (`ssh` on PATH).               |

The aap-demo package itself supports Python 3.9+, but the Windows installer
requires Python 3.11+ because current pipx releases need that runtime.

Some Python v2 addon installers still run their bundled Bash scripts through
Git for Windows. Those commands also require `jq`; Python provisions AAP demo
content and imports AO demo workflows. The Python CLI remains the command
entrypoint, while `aap-demo-v1` is the separate legacy Bash CLI.

## Install

### 1. Clone the repository

```powershell
git clone https://github.com/RedHatOfficial/aap-demo.git
cd aap-demo
```

### 2. Copy pull secret

Download from the [Red Hat console](https://console.redhat.com/openshift/install/pull-secret),
then copy it into place:

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.aap-demo" | Out-Null
Copy-Item "$env:USERPROFILE\Downloads\pull-secret.txt" "$env:USERPROFILE\.aap-demo\pull-secret.txt"
```

Adjust the source path if your browser saved the file elsewhere or under a different name.

### 3. Run installer

```powershell
.\powershell\install.ps1
```

Open a **new** PowerShell window when install finishes, then:

```powershell
aap-demo --help
aap-demo-v1 --help
```

The PowerShell script only locates or bootstraps Python and starts the Python
setup module. Python setup installs `aap-demo` from PyPI through pipx, installs
`oc` with winget when it is missing, and registers the legacy Bash checkout as
`aap-demo-v1` in `%USERPROFILE%\.local\bin`. If a previous install left a stale
PowerShell wrapper, rerun the installer with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\powershell\install.ps1
```

For shell-backed addons such as Product Demos, EDA Playground, MCP Server, and
Ollama, install Git for Windows and the external tools each addon needs. The
installer reports missing optional tools but does not install them. Install
`jq` and a Python runtime for Product Demos when they are not already
available:

```powershell
winget install --id jqlang.jq -e --source winget
winget install --id Python.Python.3.12 -e --source winget
```

Python is used by AAP demo provisioning and AO workflow import steps. Those
addon commands stop with an actionable missing-tool message instead of silently
skipping demo content.

## Quick start

```powershell
aap-demo create        # Python CLI: create OpenShift Local cluster
aap-demo deploy        # Python CLI: deploy AAP 2.7
aap-demo status        # Python CLI: routes, credentials, pod counts
aap-demo-v1 status     # Legacy Bash compatibility path
```

`aap-demo create` asks for CPUs, memory, disk size, and persistent-volume size.
Those values are saved to
`%USERPROFILE%\.config\aap-demo\config.yaml`. Change the disk later with
`aap-demo storage`. An existing VM keeps its current disk until
`aap-demo destroy` and `aap-demo create`.

After deploy, open the AAP route from `aap-demo status`. If your browser shows a
certificate warning, run `aap-demo trust-ca` — see
[Ingress CA and browser TLS](#ingress-ca-and-browser-tls) below.

## Commands

All commands run in PowerShell. Run `aap-demo help` for the full list.

| Command                        | Description                                                        |
| ------------------------------ | ------------------------------------------------------------------ |
| `aap-demo create`              | Create OpenShift Local cluster (NFS, CoreDNS, OLM, metrics-server) |
| `aap-demo storage`             | Show or change the VM disk and persistent-volume size              |
| `aap-demo storage 160 100`     | Set a 160GB disk and a 100GB persistent-volume pool                |
| `aap-demo deploy`              | Deploy AAP 2.7 operator and instance via OLM                       |
| `aap-demo deploy --force`      | Deploy even if an AAP CR already exists                             |
| `aap-demo redeploy`            | Clean namespace and redeploy AAP                                   |
| `aap-demo redeploy-all`        | Destroy cluster and full redeploy                                  |
| `aap-demo clean`               | Remove AAP deployment                                              |
| `aap-demo destroy`             | Delete CRC cluster (`--reset` clears saved preset)                 |
| `aap-demo stop`                | Stop CRC cluster                                                   |
| `aap-demo start`               | Start CRC and refresh MicroShift DNS                               |
| `aap-demo trust-ca`            | Repair ingress certificate trust without repairing cluster           |
| `aap-demo status`              | Cluster health, namespaces, routes, admin password                 |
| `aap-demo diagnose`            | Environment health checks                                          |
| `aap-demo watch`               | Monitor AAP deployment until Successful                            |
| `aap-demo idle true` / `false` | Scale AAP down/up                                                  |
| `aap-demo kubeconfig`          | Sync kubeconfig (context: `aap-demo`)                              |
| `aap-demo ssh`                 | SSH into CRC VM                                                    |
| `aap-demo enable` / `disable`  | Enable or disable addons                                           |
| `aap-demo wire`                | Apply addon integrations after deployment                          |
| `aap-demo must-gather`         | Collect diagnostic bundle                                          |
| `aap-demo redhat-status`       | Check Red Hat registry status                                      |
| `aap-demo config`              | Show or set Python CLI configuration                               |
| `aap-demo update`              | Upgrade the pipx-installed Python package                          |
| `aap-demo help`                | Show command help                                                  |

Python v2 currently lists `fleet`, `product-demos`, `product-demo-satellite`,
`eda-playground`, `ao`, `mcp-server`, `ollama`, and `opa`. Fleet, AO, and OPA
use native Python handlers. Product Demos, EDA Playground, MCP Server, and
Ollama use bundled Bash installers launched by Python and need Git for
Windows; `aap-demo-v1` remains the separate legacy CLI for commands not yet
implemented in Python.

## Environment variables

Set in PowerShell before running commands, or use `aap-demo config` to save
non-secret settings in `%USERPROFILE%\.config\aap-demo\config.yaml`. Credential
values must not be stored in the shared config file; use the OS credential
store or the documented secret file/environment-variable interface for the
specific addon.

| Variable            | Default                                      | Description                                        |
| ------------------- | -------------------------------------------- | -------------------------------------------------- |
| `CRC_CPUS`          | `8`                                          | VM CPU count                                       |
| `CRC_MEMORY`        | `16384`                                      | VM memory (MiB)                                    |
| `CRC_DISK`          | `120`                                        | VM disk (GiB). Minimum 31. Prompted on create      |
| `CRC_PV_SIZE`       | `70`                                         | Persistent-volume pool (GiB). Minimum 15 and `< CRC_DISK` |
| `NFS_BACKING_STORAGE_SIZE` | `5Gi`                                  | LVMS-backed storage reserved for the NFS server      |
| `NAMESPACE`         | `aap-operator`                               | Kubernetes namespace                               |
| `QUIET`             | `false`                                      | Suppress interactive prompts                       |
| `KUBECONFIG`        | Python-managed kubeconfig under `%USERPROFILE%\.local\state\aap-demo` | Cluster kubeconfig                  |
| `AAP_DEMO_TRUST_CA` | `true` (implicit)                            | Set to `false` to skip automatic ingress CA import |
| `AO_LLM_PROVIDER`    | `ollama` when unset                           | AO provider: `ollama`, `external`, or `none`      |
| `AO_LLM_BASE_URL`    | `https://api.openai.com/v1` for `external`     | External LLM API base URL                         |
| `AO_LLM_MODEL`       | `gpt-6-luna` for `external`                   | External LLM model; `luna` is an alias            |
| `AO_LLM_API_KEY`     | unset                                         | External provider key; saved under Python state, never in shared config |
| `GALAXY_TOKEN_FILE`  | `%USERPROFILE%\.aap-demo\galaxy-token`      | Red Hat Galaxy/Automation Hub offline token file  |
| `PAH_CONFIG_FILE`    | `%USERPROFILE%\.aap-demo\pah-config.yml`    | Private Automation Hub URL and credentials        |

Example:

```powershell
$env:CRC_MEMORY = 20480
$env:NAMESPACE = 'aap-operator'
aap-demo create
```

### Addon configuration and credentials

Python v2 reads non-secret settings from process environment variables or
`config.yaml`. Do not put passwords, API keys, or tokens in that shared file or
on a command line. AO keeps its external API key in
`%USERPROFILE%\.local\state\aap-demo\addons\ao\llm-api-key` and can import
the prior `%USERPROFILE%\.aap-demo\ao\llm-api-key` file. Some listed addons
use bundled Bash installers; the Python CLI supplies their kubeconfig and
required environment. For addons not listed above, use the explicit
`aap-demo-v1` compatibility command.

`aap-demo start` restores the cluster kubeconfig and MicroShift DNS state.
`aap-demo trust-ca` fetches the current ingress CA and updates Windows trust
without repairing or redeploying the cluster.

## File locations

| Path                                                       | Purpose                                      |
| ---------------------------------------------------------- | -------------------------------------------- |
| `%USERPROFILE%\.config\aap-demo\config.yaml`              | Python v2 configuration                      |
| `%USERPROFILE%\.local\state\aap-demo\`                    | Python v2 kubeconfig and runtime state        |
| `%USERPROFILE%\.local\state\aap-demo\certs\crc-ingress-ca.crt` | Ingress CA saved by Python v2         |
| `%USERPROFILE%\.aap-demo\`                                 | Legacy files and the v1 checkout marker       |
| `%USERPROFILE%\.crc\`                                      | OpenShift Local VM data                       |

## Roll back to Bash v1

If a Windows issue blocks the Python CLI, restore the Bash implementation as
the default command:

```powershell
.\powershell\install.ps1 -RollbackToV1
```

This keeps `aap-demo-v1`, makes `aap-demo` forward to that command, and removes
the pipx Python package. It does not change the existing cluster or files under
`%USERPROFILE%\.aap-demo`. Re-run `install.ps1` later to restore Python v2 as
the default.

## Uninstall

Removes the pipx package and both launchers. It removes `%USERPROFILE%\.local\bin`
from PATH only when this installer originally added it. It does **not** delete
cluster or configuration data:

```powershell
cd path\to\aap-demo
.\powershell\install.ps1 -Uninstall
```

To remove the cluster: `aap-demo destroy`

## Troubleshooting

### `aap-demo` is not recognized

Re-run the installer and open a **new** PowerShell window:

```powershell
.\powershell\install.ps1
```

### `aap-demo is not installed` / repo path error

Re-run from the repo directory:

```powershell
.\powershell\install.ps1
```

Do not move or delete the cloned repo after install if you use `aap-demo-v1` or
rollback to it; those launchers point at the checkout. The pipx Python `aap-demo`
command is installed independently.

### Git Bash addon requirements

The Python CLI is the default command. Some addon handlers still run their
bundled Bash installers, so install Git for Windows and make `bash`, `curl`, and
`jq` available on `PATH` before using those addons. `aap-demo-v1` runs the
legacy Bash CLI directly for commands that have not moved to Python.

### `oc` or `crc` not found

Re-run the installer from the repo directory (it installs `oc` via winget when
possible and reports any missing prerequisites):

```powershell
.\powershell\install.ps1
```

### `crc start` or Hyper-V errors

- Enable Hyper-V (Windows Pro/Enterprise) or use WSL2 backend per OpenShift Local docs
- Run OpenShift Local setup from the Red Hat console installer first

### Ingress CA and browser TLS

MicroShift routes (for example `https://aap-aap-operator.apps.127.0.0.1.nip.io`)
use a cluster-local CA. Python v2 saves it to
`%USERPROFILE%\.local\state\aap-demo\certs\crc-ingress-ca.crt` and imports it
into **Current User → Trusted Root Certification Authorities** through Windows
CryptoAPI. This user-store import does not require an elevated PowerShell
window.

`aap-demo create`, `deploy`, and `trust-ca` perform the trust step when the CA is
available. The command checks that the current certificate is present before
reporting trust. To skip automatic import for a locked-down environment:

```powershell
$env:AAP_DEMO_TRUST_CA = 'false'
aap-demo deploy
```

If Chrome or Edge still shows a certificate warning after `aap-demo status`
reports `trusted (Windows Current User Root)`:

1. Fully quit the browser, then reopen it; reloading a tab does not reload the
   certificate store.
2. Run `aap-demo trust-ca` and confirm it reports the current CA as trusted.
3. Open the AAP URL printed by `aap-demo status` again.

If you opened the route **before** the CA was trusted, clear cached security
state for the nip.io domain:

1. Open `chrome://net-internals/#hsts` (or the Edge equivalent).
2. Under **Delete domain security policies**, enter `127.0.0.1.nip.io`.
3. Click **Delete**, then reload the AAP URL.

#### curl and PowerShell on Windows

PowerShell (`Invoke-WebRequest`) and .NET use the Windows certificate stores and
should work once the CA is imported.

Windows `curl.exe` uses Schannel and may fail with a revocation-check error even
when the CA is trusted:

```text
CRYPT_E_NO_REVOCATION_CHECK — The revocation function was unable to check revocation
```

Use `--ssl-no-revoke` for local CRC routes:

```powershell
curl.exe --ssl-no-revoke -I https://aap-aap-operator.apps.127.0.0.1.nip.io
```

#### Manual import

If automatic trust fails (for example corporate policy blocks store writes),
the Windows certificate manager can import the saved file manually. A command
line fallback is also available:

```powershell
certutil.exe -user -addstore Root "$env:USERPROFILE\.local\state\aap-demo\certs\crc-ingress-ca.crt"
```

Or import the same file through **certmgr.msc** → Current User → Trusted Root
Certification Authorities.

#### After cluster recreate

Destroying and recreating the cluster issues a new ingress CA. Run
`aap-demo trust-ca` after the new cluster is ready to replace the saved CA and
refresh the Current User store.

### PowerShell vs PowerShell 7

Scripts require **PowerShell 5.1+**. If `deploy` fails on encoding errors under
Windows PowerShell 5.1, install PowerShell 7:

```powershell
winget install Microsoft.PowerShell
```

Then run commands with `pwsh` instead of `powershell`.

## How it works

```
aap-demo (pipx Python console script in ~/.local/bin)
  └── Python v2 CLI
        ├── Python command and lifecycle handlers
        └── selected addon installers → bundled Bash scripts via Git for Windows

aap-demo-v1.cmd
  └── Git for Windows bash.exe → repository aap-demo.sh
```

## Updating

```powershell
aap-demo update
```

Or manually:

```powershell
pipx upgrade aap-demo
```

Re-run `.\powershell\install.ps1` if the installer changed or you moved the
repository used by `aap-demo-v1`.
