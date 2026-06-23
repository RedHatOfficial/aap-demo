# Portal Appliance 2.2.1 - Plugin Install Lock Issue

## Summary

Portal container fails to start on first boot, stuck indefinitely waiting for a stale plugin install lock that never releases. Container remains unhealthy, port 7007 never listens, and `https://localhost:8443` times out with no HTTP response.

**Confirmed platform-agnostic**: reproduces on native Linux KVM (Fedora, x86_64) as well as macOS ARM with QEMU x86 emulation.

## Environment

### macOS (original report)

- **Portal Appliance Version**: `ansible-automation-portal-2.2.1-x86_64.qcow2`
- **Container Image**: `registry.redhat.io/rhdh/rhdh-hub-rhel9@sha256:80453720616cee369e9f79863ef1815a2741afdeb25d3572085d11ad54afa9a0`
- **Platform**: QEMU x86_64 emulation on macOS ARM (socket_vmnet bridged networking)
- **VM Specs**: 8GB RAM, 4 vCPU
- **RHEL Version**: 9 (from portal appliance)
- **Podman Version**: (as shipped in appliance)

### Linux native KVM (2026-06-23)

- **Platform**: Fedora 44, x86_64, native KVM (`deploy-linux.sh`)
- **VM Specs**: 8GB RAM, 4 vCPU
- **Networking**: QEMU user-mode with `hostfwd=tcp::2223-:22,hostfwd=tcp::8443-:8443`
- **AAP backend**: CRC / MicroShift (`aap-aap-operator.apps.127.0.0.1.nip.io`)
- **Boot time**: ~3 minutes to SSH; portal stuck indefinitely after boot

## Steps to Reproduce

1. Deploy portal appliance 2.2.1 qcow2 via QEMU
2. Boot VM with cloud-init config containing:

   ```yaml
   aap:
     host_url: "https://aap-example.apps.192.168.68.81.nip.io"
     token: "<token>"
     check_ssl: false
     oauth:
       client_id: "portal-vm"
       client_secret: "<secret>"
   database:
     type: builtin
   ```

3. VM boots successfully, cloud-init completes
4. Portal service starts: `systemctl status portal` shows `active (running)`
5. Check portal container logs: `podman logs portal`

## Expected Behavior

Portal container should:

1. Install dynamic plugins
2. Start RHDH on port 7007
3. Become healthy
4. Respond to HTTPS requests on port 8443 (host port-forward)

## Actual Behavior

Portal container logs show indefinite lock wait:

```
GitHub integration disabled (no valid token provided)
GitLab integration disabled (no valid token provided)
Running dynamic plugins preparation (inside container where all scripts exist)...
dynamic-plugins-root exists in custom location - keeping it
Removing ~/.npmrc to fix RHIDP-4410
Using dynamic-plugins.override.yaml
No .npmrc found, skipping NPM_CONFIG_USERCONFIG
Running install-dynamic-plugins.sh
Installing plugins to: /opt/app-root/src/dynamic-plugins-root
======= Waiting for lock release (file: /opt/app-root/src/dynamic-plugins-root/install-dynamic-plugins.lock)...
```

**Observations (Linux KVM, corrected):**

- Lock file **does exist** as a stale 0-byte file on the host filesystem:

  ```
  /var/lib/portal/dynamic-plugins-root/install-dynamic-plugins.lock
  ```

- Lock persists across reboots via bind mount: `/var/lib/portal/dynamic-plugins-root` → `/opt/app-root/src/dynamic-plugins-root`
- Partial plugin installs are present in the directory from an interrupted prior run (timestamps predate current boot)
- Container status: `starting` / `unhealthy` (health checks fail)
- Port 7007: **not listening** (443 mapped inside VM, forwarded to host 8443)
- Service status: `active (running)` but container blocked in install loop
- `curl https://localhost:8443` returns **HTTP 000**, exit code 35 (SSL/connect timeout)
- Plugin dir permissions: `drwxr-xr-x. portal root` (portal user owns)

**Note on earlier macOS observation:** `podman exec portal ls .../*.lock` may report "No such file" due to shell glob expansion inside the container even when the lock exists on the bind-mounted host path. Check the host path directly:

```bash
sudo ls -la /var/lib/portal/dynamic-plugins-root/install-dynamic-plugins.lock
```

## Container State

```
$ podman ps -a
CONTAINER ID  IMAGE                                                                                                               COMMAND         STATUS                     PORTS
a268e1d49749  registry.redhat.io/ansible-automation-platform-27/ansible-dev-tools-rhel9@sha256:...  adt server      Up (healthy)
ea80a4a9ffce  registry.redhat.io/rhel9/postgresql-15@sha256:...                                     run-postgresql  Up (healthy)             127.0.0.1:5432->5432/tcp
917a4a99bbe6  registry.redhat.io/rhdh/rhdh-hub-rhel9@sha256:80453720616cee369e9f79863ef1815a2741afdeb25d3572085d11ad54afa9a0                     Up (unhealthy)  0.0.0.0:443->7007/tcp, 8080/tcp
```

## Root Cause Analysis

### Lock mechanism (`install-dynamic-plugins.py`)

The install script uses an exclusive-create lock with no timeout:

```python
def create_lock(lock_file_path):
    while True:
      try:
        with open(lock_file_path, 'x'):   # exclusive create
          print(f"======= Created lock file: {lock_file_path}")
          return
      except FileExistsError:
        wait_for_lock_release(lock_file_path)  # infinite loop, 1s sleep

def wait_for_lock_release(lock_file_path):
   while True:
     if not os.path.exists(lock_file_path):
       break
     time.sleep(1)
```

