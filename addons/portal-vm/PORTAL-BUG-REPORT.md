# Portal Appliance 2.2.1 - Plugin Install Lock Issue

## Summary

Portal container fails to start on first boot, stuck indefinitely waiting for plugin install lock that never releases. Container remains unhealthy, port 7007 never listens.

## Environment

- **Portal Appliance Version**: `ansible-automation-portal-2.2.1-x86_64.qcow2`
- **Container Image**: `registry.redhat.io/rhdh/rhdh-hub-rhel9@sha256:80453720616cee369e9f79863ef1815a2741afdeb25d3572085d11ad54afa9a0`
- **Platform**: QEMU x86_64 emulation on macOS ARM (socket_vmnet bridged networking)
- **VM Specs**: 8GB RAM, 4 vCPU
- **RHEL Version**: 9 (from portal appliance)
- **Podman Version**: (as shipped in appliance)

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
4. Respond to HTTPS requests

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

**Observations:**

- Lock file **does not exist**: `ls /opt/app-root/src/dynamic-plugins-root/*.lock` returns no files
- Container status: `unhealthy` (health checks fail)
- Port 7007: **not listening**
- Service status: `active (running)` but container blocked
- Plugin dir permissions: `drwxr-xr-x. 2 portal root` (portal user owns)

## Container State

```
$ podman ps -a
CONTAINER ID  IMAGE                                                                                                               COMMAND         STATUS                     PORTS
418ae94d9bbf  registry.redhat.io/rhdh/rhdh-hub-rhel9@sha256:80453720616cee369e9f79863ef1815a2741afdeb25d3572085d11ad54afa9a0          33 minutes ago  Up 33 minutes (unhealthy)  0.0.0.0:443->7007/tcp, 8080/tcp
```

## Attempted Workarounds

### Service Restart

```bash
systemctl restart portal
```

**Result**: Same issue - still waits for non-existent lock

### Lock File Check

```bash
podman exec portal ls -la /opt/app-root/src/dynamic-plugins-root/*.lock
```

**Result**: `No such file or directory` - lock file never created

## Analysis

Script `install-dynamic-plugins.sh` waits for lock file to be released but:

1. Lock file doesn't exist
2. No process appears to be creating it
3. Wait loop is infinite (no timeout)

Possible root cause:

- Race condition in plugin install initialization
- Missing lock cleanup from previous failed attempt (but fresh boot?)
- Script expects external lock creation that never happens

## Impact

Portal appliance unusable on first boot. Requires manual intervention or image rebuild.

## Additional Context

Cloud-init successfully:

- Configured AAP connection
- Set up SSH keys
- Created portal SSL cert via custom script
- Started all systemd services (portal, postgres, devtools)

Other containers healthy:

- `portal-postgres`: Up, healthy
- `portal-devtools`: Up, healthy

Only portal container affected.

## Questions for Red Hat

1. Is lock supposed to be created externally or by install script?
2. Should there be timeout on lock wait?
3. Known issue with 2.2.1 appliance on emulated x86?
4. Recommended workaround or newer appliance version available?

---

**Filed by**: AAP Customer
**Date**: 2026-06-23
**Product**: Ansible Automation Platform 2.7 Portal Appliance
