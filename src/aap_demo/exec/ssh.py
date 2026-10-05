"""SSH access to the CRC VM (design §2.2 mapping table, R10).

Key detection and remote command execution go through the normal
``CommandRunner`` seam like any other subprocess call. Only
``interactive_shell`` is special: see its docstring for why it must bypass
that seam entirely.
"""

from __future__ import annotations

import os
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, List, Mapping, Optional

CRC_SSH_PORT = 2222
CRC_SSH_USER = "core@127.0.0.1"


def crc_machines_dir(env: Mapping[str, str]) -> Path:
    """``~/.crc/machines/crc`` — CRC's own directory, not one of ours."""
    home = Path(env.get("HOME") or Path.home())
    return home / ".crc" / "machines" / "crc"


def detect_ssh_key(machines_dir: Path) -> Optional[Path]:
    """Ports ``_detect_crc_ssh_key`` (includes/infra-crc.sh:19).

    CRC creates ``id_ed25519`` for the OpenShift preset and ``id_ecdsa`` for
    MicroShift; ed25519 is checked first, matching the bash order.
    """
    for name in ("id_ed25519", "id_ecdsa"):
        candidate = machines_dir / name
        if candidate.is_file():
            return candidate
    return None


def ssh_options(key: Path, *, connect_timeout: int = 10) -> List[str]:
    """Ports ``CRC_SSH_OPTS`` (includes/infra-crc.sh:32) — *non-interactive* only.

    ``BatchMode=yes`` and ``LogLevel=ERROR`` belong to the scripted paths that
    capture output; the interactive ``aap-demo ssh`` session uses
    :data:`INTERACTIVE_SSH_OPTIONS` instead.
    """
    return [
        "-i",
        str(key),
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "LogLevel=ERROR",
        "-o",
        f"ConnectTimeout={connect_timeout}",
        "-o",
        "BatchMode=yes",
    ]


def interactive_ssh_options(key: Path) -> List[str]:
    """Exactly the options bash's ``cmd_ssh`` passes (aap-demo.sh:1596-1604).

    Deliberately *not* ``CRC_SSH_OPTS``: ``BatchMode=yes`` would disable
    password/passphrase prompting, so a passphrase-protected key could not be
    used at all, and ``LogLevel=ERROR`` would hide exactly the connection
    diagnostics someone debugging a broken VM opened this shell to see.
    """
    return [
        "-i",
        str(key),
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
    ]


def remote_argv(
    key: Path, *remote_cmd: str, sudo: bool = True, connect_timeout: int = 10
) -> List[str]:
    argv = [
        "ssh",
        "-p",
        str(CRC_SSH_PORT),
        *ssh_options(key, connect_timeout=connect_timeout),
        CRC_SSH_USER,
    ]
    remote: List[str] = ["sudo", *remote_cmd] if sudo else list(remote_cmd)
    # ``ssh`` does not pass argv through: it joins everything after the host
    # with single spaces and hands the result to the remote user's shell. So
    # every remote token has to be quoted *here*, or a script passed as
    # ``python3 -c <source>`` arrives as bare shell words and dies on the
    # first parenthesis. Bash never hit this because it always passed one
    # already-quoted string (includes/olm-catalog-signature.sh:88,
    # aap-demo.sh:1751). Caught by the phase-3 live deploy, which reported
    # "Could not relax signature policy via SSH" for a VM that was reachable.
    argv.append(" ".join(shlex.quote(token) for token in remote))
    return argv


def exec_remote(
    runner: Any,
    key: Path,
    *remote_cmd: str,
    sudo: bool = True,
    timeout: Optional[float] = None,
    connect_timeout: int = 10,
) -> Any:
    """Ports ``_infra_crc_exec_cmd``/``_crc_exec`` (includes/infra-crc.sh:49,75)."""
    return runner.run(
        remote_argv(key, *remote_cmd, sudo=sudo, connect_timeout=connect_timeout),
        timeout=timeout,
    )


def interactive_shell(
    key: Path,
    *,
    exec_func: Callable[..., Any] = os.execvp,
    run_func: Callable[..., Any] = subprocess.run,
    exit_func: Callable[[int], Any] = sys.exit,
    is_windows: Optional[bool] = None,
) -> None:
    """Ports ``cmd_ssh`` (aap-demo.sh:1596-1604): ``exec ssh -p 2222 ...``.

    This deliberately bypasses ``CommandRunner``/``SubprocessRunner`` (design
    §2.2's "only exec/runner.py may call subprocess" rule, and §14 R10):
    the bash original replaces the current process with an interactive ssh
    session, and any wrapper that captures stdout/stderr — which is the
    entire point of ``CommandRunner`` — would break that interactive session
    (the user would get no terminal). POSIX gets true process replacement via
    ``os.execvp``, matching bash's ``exec``. Windows has no exec() that keeps
    an interactive terminal session working the same way, so there it runs
    ssh as an inherited-stdio child and exits with its return code instead
    (documented gap, per R10's own mitigation text).

    ``exec_func``/``run_func``/``exit_func`` are injectable so this is
    unit-testable without actually replacing or exiting the test process.
    """
    argv = ["ssh", "-p", str(CRC_SSH_PORT), *interactive_ssh_options(key), CRC_SSH_USER]
    windows = os.name == "nt" if is_windows is None else is_windows
    if windows:
        completed = run_func(argv)  # noqa: S603 - argv list, inherited stdio for the interactive session
        exit_func(completed.returncode)
    else:
        exec_func(argv[0], argv)  # noqa: S606 - documented exec-bypass (R10)
