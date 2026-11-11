# WSL quickstart (Windows-hosted CRC)

The recommended WSL arrangement is **CRC on Windows/Hyper-V**, with WSL as
an optional terminal/editor. Do not assume a CRC VM inside WSL is supported:
nested virtualization, networking, systemd, libvirt and storage differ from a
native RHEL/Fedora host.

This is a local development demo, not production infrastructure.

## 1. Install on the Windows side

Follow [Windows_Quickstart.md](Windows_Quickstart.md) in Windows PowerShell.
Keep CRC, the repository, pull secret, kubeconfig and the authoritative
`aap-demo` installation in the **Windows user's profile**.

For example, clone into `C:\Users\YOUR_WINDOWS_USER\source\aap-demo`, install
with `powershell\install.ps1`, and deploy from Windows PowerShell first:

```powershell
$env:CRC_MEMORY = '24576'
$env:CRC_DISK = '200'
aap-demo deploy
aap-demo status
aap-demo diagnose
```

Enable WSL using your organization's Windows procedure if it is not installed.
Running `wsl --install` from an administrator Windows terminal may install a
distribution and require a reboot. WSL is not needed by the native demo itself.

## 2. Invoke the Windows CLI from WSL

Verify Windows executable interop is enabled:

```bash
powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion'
```

From a WSL Bash terminal, define a wrapper using your actual **Windows path**:

```bash
aap-demo() {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
    'C:\Users\YOUR_WINDOWS_USER\source\aap-demo\powershell\aap-demo.ps1' "$@"
}
aap-demo status
aap-demo start
aap-demo diagnose
```

Save the function in your WSL `~/.bashrc` if wanted. For a different checkout
location, use `wslpath -w /mnt/c/Users/.../source/aap-demo` to find its Windows
path. Do not use `eval` or flatten arguments into an interpolated command string.
The function returns the Windows process exit status.

Do not run `./install.sh`, `scripts/local-prereq.sh --full`, or the Linux
systemd recovery installer inside WSL to manage this same demo. That creates
conflicting Linux state directories or tries to use a different hypervisor.

## 3. Configuration and Kubernetes access

The wrapper uses Windows `%USERPROFILE%\.aap-demo\config`, not WSL
`~/.aap-demo/config`. Set persistent values using the Windows CLI, or set
PowerShell environment variables in the same Windows invocation:

```bash
powershell.exe -NoProfile -Command \
  '$env:CRC_MEMORY="24576"; aap-demo status'
```

Use `aap-demo kubeconfig` and perform direct `oc` queries from Windows
PowerShell using the path it prints. Do not copy a kubeconfig into WSL and
assume Windows certificate/key paths and localhost routes will work there.
Use a Windows browser for the routes shown by `status`; Windows owns the CA
trust setup and CRC port forwarding.

If editing from WSL, the checkout is visible under
`/mnt/c/Users/YOUR_WINDOWS_USER/source/aap-demo`. Avoid running simultaneous
Windows and Linux deployment commands against it.

## 4. Checkpoint and resume

```bash
aap-demo service status
aap-demo service backup
aap-demo stop
aap-demo start
```

Install/manage login recovery from Windows PowerShell with the permissions
required by Hyper-V. The WSL wrapper invokes the same native implementation.
It is a **checkpoint-before-reboot, restore-at-Windows-login** workflow, not
a WSL shutdown hook. Shutting down WSL (`wsl --shutdown`) is not equivalent to
stopping CRC or checkpointing the Windows demo.

For one retained state, install with `aap-demo service install --keep 1`;
increase history with `aap-demo service retention N`. Backups contain secrets.

## Limitations and troubleshooting

- If `powershell.exe` is unavailable, check WSL Windows interop/PATH settings or
  use Windows PowerShell directly. Do not silently substitute Linux Bash.
- Git Bash addon dependencies belong on the Windows side. WSL's Bash has different
  paths, tools, credentials and network semantics.
- A WSL-only Linux systemd service cannot promise Windows Hyper-V shutdown order.
- Native PowerShell's feature limits still apply when invoked from WSL.
- Do not delete CRC/profile directories to fix a client-path error. Check
  `aap-demo status`, then `aap-demo kubeconfig` and `aap-demo diagnose`.

For a genuinely native Linux host follow [Linux_Quickstart.md](Linux_Quickstart.md);
for a Mac follow [MAC_Quickstart.md](MAC_Quickstart.md).
