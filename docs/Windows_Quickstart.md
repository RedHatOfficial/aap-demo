# Windows quickstart (native PowerShell)

aap-demo is for local development only. Use the **native PowerShell CLI**;
do not run the Linux bootstrap in Git Bash or try to put CRC inside WSL.

## 1. Prepare Windows

- Use a CRC-supported Windows edition with **Hyper-V**, hardware virtualization,
  and sufficient free RAM/disk. Typical hosts need Windows Pro/Enterprise, not
  Home. Follow [OpenShift Local's requirements](https://console.redhat.com/openshift/create/local).
- Allocate at least 8 CPUs / 16 GiB to CRC; prefer 24 GiB for an addon-heavy
  demo and 32+ GiB of physical host RAM.
- Install PowerShell 5.1+ (Windows PowerShell is built in), Git for Windows,
  CRC for Windows, and the Windows OpenSSH client.
- Enable Hyper-V using Windows Features in an administrator session, then reboot
  if Windows requests it. Run CRC's host setup as directed by its installer.
- Git Bash is needed for addons that delegate to Bash.
  WSL's `bash.exe` is **not an interchangeable replacement** for Git Bash.
  `diagnose --ai` requires the Bash/Linux CLI; it is not a native PowerShell command.

From PowerShell:

```powershell
git clone https://github.com/ShaddGallegos/aap-demo.git
Set-Location aap-demo
New-Item -ItemType Directory -Force "$env:USERPROFILE\.aap-demo" | Out-Null
Copy-Item "$env:USERPROFILE\Downloads\pull-secret.txt" `
  "$env:USERPROFILE\.aap-demo\pull-secret.txt"
.\powershell\install.ps1
```

Download the personal [pull secret](https://console.redhat.com/openshift/install/pull-secret)
first; do not commit it. The installer checks CRC and installs `oc` via winget
when available. If execution policy blocks the installer, review the source and
run it with a **process-scoped**, not machine-wide, override:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\powershell\install.ps1
```

Open a new PowerShell window after installation. Do not move the repository.
The repository's Git attributes keep shell scripts LF-terminated for Git Bash.
If using an older checkout with CRLF shell errors, use a fresh clone rather
than changing machine-wide Git settings or mass-rewriting a dirty checkout.

## 2. Configure and deploy

```powershell
crc config set preset microshift
crc setup
$env:CRC_MEMORY = '24576'
$env:CRC_DISK = '200'
aap-demo create
aap-demo deploy
aap-demo status
aap-demo diagnose
aap-demo status --show-secrets
aap-demo kubeconfig
```

Settings live in `%USERPROFILE%\.aap-demo\config`. Environment variables override
saved values. Unlike Bash, use `$env:NAME = 'value'`, not `NAME=value command`.
`oc` is sufficient for the native CLI; `kubectl` is optional. Follow the
kubeconfig command's reported path for direct Kubernetes queries.

Open the route printed by `status`. For browser CA trust problems run
`aap-demo repair` from an elevated PowerShell, then fully restart the browser.
Do not disable TLS verification globally.

```powershell
aap-demo enable
aap-demo enable mcp-server
aap-demo stop
aap-demo start
aap-demo restart
```

Native startup resumes existing workloads instead of recreating AAP. Readiness
or image-pull failures must be resolved rather than treated as a successful start.
Allow sufficient time on slower Windows storage.

Startup also implements the **90%-used / 20%-growth** CRC storage policy, rounded
up to whole GiB using actual disk capacity. It checks host space, persists one
resize target, stops CRC gracefully, restarts it, and verifies disk/filesystem
growth before clearing the target. Failed retries use the same target. Missing
driver capacity metadata fails explicitly at resize time. This implementation
is mock-tested; actual Hyper-V/guest expansion still needs native validation.

## 3. Optional explicit checkpoint and login recovery

```powershell
aap-demo service install --keep 1
aap-demo service retention 3
aap-demo service backup
aap-demo service backups
aap-demo service status
aap-demo stop
```

The native recovery integration uses a **current-user login scheduled task**
named `aap-demo-login-restore`, not Linux systemd. It runs with limited rights
and no stored password. The installing user must belong to **Hyper-V
Administrators** and be able to inspect the VM/disks with that limited token.
An administrator may need to grant group membership first, followed by sign-out
and sign-in. Running installation elevated alone is not a substitute for
granting the login task the required access.

The existing Hyper-V VM must retain the **same VMId and configuration** and its
CRC bundle cache must remain present. Hyper-V VM definitions and bundle cache
are not reconstructed by this checkpoint mechanism. Saved/paused VMs,
differencing disks, pass-through disks and Hyper-V checkpoints are refused.
This is recovery of the same existing VM, not a complete disaster-recovery VM
export. Follow any access/layout errors before relying on it.

Checkpoint with `aap-demo stop` or `aap-demo service backup` **before restarting
Windows**. Task Scheduler does not guarantee completion of a large cold backup
during Windows shutdown. Automatic recovery happens when the installing user
logs in, not before login. Recovery intentionally uses the last completed state;
changes since it may be lost after an uncoordinated reboot.

Only one completed state is kept unless retention is increased. Checkpoints
live under `%LOCALAPPDATA%\aap-demo\state\backups\`; service state, the latest
pointer, logs and restore journal are alongside them. Files use the Windows
profile's account ACLs. Backups contain keys/credentials and are not independently
encrypted; use account ACLs and BitLocker. Allow roughly 1.1 times the managed
disk footprint for a new checkpoint and similar free space for restore staging.
The checksum manifest and completion marker distinguish completed backups.
Use `aap-demo service verify` to verify the latest checkpoint explicitly.
Read the
[native recovery details](docs/state-service.md#macos-and-windows-login-recovery)
for current layout limitations and storage locations.

Disable managed recovery before rebuilding or deleting the demo:

```powershell
aap-demo service disable
```

## Platform limits

- Native PowerShell does not yet implement every Bash addon/Fleet command.
  `create --full-demo` is a Linux/Bash workflow, not native Windows parity.
- MCP Server and portal have native paths. Other addon paths may invoke Bash and
  require Unix tools, compatible paths and matching images. Consult
  [the PowerShell guide](powershell/README.md) and each addon README.
- Linux's separate libvirt persistent image disk and its systemd shutdown service
  do not run on Windows. Do not copy Linux `sudo`/`virsh` instructions.
- Windows ARM, arbitrary external disks, network shares and nested virtualization
  are not implied supported by a successful CLI installation.
- Native Windows/Hyper-V recovery needs real Windows lifecycle validation;
  mock tests and CI parsing do not establish that validation.

For WSL terminals use [WSL_Quickstart.md](WSL_Quickstart.md). For other hosts see
[Linux](Linux_Quickstart.md) and [macOS](MAC_Quickstart.md).
