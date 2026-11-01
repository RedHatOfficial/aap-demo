"""Kubeconfig/context preflight — ports ``setup_kubeconfig`` and
``verify_cluster_type``.

Bash runs ``setup_kubeconfig`` from the dispatch block *before* every command
that touches a cluster: it checks ``kubectl`` exists,
exports ``KUBECONFIG`` to the ``--kubeconfig`` override or the resolved
default, re-extracts the kubeconfig over SSH when ``kubectl cluster-info``
fails, and applies ``--context`` with ``kubectl config use-context``. The
non-lifecycle commands additionally get ``verify_cluster_type``'s
"no cluster" / "cluster is stopped" warning.

``oc login`` changes the current context of the kubeconfig, so cluster commands
stop unless the API server is local. That ports ``includes/kubeconfig-guard.sh``.

The ``export`` half is reproduced by wrapping ``ctx.runner`` in an
``EnvRunner`` carrying the resolved ``KUBECONFIG``, so *every* later
subprocess sees it — a Python process cannot export into its own ambient
environment the way a shell script's ``export`` does for the rest of the
script.
"""

from __future__ import annotations

import ipaddress
import shlex
import shutil
from pathlib import Path
from typing import Any, Callable, List, Optional
from urllib.parse import urlsplit

from aap_demo.cluster import kubeconfig as kubeconfig_mod
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, PrerequisiteError
from aap_demo.exec import ssh as ssh_mod
from aap_demo.exec.runner import EnvRunner
from aap_demo.infra import crc as infra_crc

#: Bash uses a 2-second connect timeout for the refresh attempt specifically,
#: not ``CRC_SSH_OPTS``' 10 seconds.
REFRESH_CONNECT_TIMEOUT = 2

#: Set to target a remote API server on purpose. Same name as the bash guard.
ALLOW_REMOTE_ENV = "AAP_DEMO_ALLOW_REMOTE_KUBECONFIG"
ALLOW_REMOTE_VALUES = frozenset({"1", "true", "TRUE", "yes", "YES"})
LOCAL_API_HOSTS = frozenset({"localhost", "127.0.0.1", "::1", "api.crc.testing"})
#: ``crc ip`` can hang when the daemon is unhealthy.
CRC_IP_TIMEOUT = 2
LOCAL_CONTEXT_NAMES = ("microshift", "aap-demo")
SERVER_JSONPATH = "jsonpath={.clusters[0].cluster.server}"
ALL_SERVERS_JSONPATH = 'jsonpath={range .clusters[*]}{.cluster.server}{"\\n"}{end}'


def _export(ctx: AppContext, path: Path) -> None:
    """Bash's ``export KUBECONFIG=...``, for a process that cannot export."""
    inner = ctx.runner.inner if isinstance(ctx.runner, EnvRunner) else ctx.runner
    ctx.env = {**ctx.env, "KUBECONFIG": str(path)}
    ctx.runner = EnvRunner(inner, ctx.kube_env())


def _refresh_from_vm(ctx: AppContext, path: Path) -> bool:
    """Ports the SSH re-extraction inside ``setup_kubeconfig``.

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
    """Ports the ``--context`` block."""
    name = ctx.kube_context
    if not name:
        return
    if ctx.runner.run(["kubectl", "config", "use-context", name]).ok:
        return
    listing = ctx.runner.run(["kubectl", "config", "get-contexts", "-o", "name"])
    names = [line.strip() for line in listing.stdout.splitlines() if line.strip()]
    available = "\n".join(f"  {n}" for n in names) if names else "  (none)"
    raise AapDemoError(f"Context '{name}' not found", hint=f"Available contexts:\n{available}")


def _server_host(server: str) -> str:
    """Lowercase host of a kubeconfig server URL, without brackets or port."""
    target = server if "://" in server else f"https://{server}"
    try:
        return (urlsplit(target).hostname or "").lower()
    except ValueError:
        return ""


def _crc_ip(ctx: AppContext, finder: Callable[[str], Optional[str]]) -> Optional[str]:
    if finder("crc") is None:
        return None
    try:
        result = ctx.runner.run(["crc", "ip"], timeout=CRC_IP_TIMEOUT)
    except AapDemoError:
        return None
    if not result.ok:
        return None
    try:
        return str(ipaddress.ip_address(result.stdout.strip()))
    except ValueError:
        return None


def _crc_kubeconfig_hosts(ctx: AppContext) -> List[str]:
    """Hosts from CRC's own kubeconfig. ``oc login`` does not write to that file."""
    path = ssh_mod.crc_machines_dir(ctx.env) / "kubeconfig"
    if not path.is_file() or path.stat().st_size == 0:
        return []
    argv = ["kubectl", "--kubeconfig", str(path), "config", "view", "-o", ALL_SERVERS_JSONPATH]
    listed = ctx.runner.run(argv)
    return [_server_host(line) for line in listed.stdout.splitlines() if line.strip()]


