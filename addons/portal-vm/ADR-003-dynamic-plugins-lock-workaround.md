# ADR-003: Dynamic Plugins Lock File Workaround

**Status:** Accepted **Date:** 2026-06-24 **Author:** Chad Ferman **Related:** Portal appliance bug (all deployment
methods)

## Context

Portal appliance 2.2.1 fails to start dynamic plugins on second and subsequent boots.

### Symptoms

- First boot: Portal starts successfully, plugins load
- Subsequent boots: Portal service starts but plugins don't load
- No obvious errors in `journalctl -u portal`
- `/var/lib/portal/dynamic-plugins-root/install-dynamic-plugins.lock` persists across reboots

### Investigation

Lock file mechanism prevents concurrent plugin installations. Expected behavior:

1. Portal service starts
1. Plugin installer creates lock file
1. Plugins install
1. Lock file deleted on completion

**Bug:** Lock file not deleted on clean shutdown. Persists across reboots on bootc image.

**Affected versions:**

- Portal appliance 2.2.1 (confirmed)
- Likely all 2.x versions until Red Hat fixes

**Deployment methods affected:**

- QEMU (macOS, Linux)
- KVM/virt-install (Linux)
- OpenShift Virtualization
- VMware vSphere

**Not macOS-specific** - bootc image bug.

## Decision

**Delete lock file via cloud-init `runcmd` on every boot.**

```yaml
runcmd:
  - sudo rm -f /var/lib/portal/dynamic-plugins-root/install-dynamic-plugins.lock
  - systemctl restart portal.service
```

### Why `runcmd` not `bootcmd`

- `bootcmd`: Runs once on first boot only
- `runcmd`: Runs on every boot
- Need: Delete on every boot (bug can reoccur)

### Why `sudo`

Lock file owned by `root:root` (portal service runs as root). Cloud-init `runcmd` executes as configured user (`admin`),
needs `sudo`.

### Why before `systemctl restart`

Portal service auto-starts via systemd. By time cloud-init runs, portal already started with stale lock. Must delete +
restart.

## Alternatives Considered

### 1. Patch portal container image

**Rejected:**

- Requires rebuilding Red Hat signed image
- Breaks support/updates
- Not maintainable across versions

### 2. Systemd ExecStartPre hook

```ini
[Service]
ExecStartPre=/usr/bin/rm -f /var/lib/portal/dynamic-plugins-root/install-dynamic-plugins.lock
```

**Rejected:**

- Portal uses Podman Quadlet (`.container` files), not traditional systemd units
- Quadlet auto-generates `.service` files, can't easily inject `ExecStartPre`
- Would require complex systemd drop-in override

### 3. Cron job on reboot

```yaml
write_files:
  - path: /etc/cron.d/portal-unlock
    content: |
      @reboot root rm -f /var/lib/portal/dynamic-plugins-root/install-dynamic-plugins.lock
```

**Rejected:**

- Runs after portal already started (same issue)
- More complex than `runcmd`
- Harder to debug

### 4. Wait for Red Hat fix

**Rejected:**

- No timeline for fix
- Portal unusable on reboots without workaround
- Can remove workaround when fixed

## Implementation

### Cloud-init runcmd

```yaml
runcmd:
  - sudo rm -f /var/lib/portal/dynamic-plugins-root/install-dynamic-plugins.lock
  - systemctl restart portal.service
```

Placement in `runcmd`:

1. After network setup (if needed)
1. After /etc/hosts injection (if needed)
1. **Before** any portal health checks

### Verification

SSH into portal VM and check:

```bash
# Lock should not exist after boot completes
ls -la /var/lib/portal/dynamic-plugins-root/install-dynamic-plugins.lock
# Should return: No such file or directory

# Portal should be running
sudo systemctl status portal

# Plugins should be loaded (check portal logs)
sudo journalctl -u portal | grep -i plugin
```

## Consequences

### Positive

- Portal works on reboots
- Simple one-line workaround
- Easy to remove when upstream fixed
- No custom image building required

### Negative

- Must remember to remove when Red Hat fixes bug
- Extra restart adds ~60s to boot time
- Not addressing root cause (but can't - closed source)

### Monitoring for Fix

Check Red Hat portal appliance release notes for:

- "Fixed dynamic plugin lock file persistence"
- "Plugin installation improvements"
- Bootc systemd integration fixes

**Test after each portal appliance upgrade:**

```bash
# Boot VM, wait for portal to start, reboot, check if plugins load
# If plugins load without workaround, remove runcmd line
```

## References

- Portal appliance: `/var/lib/portal/dynamic-plugins-root/`
- Cloud-init docs: `runcmd` directive
- Related: ADR-002 (cloud-init configuration)
- Portal service: `systemctl status portal`

## Removal Plan

**When Red Hat fixes bug:**

1. Test new appliance version (boot → reboot → verify plugins load)
1. Remove `runcmd` lock deletion line from `deploy.sh`
1. Remove `systemctl restart portal.service` line (unless needed for other reasons)
1. Update this ADR status to "Superseded"
1. Document in changelog

**Tracking:** Check AAP release notes starting with 2.8+ releases.
