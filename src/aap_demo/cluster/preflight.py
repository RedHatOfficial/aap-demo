"""Kubeconfig/context preflight — ports ``setup_kubeconfig`` and
``verify_cluster_type`` (aap-demo.sh:264-320).

Bash runs ``setup_kubeconfig`` from the dispatch block *before* every command
that touches a cluster (aap-demo.sh:2861-2874): it checks ``kubectl`` exists,
exports ``KUBECONFIG`` to the ``--kubeconfig`` override or the resolved
default, re-extracts the kubeconfig over SSH when ``kubectl cluster-info``
fails, and applies ``--context`` with ``kubectl config use-context``. The
non-lifecycle commands additionally get ``verify_cluster_type``'s
"no cluster" / "cluster is stopped" warning.

The ``export`` half is reproduced by wrapping ``ctx.runner`` in an
``EnvRunner`` carrying the resolved ``KUBECONFIG``, so *every* later
subprocess sees it — a Python process cannot export into its own ambient
environment the way a shell script's ``export`` does for the rest of the
script.
"""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any, Callable, Optional

from aap_demo.cluster import kubeconfig as kubeconfig_mod
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, PrerequisiteError
from aap_demo.exec import ssh as ssh_mod
from aap_demo.exec.runner import EnvRunner
from aap_demo.infra import crc as infra_crc

#: Bash uses a 2-second connect timeout for the refresh attempt specifically
#: (aap-demo.sh:283), not ``CRC_SSH_OPTS``' 10 seconds.
REFRESH_CONNECT_TIMEOUT = 2


def _export(ctx: AppContext, path: Path) -> None:
    """Bash's ``export KUBECONFIG=...``, for a process that cannot export."""
    inner = ctx.runner.inner if isinstance(ctx.runner, EnvRunner) else ctx.runner
    ctx.env = {**ctx.env, "KUBECONFIG": str(path)}
    ctx.runner = EnvRunner(inner, ctx.kube_env())


def _refresh_from_vm(ctx: AppContext, path: Path) -> bool:
    """Ports the SSH re-extraction inside ``setup_kubeconfig`` (aap-demo.sh:277-292).

    Bash writes the *raw* remote kubeconfig here (no rename — that is only
    ``cmd_kubeconfig``'s job) and any failure is silent: the stale kubeconfig
    is simply left in place for the command to fail against on its own.
    """
    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is None:
        return False
    result = ssh_mod.exec_remote(
        ctx.runner,
        key,
        "cat",
        kubeconfig_mod.REMOTE_KUBECONFIG_PATH,
        sudo=True,
        connect_timeout=REFRESH_CONNECT_TIMEOUT,
    )
    if not result.ok or not result.stdout.strip():
        return False
    kubeconfig_mod.write_private(path, result.stdout)
    return True


def _apply_context(ctx: AppContext) -> None:
    """Ports the ``--context`` block (aap-demo.sh:296-306)."""
    name = ctx.kube_context
    if not name:
        return
    if ctx.runner.run(["kubectl", "config", "use-context", name]).ok:
        return
    listing = ctx.runner.run(["kubectl", "config", "get-contexts", "-o", "name"])
    names = [line.strip() for line in listing.stdout.splitlines() if line.strip()]
    available = "\n".join(f"  {n}" for n in names) if names else "  (none)"
    raise AapDemoError(f"Context '{name}' not found", hint=f"Available contexts:\n{available}")


def setup_kubeconfig(
    ctx: AppContext, *, which: Optional[Callable[[str], Optional[str]]] = None
) -> Path:
    """Ports ``setup_kubeconfig`` (aap-demo.sh:264-307). Returns the path in use.

    ``which`` is resolved on each call. A default argument would capture
    ``shutil.which`` at import, so a test patch — and a kubectl installed
    later on PATH — would never be seen.
    """
    finder = shutil.which if which is None else which
    if finder("kubectl") is None:
        raise PrerequisiteError(
            "kubectl not found",
            hint="Install kubectl and make sure it is on PATH: "
            "https://kubernetes.io/docs/tasks/tools/",
        )

    override = ctx.kubeconfig_override
    if override is not None:
        # Bash exits 1 rather than falling back when an explicit
        # --kubeconfig does not exist (aap-demo.sh:267-271).
        if not override.is_file():
            raise AapDemoError(f"Kubeconfig file not found: {override}")
        _export(ctx, override)
        _apply_context(ctx)
        return override

    path = ctx.kubeconfig
    path.parent.mkdir(parents=True, exist_ok=True)
    _export(ctx, path)
    if not ctx.runner.run(["kubectl", "cluster-info"]).ok and _refresh_from_vm(ctx, path):
        _export(ctx, path)
    _apply_context(ctx)
    return path


def warn_cluster_state(ctx: AppContext, runner: Any = None) -> None:
    """Ports ``verify_cluster_type`` (aap-demo.sh:2853-2874).

    Bash prints these with plain ``echo`` — stdout — before the command's own
    output, and never fails on them.
    """
    state = infra_crc.get_state(runner if runner is not None else ctx.runner)
    if state == infra_crc.STATE_NOT_CREATED:
        ctx.console.out("WARNING: No cluster exists")
        ctx.console.out("  Run 'aap-demo create' first")
        ctx.console.out("")
    elif state == infra_crc.STATE_STOPPED:
        ctx.console.out("WARNING: Cluster exists but is stopped")
        ctx.console.out("  Run 'crc start' to start it")
        ctx.console.out("")


__all__ = ["setup_kubeconfig", "warn_cluster_state"]
