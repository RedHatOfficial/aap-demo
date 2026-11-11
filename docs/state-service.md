# Shutdown backups and boot recovery

The `aap-demo.service` system service resumes the latest local CRC disks and
configuration in place and brings the demo online at boot. It also saves a cold
backup on graceful host shutdown. Automatic startup never replaces current data
with an older checkpoint, even if shutdown was interrupted.

This shutdown/boot feature is for **local development on Linux with CRC/libvirt**.
macOS and Windows instead have [explicit checkpoint/login recovery](#macos-and-windows-login-recovery).
It is not
a production backup system, a cross-machine migration tool, or a live-memory
snapshot.

## Install

On Linux, `aap-demo create --full-demo` installs recovery automatically and fails
if recovery installation or dashboard startup fails. No separate install or
manual backup before reboot is required. For an existing demo, finish any running
deployment or other mutating demo command first:

```bash
aap-demo service install
```

Installation requires sudo. It installs a root-owned runner and systemd unit,
enables the installing user's lingering user manager for CRC's sockets and
validates starting the existing demo and dashboard. Initial installation does
not stop the demo or copy older state over it. Reinstallation restarts an active
service (including its shutdown backup) before validating the updated runner.
The service is enabled for boot only after its initial start succeeds.
Rerunning `create --full-demo` on Linux reuses a managed cluster (starting it
in place if stopped) and reinstalls/validates recovery. Plain `create`,
`destroy` and `redeploy-all` still require disabling the service first.

On Linux, installation also adds a desktop autostart entry for the installing
user. Boot recovery starts the local dashboard without opening a browser.
At the next graphical login, the default browser automatically opens
`http://127.0.0.1:8765/` (or the configured `AAP_DEMO_DASHBOARD_PORT`).
No browser is opened at the login screen or on a headless boot. The login
launcher checks that the user's recovery service is still enabled; disabling
the service removes the desktop entry. Existing installations must reinstall
the service to add this entry. This behavior does not apply to macOS or Windows
login recovery.

Allow enough time for cold disk copying, checksums, and AAP reconciliation.
The service allows one hour for startup and 30 minutes for shutdown. Adjust
these using `sudo systemctl edit aap-demo.service` if large disks require longer.
Shutdown can take several minutes because it includes a complete disk backup.
The repository must remain at its installation path.

### Optional forced CRC shutdown (Linux only)

If CRC repeatedly fails to shut down gracefully, explicitly opt in:

```bash
aap-demo service install --keep 1 --force-stop --stop-timeout 120
```

After the ordinary `crc stop` fails, the service waits up to another 120 seconds
(configurable from 1 to 86400). If CRC is still **running**, it force-powers-off
only the existing `crc` libvirt domain and verifies that CRC and Fleet are stopped
before copying disks. If CRC finishes shutting down during the wait, no force is
used. Unexpected VM states and libvirt errors stop recovery instead.

**Forced power-off can lose unsaved data.** The resulting backup is
**crash-consistent**, not a clean application backup; filesystem and application
recovery may be needed on restore. The service logs warnings and records
`crc_shutdown: forced` in the backup manifest, including a warning on restore.
Fleet guests are never force-stopped by this policy. Ordinary CLI stops and
macOS/Windows recovery behavior are unchanged.

The fallback is disabled unless `--force-stop` is supplied during installation.
An unsuccessful installation leaves automatic recovery disabled. Verify a
completed backup and a successful reboot before relying on recovery.

## Day-to-day commands

```bash
aap-demo start               # Save if active, then start the latest live state
aap-demo restart             # Save and bring the current demo fully online
aap-demo stop                # Stop cleanly and publish a new backup
aap-demo service backup      # Explicit checkpoint followed by startup in place
aap-demo service status
aap-demo service backups
sudo journalctl -u aap-demo.service --no-pager
```

While enabled, top-level `start`, `restart`, and `stop` delegate to systemd.
The service runs CRC and addon commands as the installing user, not as root.
The root runner handles disk access, libvirt metadata, and private backup storage.
It refreshes CRC's user daemon before starting with its existing configuration. Interactive
ingress CA import is disabled for service-started commands; set up local browser
trust through the ordinary deployment/setup workflow before unattended use.
The existing demo operation lock prevents backup/restore from racing a deployment.
The service stops before libvirt and the user's CRC daemon on host shutdown.

**The current persistent state is authoritative:** boot does not copy a checkpoint
over CRC settings, VM disks, application data, credentials or demo configuration.
A missing, stale or corrupt backup cannot cause automatic rollback. Restarting
an active service first saves its current cold state, then starts those same
live files. Backup verification remains mandatory before publishing a backup.

The demo is always brought fully online at boot, including resuming idle
AAP and enabled addons/Fleet. It does not preserve an intentional stopped or idle
mode across host reboot.

## Retention

Only **one completed backup** is retained by default:

```bash
aap-demo service install --keep 3    # Choose retention at installation
aap-demo service retention 3         # Change an existing installation
```

Retention changes apply when the next backup completes. A new backup is staged,
disk-checked and checksum-verified before it is published as `latest`; only then
are older completed backups pruned. Failure does not replace or delete the
previous completed backup.

Backups are stored under `/var/lib/aap-demo/<user>/states/`, outside the live
demo directories. Keep adequate **host** disk space: the preflight conservatively
requires approximately twice the allocated demo footprint free for staging.
Retained backups consume additional space. CRC's guest disk-growth policy does
not expand the host backup filesystem.

## What is saved

- CRC machine metadata, SSH keys, kubeconfigs, configuration and bundle cache.
- CRC's stopped disk, containing cluster objects, databases and local PVC data.
- File-backed additional CRC disks under the user's managed directories, such as
  an attached persistent image-store disk.
- Fleet disks, cloud-init data, configuration and SSH keys.
- The remaining persistent state under `~/.aap-demo/`.
- The libvirt domain definition and CRC's UEFI variable store.
- The standard credential Vault `~/.ansible/conf/env.yml` and its password file.

QCOW2 backing chains are flattened for active CRC and Fleet disks so their
backups do not depend on later changes to base images. Raw attached disks retain
their raw format. Stale Fleet PIDs, sockets, process locks and runtime logs are
not restored.

The credential Vault is copied as a **whole file**; restoring it also rolls back
any unrelated entries stored in that same file. Backups include secrets and the
Vault password, so they are **sensitive and not independently encrypted**. Backup
directories are root-only. Do not publish them or treat them as safe to share.

Only the standard local state directories and standard Vault paths are covered.
Custom credential locations, external storage, remote services, block-backed
VM disks, custom libvirt connections, and host configuration outside the listed
paths are not recoverable through this service. Unsupported attached disk paths
or formats cause backup failure rather than an incomplete success.

## CRC vsock forward watchdog

The CRC daemon forwards the VM's SSH (port 2222) and API over vsock. Under load
or after a daemon restart the forward can drop while the VM keeps running,
leaving the cluster unreachable (`crc status` shows the VM running but
MicroShift "Unreachable", and `aap-demo ssh` is refused). A systemd **user**
timer self-heals this:

- `scripts/aap-demo-crc-watchdog.sh check` runs every minute. When the VM is
  running but the SSH forward is refused, it restarts `crc-daemon.service` to
  re-establish the forward; only if that fails does it fall back to a full
  `crc stop`/`start` (VM reboot) as a last resort.
- Installed automatically by `aap-demo service install` and removed by
  `aap-demo service disable`. Manage it directly with
  `scripts/aap-demo-crc-watchdog.sh {check|install|uninstall|status}`.
- State is written to `~/.aap-demo/crc-watchdog.state`; concurrent runs are
  serialized with a lock. Retry counts/sleep are tunable via
  `AAP_DEMO_WATCHDOG_DAEMON_RETRIES`, `AAP_DEMO_WATCHDOG_REBOOT_RETRIES`, and
  `AAP_DEMO_WATCHDOG_RETRY_SLEEP`.

## Failure and recovery

- Fleet guests must respond to SSH and power off cleanly before backup. CRC must
  also stop cleanly unless the Linux forced-stop fallback is explicitly enabled.
  Fleet shutdown is scheduled with a short systemd timer so SSH can acknowledge
  the request before the guest disconnects.
- If CRC reports `VM Failed to gracefully shutdown`, backup stops without reading
  its running disk unless the opt-in fallback succeeds. A reproducible instance
  of this failure prevents clean-shutdown validation on the Fedora development
  host with CRC 2.64.0 / MicroShift
  4.22.13. Disable the failed service before resuming normal use; do not rely on
  automatic reboot recovery until a clean stop and subsequent startup succeed.
  The opt-in fallback above can handle a stuck running CRC VM, but can lose
  unsaved data and does not establish clean-shutdown reliability.
- A sudden power loss cannot create a shutdown backup. The next boot starts the
  existing persistent disks; it never replaces them with an older checkpoint.
  Unflushed guest writes can still be lost and filesystem/application recovery
  may be needed. This is not a guarantee against hardware failure or disk corruption.
- An interrupted backup is never selected as `latest` and does not prevent
  startup of the current persistent state.
- Missing tools, insufficient disk space, concurrent demo operations, checksum
  errors and readiness failures fail the systemd job and are visible in its
  journal. A failed start is not reported as a ready demo.
- If a shutdown checkpoint fails during a manual restart, systemd reports that
  failure. Subsequent startup uses the live files and warns about the incomplete
  backup; it does not roll back local changes. Retry the backup after resolving
  its error.
- If installation fails, resolve the journal's error and rerun installation
  after other demo operations finish. Installation validates startup, not backup
  recoverability.
- Updates to the installed root runner require reinstalling after other demo
  operations finish. Do not replace its files during an active backup.

Disable the service before rebuilding, deleting or uninstalling the demo:

```bash
aap-demo service disable
```

This saves the active demo, stops it, and disables automatic boot recovery.
Backups and the installed unit are retained; disabling does not erase your
recovery copies. With the service disabled, ordinary `aap-demo start` resumes
existing disks without rollback. Reinstall to re-enable shutdown backup and boot startup.

## macOS and Windows login recovery

These platforms use a different contract, explicitly **not** a guaranteed
shutdown hook or pre-login boot service:

1. Install recovery after a successful deployment.
2. Save with `aap-demo service backup` (resume afterward) or `aap-demo stop`
   (leave stopped) **before** a host restart/logout.
3. At the installing user's next login, restore the last completed checkpoint
   and bring the demo online.

`service install --keep N`, `service retention N`, `service status`,
`service backups`, `service backup`, and `service disable` are the platform
entry points. The default is one completed state. Starting stopped managed
disks intentionally replaces newer state with the last completed checkpoint.
Restarting a running managed demo checkpoints it first. A failed checkpoint
must not silently permit rollback over newer local work.

Large cold copies and VM shutdown cannot be guaranteed to finish within macOS
or Windows shutdown/logout deadlines. There is deliberately no claim that the
OS will wait. Abrupt shutdown may lose everything since the previous completed
checkpoint. Run an explicit checkpoint while your session is still available.

### macOS

The Bash CLI installs
`~/Library/LaunchAgents/com.aap-demo.recovery.plist` for the **next graphical
login**. It runs once, not as a continuously restarting supervisor. Logs,
retention settings and completed states are under
`~/Library/Application Support/aap-demo/`.

The supported CRC backend is vfkit with its local raw
`~/.crc/machines/crc/crc.img` and standard state paths. Legacy hyperkit,
external shared directories, externally linked top-level state/credential
paths and custom Vault paths are refused rather than partially backed up.
CRC must already have completed its ordinary host setup. Recovery refreshes
the existing `com.redhat.crc.daemon` LaunchAgent.

The checkpoint includes CRC metadata/cache/raw disk, `~/.aap-demo/`, managed
Fleet QCOW2 overlays flattened with `qemu-img`, and the standard Vault/password
files. It excludes runtime PID/socket/log/operation-lock files. Fleet guests
must shut down cleanly over SSH; there is no forced power-off.
Checksums are verified before publishing and before restore. Interrupted
restores are retryable and cannot be saved as a new checkpoint.

The private backup directory is owned by the user, not root. It contains
credentials and is **not separately encrypted**. Keep FileVault enabled.
Only same-account, same-path recovery is intended; use the same CRC version.
Disabling removes the login agent after checkpointing, not the retained copies.

### Windows

**Not full-demo boot parity:** the native Windows CLI still rejects
`create --full-demo`. Its recovery task runs only after interactive sign-in and
restores a checkpoint, not necessarily the latest live state. Pre-login CRC/AAP
and dashboard HTTP startup, and native Fleet/Ollama/Product Demos provisioning,
are not implemented. Do not treat the login task as fulfilling that requirement.

Use the native PowerShell CLI and Windows-hosted CRC, including when invoked
from WSL. Recovery uses a current-user login scheduled task and Hyper-V disk
handling; it does not install Linux systemd or run CRC inside WSL.
Native `aap-demo create` now installs the task automatically (opt out with
`AAP_DEMO_SKIP_BOOT_RECOVERY=true`). It does not capture an initial checkpoint:
after deploying AAP, run `aap-demo service backup` and then `aap-demo start`.
Checkpoint again before reboot. At sign-in the task opens the localhost
dashboard after successful recovery and AAP readiness; Python 3.10+ is required
for the dashboard. Set the Windows user environment variable
`AAP_DEMO_DASHBOARD_AUTOSTART=false` to suppress automatic dashboard launch.
This remains login recovery, not pre-login boot or automatic shutdown backup.
The installing user must belong to Hyper-V Administrators and have access
with a **limited**, non-elevated login token. The task
`aap-demo-login-restore` uses interactive current-user logon without storing a
password. Installation and checkpoint operations report missing access or
unsupported layouts rather than publish an incomplete snapshot.

Completed checkpoints are under
`%LOCALAPPDATA%\aap-demo\state\backups\`. The parent state directory also holds
the latest pointer, service configuration, pending/restore journals, logs
(last ten) and login result. Checkpoints include CRC machine disk/metadata,
`.crc\crc.json`, `.aap-demo\`, and the standard Vault/password files.
Restore staging uses `%USERPROFILE%\.aap-restore-<token>` on the same volume
as the files replaced.

**This is same-existing-VM checkpoint recovery, not full Hyper-V reconstruction.**
The Hyper-V VM definition must remain intact with the same VMId/configuration,
and the CRC bundle cache must remain present. Neither is recreated from the
checkpoint. Saved/paused VMs, Hyper-V checkpoints, differencing disks and
pass-through disks are refused. There is no automatic forced power-off.
Changing host hypervisor configuration outside these paths is not recoverable.
Budget approximately 1.1 times the managed disk footprint free for backup and
similar additional space for restore staging.

Backups are sensitive and not independently encrypted. Use Windows account
ACLs/BitLocker (files inherit the profile's ACLs), retain adequate host disk space, and do not share backup
directories. The workflow is same-machine recovery, not general VM migration.
See the [Windows quickstart](../Windows_Quickstart.md) and
[PowerShell guide](../powershell/README.md) for native prerequisites.

### Validation boundary

The new native integrations are covered by isolated filesystem/mock tests and
platform CI checks. **No real macOS/vfkit or Windows/Hyper-V backup/restore has
been validated from the Linux development host.** Before relying on recovery,
create a test value inside a disposable demo, checkpoint, restart/login and
verify that value, application readiness, credentials, addons and storage.
Do not treat a successful install or checksum test alone as recoverability.