Lock removal is registered via `atexit` — if the install process is killed (VM crash, `systemctl restart`, cert regeneration script, etc.) before completion, the lock is left behind on the persistent volume.

### `clean-plugin-lock.sh` gap

The appliance ships `/usr/local/bin/clean-plugin-lock.sh` as an `ExecStartPre` hook, but it only cleans the lock **inside an already-running container**:

```bash
if podman ps -a --format '{{.Names}}' | grep -q '^portal$'; then
    podman exec portal rm -f "$LOCK_FILE"
else
    echo "No existing portal container, lock cleanup not needed"  # skips host-side lock
fi
```

On fresh boot or restart when no container exists yet, the stale lock at `/var/lib/portal/dynamic-plugins-root/install-dynamic-plugins.lock` is never removed before the new container starts.

### Contributing factors on Linux deploy

1. **`generate-portal-cert.sh` calls `systemctl restart portal`** during cloud-init `runcmd`, which can interrupt an in-progress plugin install and leave the lock behind.
2. **qcow2 disk retains state** — redeploying without deleting `~/.aap-demo/portal-vm/portal.qcow2` carries forward the stale lock and partial plugin tree.
3. **AAP route / `/etc/hosts` mismatch** (secondary, does not cause the lock issue but breaks AAP integration once portal starts): `deploy-linux.sh` writes `/etc/hosts` with `aap-aap-operator.apps.<host_ip>.nip.io` but cloud-init sets `host_url` to the CRC route `aap-aap-operator.apps.127.0.0.1.nip.io`. From inside the VM, the configured URL is unreachable.

## Attempted Workarounds

### Service Restart

```bash
systemctl restart portal
```

**Result**: Same issue — lock persists on host filesystem; restart does not clear it.

### Lock File Check (inside container)

```bash
podman exec portal ls -la /opt/app-root/src/dynamic-plugins-root/*.lock
```

**Result**: May misleadingly report "No such file" due to glob expansion; lock exists on host bind mount.

### Manual Lock Removal (works)

```bash
sudo systemctl stop portal
sudo rm -f /var/lib/portal/dynamic-plugins-root/install-dynamic-plugins.lock
sudo systemctl start portal
sudo podman logs -f portal
```

**Result**: Install proceeds — new plugin directories appear, container moves toward `(healthy)`. Requires full stop before removal; `systemctl restart` alone is insufficient because the lock may be recreated by a racing process.

### Fresh qcow2

```bash
./deploy-linux.sh --delete
rm -rf ~/.aap-demo/portal-vm/portal.qcow2
./deploy-linux.sh
```

**Result**: Clean disk avoids carrying forward stale state, but lock can recur if install is interrupted again (e.g., by cert generation restart).

## Impact

Portal appliance unusable on first boot without manual intervention. Postgres and devtools containers start healthy; only the main portal (RHDH) container is affected.

## Additional Context

Cloud-init successfully:

- Configured AAP connection (portal-specific `aap`/`database` keys; schema validation warning is expected)
- Set up SSH keys — SSH works: `ssh -i ~/.aap-demo/portal-vm/id_ed25519 -p 2223 admin@localhost`
- Created portal SSL cert via custom script
- Started all systemd services (portal, postgres, devtools)

Other containers healthy:

- `portal-postgres`: Up, healthy
- `portal-devtools`: Up, healthy

Only portal container affected.

## Linux Native KVM Testing

**Platform**: Fedora 44, x86_64, KVM enabled
**Boot Time**: ~3 minutes to SSH
**Result**: **FAILED — same lock issue as macOS emulation**

| Component | Status |
|-----------|--------|
| QEMU/KVM VM | Running, SSH on port 2223 |
| cloud-init | Completed |
| portal-postgres | Healthy |
| portal-devtools | Healthy |
| portal (RHDH) | Stuck on stale lock, unhealthy |
| https://localhost:8443 | Timeout (HTTP 000) |

Conclusion: **Not emulation-specific.** This is an appliance/image bug affecting any platform where the plugin install is interrupted before `atexit` lock cleanup runs.

## Questions for Red Hat

1. Is lock supposed to be created externally or by install script? (Script creates it via exclusive `open(..., 'x')`; stale lock from killed process is the failure mode.)
2. Should there be a timeout on lock wait, or stale-lock detection (e.g., check lock age / owning PID)?
3. Should `clean-plugin-lock.sh` also check `/var/lib/portal/dynamic-plugins-root/` on the host before container start?
4. Known issue with 2.2.1 appliance on emulated x86? (Now confirmed on native x86 KVM as well.)
5. Recommended workaround or newer appliance version available?

## Suggested Fixes

### Appliance (Red Hat)

- `clean-plugin-lock.sh`: remove stale lock from `/var/lib/portal/dynamic-plugins-root/` on the host filesystem, not only via `podman exec`
- `install-dynamic-plugins.py`: add lock age timeout or stale-lock detection
- Avoid `systemctl restart portal` in first-boot cert generation while plugin install may be running

### aap-demo deploy script

- `deploy-linux.sh`: write `/etc/hosts` using the **actual AAP route hostname** from `kubectl get route aap`, not a separate `<host_ip>.nip.io` variant
- Pre-start hook or deploy script: remove stale lock on host before starting VM or after SSH is available

---

**Filed by**: AAP Customer
**Date**: 2026-06-23
**Updated**: 2026-06-23 (Linux native KVM findings)
**Product**: Ansible Automation Platform 2.7 Portal Appliance
