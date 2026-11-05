"""Host-side CRC checks for ``aap-demo diagnose``.

The cluster checks look from kubectl inward, so they cannot tell a missing
cluster from a VM that CRC cannot reach. These checks look at the host: the
``crc`` binary, whether ``crc status`` answers, the ``crc daemon`` that carries
the VM's network, and (on macOS) the SSH forward it serves on 127.0.0.1:2222.
"""

from __future__ import annotations

import os
import platform
import shutil
import socket
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from aap_demo.infra import crc as infra_crc

#: ``crc`` forwards the VM's SSH here on macOS (vfkit, user-mode networking).
SSH_FORWARD = ("127.0.0.1", 2222)
#: Bound on ``crc version`` and ``ps`` so a stuck host cannot hang diagnose.
PROBE_TIMEOUT_SECONDS = 6.0
FIX_HINT = "Fix: crc stop; pkill -f 'crc daemon'; crc cleanup && crc setup; then aap-demo start"


@dataclass
class HostProbe:
    """What the checks read from the host. Tests pass stand-ins."""

    system: str
    which_crc: Callable[[], Optional[str]]
    crc_version: Callable[[], str]
    status: Callable[[], Dict[str, Any]]
    machine_exists: Callable[[], bool]
    #: Command lines of running ``crc daemon`` processes, or None when the
    #: host has no ``ps`` to ask (Windows).
    daemons: Callable[[], Optional[List[str]]]
    port_open: Callable[[str, int], bool]
    resolve: Callable[[str], str] = os.path.realpath

    @classmethod
    def live(cls, runner: Any, home: Path) -> "HostProbe":
        def version() -> str:
            try:
                result = runner.run(["crc", "version"], timeout=PROBE_TIMEOUT_SECONDS)
            except Exception:  # noqa: BLE001 - a hung crc must not hang diagnose
                return ""
            return result.stdout if result.ok else ""

        def daemons() -> Optional[List[str]]:
            if shutil.which("ps") is None:
                return None
            try:
                result = runner.run(["ps", "-axo", "command="], timeout=PROBE_TIMEOUT_SECONDS)
            except Exception:  # noqa: BLE001 - a hung or failing ps must not hang diagnose
                return None
            if not result.ok:
                return None
            return daemon_lines(result.stdout)

        return cls(
            system=platform.system(),
            which_crc=lambda: shutil.which("crc"),
            crc_version=version,
            status=lambda: infra_crc.status_json(runner),
            machine_exists=lambda: infra_crc.machine_exists(home),
            daemons=daemons,
            port_open=_port_open,
        )


def daemon_lines(ps_output: str) -> List[str]:
    """``ps`` command lines whose program is ``crc`` running ``daemon``."""
    found = []
    for line in ps_output.splitlines():
        parts = line.split()
        if len(parts) >= 2 and os.path.basename(parts[0]) == "crc" and parts[1] == "daemon":
            found.append(line.strip())
    return found


def _port_open(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=2):
            return True
    except OSError:
        return False


@dataclass
class HostFindings:
    """What the cluster section needs to word its own result."""

    unresponsive: bool = False


def check(probe: HostProbe, rec: Any) -> HostFindings:
    """Record the ``OpenShift Local host`` section on ``rec``."""
    findings = HostFindings()
    rec.start("OpenShift Local host")
    crc = probe.which_crc()
    if crc is None:
        rec.fail("crc not found on PATH — run: aap-demo create (it installs CRC)")
        return findings
    client = infra_crc.crc_client_version(probe.crc_version()) or "version unknown"
    rec.ok(f"crc {client}: {crc}")

    data = probe.status()
    exists = probe.machine_exists()
    failed = False
    if not data and exists:
        findings.unresponsive = True
        failed = True
        rec.fail("CRC does not answer 'crc status', but a VM exists — a 'crc start' may be hung")

    lines = probe.daemons()
    if lines is None:
        rec.info("crc daemon: not checked on this platform")
    elif not lines:
        if exists:
            failed = True
            rec.fail("crc daemon is not running — the VM has no network")
        else:
            rec.info("crc daemon is not running (no VM yet)")
    else:
        # `crc setup` links ~/.crc/bin/crc to the crc it ran from, and the
        # daemon runs through that link. A link left from another install
        # (bash, an older pkg, a removed binary) gives the VM a stale daemon.
        program = lines[0].split()[0]
        daemon_target, crc_target = probe.resolve(program), probe.resolve(crc)
        if os.path.isabs(program) and daemon_target != crc_target:
            failed = True
            rec.fail(
                f"crc daemon runs {program} ({daemon_target}), "
                f"but crc on PATH is {crc} ({crc_target})"
            )
        else:
            rec.ok("crc daemon running")

    running = infra_crc.state_from_status(data) == infra_crc.STATE_RUNNING
    if probe.system == "Darwin" and (running or findings.unresponsive):
        host, port = SSH_FORWARD
        if probe.port_open(host, port):
            rec.ok(f"VM SSH forward {host}:{port} answers")
        else:
            failed = True
            rec.fail(f"Nothing answers on {host}:{port}, the VM's SSH forward")

    if failed:
        rec.info(FIX_HINT)
    return findings


__all__ = ["HostProbe", "HostFindings", "check", "daemon_lines", "FIX_HINT"]