def _host_is_local(ctx: AppContext, host: str, finder: Callable[[str], Optional[str]]) -> bool:
    if not host:
        return False
    if host in LOCAL_API_HOSTS or host == _crc_ip(ctx, finder):
        return True
    return host in _crc_kubeconfig_hosts(ctx)


def _context_server(ctx: AppContext, path: Path, context: Optional[str] = None) -> str:
    argv = ["kubectl", "--kubeconfig", str(path), "config", "view"]
    if context:
        argv.append(f"--context={context}")
    return ctx.runner.run([*argv, "--minify", "-o", SERVER_JSONPATH]).stdout.strip()


def _local_context_name(
    ctx: AppContext, path: Path, finder: Callable[[str], Optional[str]]
) -> Optional[str]:
    argv = ["kubectl", "--kubeconfig", str(path), "config", "get-contexts", "-o", "name"]
    names = ctx.runner.run(argv).stdout.split()
    for name in LOCAL_CONTEXT_NAMES:
        if name in names and _host_is_local(
            ctx, _server_host(_context_server(ctx, path, name)), finder
        ):
            return name
    return None


def _remote_hint(path: Path, context: str, server: str, suggestion: Optional[str]) -> str:
    quoted = shlex.quote(str(path))
    if suggestion:
        name = shlex.quote(suggestion)
        fix = (
            "Switch back to the local context:\n"
            f"    kubectl config use-context {name}\n"
            "  Or run one command with that context:\n"
            f"    aap-demo --context {name} <command>"
        )
    else:
        fix = (
            "This file has no local OpenShift Local context. Set it aside, then refresh it:\n"
            f"    mv {quoted} {shlex.quote(f'{path}.remote')}\n"
            "    aap-demo kubeconfig"
        )
    return (
        f"Current context: {context}\n"
        f"  API server: {server}\n"
        f"  Kubeconfig: {path}\n"
        "  oc login updates the current context of this file. aap-demo stopped before it\n"
        "  could read or change that cluster.\n"
        f"  {fix}\n"
        "  To target this API server on purpose:\n"
        f"    {ALLOW_REMOTE_ENV}=true aap-demo <command>"
    )


def _reject_remote(ctx: AppContext, path: Path, finder: Callable[[str], Optional[str]]) -> None:
    """Ports ``aap_demo_reject_remote_kubeconfig``."""
    if ctx.env.get(ALLOW_REMOTE_ENV, "") in ALLOW_REMOTE_VALUES:
        return
    if not path.is_file() or path.stat().st_size == 0:
        return
    server = _context_server(ctx, path)
    if not server or _host_is_local(ctx, _server_host(server), finder):
        return
    current = ctx.runner.run(["kubectl", "--kubeconfig", str(path), "config", "current-context"])
    raise AapDemoError(
        "Kubeconfig points at a remote cluster",
        hint=_remote_hint(
            path,
            current.stdout.strip() or "(unknown)",
            server,
            _local_context_name(ctx, path, finder),
        ),
    )


def setup_kubeconfig(
    ctx: AppContext,
    *,
    which: Optional[Callable[[str], Optional[str]]] = None,
    guard: bool = True,
) -> Path:
    """Ports ``setup_kubeconfig``. Returns the path in use.

    ``guard=False`` is for the commands that never talk to the Kubernetes API.
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
        # --kubeconfig does not exist.
        if not override.is_file():
            raise AapDemoError(f"Kubeconfig file not found: {override}")
        _export(ctx, override)
        _apply_context(ctx)
        if guard:
            _reject_remote(ctx, override, finder)
        return override

    path = ctx.kubeconfig
    path.parent.mkdir(parents=True, exist_ok=True)
    _export(ctx, path)
    _apply_context(ctx)
    if guard:
        _reject_remote(ctx, path, finder)
    # Refresh only after the context is known to be local, so a reachable remote
    # context can't skip the refresh and stay the target.
    if not ctx.runner.run(["kubectl", "cluster-info"]).ok and _refresh_from_vm(ctx, path):
        _export(ctx, path)
        _apply_context(ctx)
        if guard:
            _reject_remote(ctx, path, finder)
    return path


def warn_cluster_state(ctx: AppContext, runner: Any = None) -> None:
    """Ports ``verify_cluster_type``.

    Bash prints these with plain ``echo`` — stdout — before the command's own
    output, and never fails on them. Suppressed for structured JSON/YAML output.
    """
    if ctx.output in ("json", "yaml"):
        return
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
