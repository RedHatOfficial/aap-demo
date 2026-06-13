# aap-demo on Windows (PowerShell)

Install and run [aap-demo](../README.md) on Windows using PowerShell. Core commands
run natively in PowerShell; everything else falls back to the bash scripts via Git
Bash.

**Branch:** `feature/powershell-native` (while this work is in progress)

## Requirements

| Requirement | Notes |
|-------------|--------|
| **PowerShell 5.1+** | Built into Windows 10/11. PowerShell 7 (`pwsh`) also works. |
| **OpenShift Local (`crc`)** | [Download](https://console.redhat.com/openshift/create/local). Hyper-V enabled. |
| **OpenShift CLI (`oc`)** | Installed by `install.ps1` via winget when missing. |
| **Red Hat pull secret** | [Download](https://console.redhat.com/openshift/install/pull-secret) |
| **Git for Windows** | Installed by `install.ps1` via winget when missing. Required for `test`, `watch`, and other advanced commands (`diagnose --ai` only). |
| **OpenSSH client** | Used during `create` to configure the cluster VM (`ssh` on PATH). |

`kubectl` is **not** required on Windows for the PowerShell-native commands — they use
`oc` exclusively. Commands that fall back to Git Bash (`test`, `watch`, …)
need `kubectl` or `oc` on PATH (`aap-demo.sh` uses `oc` as a kubectl substitute when
`kubectl` is not installed).

Optional: `python`, `jq`, `ansible-playbook` (for ATF tests via bash).

## Install

### 1. Clone and checkout

```powershell
git clone https://github.com/RedHatOfficial/aap-demo.git
cd aap-demo
git checkout feature/powershell-native
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
aap-demo help
```

## Quick start

```powershell
aap-demo create        # Create OpenShift Local cluster (~10–20 min first time)
aap-demo deploy        # Deploy AAP 2.7 (~5–15 min)
aap-demo status        # Routes, credentials, pod counts; trusts ingress CA if needed
```

On first `create`, you are prompted to choose a CRC preset (MicroShift is
recommended). The choice is saved to `%USERPROFILE%\.aap-demo\config`.

After deploy, open the AAP route from `aap-demo status`. If your browser still
shows a certificate warning, run `aap-demo status` again and accept the UAC
prompt — see [Ingress CA and browser TLS](#ingress-ca-and-browser-tls) below.

## Commands

### PowerShell (no Git Bash required)

| Command | Description |
|---------|-------------|
| `aap-demo create` | Create OpenShift Local cluster (NFS, CoreDNS, OLM, metrics-server) |
| `aap-demo deploy` | Deploy AAP 2.7 operator and instance via OLM |
| `aap-demo deploy -Force` | Deploy even if an AAP CR already exists |
| `aap-demo status` | Cluster health, namespaces, routes, admin password |
| `aap-demo diagnose` | Environment health checks (cluster, storage, AAP, DNS) |
| `aap-demo help` | Show PowerShell command help |

`aap-demo diagnose --ai` delegates to Git Bash for Claude-assisted analysis.

### Git Bash fallback (requires [Git for Windows](https://git-scm.com/download/win))

Any command not listed above is forwarded to `aap-demo.sh`, including:

| Command | Description |
|---------|-------------|
| `aap-demo watch` | Monitor deployment progress |
| `aap-demo diagnose --ai` | Health checks + Claude analysis |
| `aap-demo clean` | Remove AAP deployment |
| `aap-demo destroy` | Delete cluster |
| `crc start` / `aap-demo stop` | Start or stop CRC (`start` is the `crc` command, not `aap-demo`) |
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
| `AAP_DEMO_TRUST_CA` | `true` (implicit) | Set to `false` to skip automatic ingress CA import |

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
| `%USERPROFILE%\.aap-demo\pull-secret.txt` | Red Hat pull secret |
| `%USERPROFILE%\.aap-demo\crc-ingress-ca.crt` | MicroShift ingress CA (saved for TLS trust) |
| `%USERPROFILE%\.crc\` | OpenShift Local VM data |

## Uninstall

Removes the launcher and PATH entry only — does **not** delete cluster data:

```powershell
cd path\to\aap-demo
.\powershell\install.ps1 -Uninstall
```

To remove the cluster: `aap-demo destroy` (requires Git Bash).

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

Do not move or delete the cloned repo after install — the launcher points at it.

### Git Bash required for command X

Re-run the installer (it installs Git for Windows via winget when missing), then
open a new PowerShell window:

```powershell
.\powershell\install.ps1
```

Commands like `create`, `deploy`, and `status` do not need Git Bash.

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
use a cluster-local CA. Browsers and CLI tools will warn or fail until that CA
is trusted on Windows.

#### Automatic trust

`create`, `deploy`, and `status` call **Install-AapIngressCaTrust** automatically:

1. Fetch the ingress CA from the CRC VM:
   `/var/lib/microshift/certs/ingress-ca/ca.crt`
2. Save a copy to `%USERPROFILE%\.aap-demo\crc-ingress-ca.crt`
3. Import into **Current User → Trusted Root Certification Authorities**
4. Import into **Local Machine → Trusted Root Certification Authorities**
   (requires Administrator / UAC — needed for Chrome and Edge)

When the CA is already trusted, these commands stay silent. Failures are
warnings only; `status` never aborts because of certificate import.

Skip automatic import:

```powershell
$env:AAP_DEMO_TRUST_CA = 'false'
aap-demo status
```

#### Chrome or Edge still shows a red certificate banner

1. Run `aap-demo status` and **accept the UAC prompt** when it appears.
   You should see: `Ingress CA trusted (Windows system certificate store)`.
2. **Fully quit** the browser (taskbar icon → Exit, or close every window).
   Reloading a tab is not enough — the trust store is read at startup.
3. Open the AAP URL from `aap-demo status` again.

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

During `create` / `deploy` / `status`, the saved CA path is also exported as
`CURL_CA_BUNDLE` and `SSL_CERT_FILE` for tools that read those variables.

#### Manual import

If UAC is blocked (corporate policy) or auto-trust fails:

```powershell
certutil -user -addstore Root "$env:USERPROFILE\.aap-demo\crc-ingress-ca.crt"
# Chrome/Edge also need the system store (elevated PowerShell):
certutil -addstore Root "$env:USERPROFILE\.aap-demo\crc-ingress-ca.crt"
```

Or import via **certmgr.msc** → Trusted Root Certification Authorities.

#### After cluster recreate

Destroying and recreating the cluster issues a new ingress CA. Run
`aap-demo status` (or `create` / `deploy`) again to replace the saved cert and
refresh both certificate stores.

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
```

Re-run `.\powershell\install.ps1` if `install.ps1` changed or you moved the repo.
