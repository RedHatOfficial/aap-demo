"""Cluster VM setting that Fleet's systemd node pods need."""

from __future__ import annotations

from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, PrerequisiteError
from aap_demo.exec import ssh as ssh_mod

SELINUX_BOOLEAN = "container_manage_cgroup"

#: Rebuilding the SELinux policy for ``setsebool -P`` can take a while.
SETSEBOOL_TIMEOUT = 300


def allow_systemd(ctx: AppContext) -> None:
    """Let containers write their own cgroup, so systemd can run as PID 1.

    CRI-O gives a container whose command is ``/sbin/init`` a writable cgroup,
    but SELinux on the VM blocks the write until this boolean is on. Without
    it, systemd exits at boot with ``Failed to create /init.scope control
    group: Permission denied``. ``-P`` keeps the setting across VM restarts.
    """
    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is None:
        raise PrerequisiteError(
            "Cannot find the CRC SSH key",
            hint="Fleet sets an SELinux boolean on the cluster VM. Run: aap-demo create",
        )
    current = ssh_mod.exec_remote(ctx.runner, key, "getsebool", SELINUX_BOOLEAN, sudo=True)
    if current.ok and current.stdout.strip().endswith("--> on"):
        return
    ctx.console.progress(f"Turning on the {SELINUX_BOOLEAN} SELinux boolean for systemd nodes")
    result = ssh_mod.exec_remote(
        ctx.runner,
        key,
        "setsebool",
        "-P",
        SELINUX_BOOLEAN,
        "on",
        sudo=True,
        timeout=SETSEBOOL_TIMEOUT,
    )
    if not result.ok:
        raise AapDemoError(
            f"Could not turn on the {SELINUX_BOOLEAN} SELinux boolean on the cluster VM",
            hint=f"Check: aap-demo ssh, then: sudo setsebool -P {SELINUX_BOOLEAN} on",
        )
