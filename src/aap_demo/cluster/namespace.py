"""Namespace creation, PSA labels, SCC grants, pull secret (design §14 R3).

Ports ``setup_namespace`` (aap-demo.sh:2297-2379). **The order is the
contract**, and R3 names getting it wrong as the single most common failure
mode in the current tool. It is, in bash's sequence:

1. clear a ``Terminating`` namespace (wait 15 × 2s, then strip finalizers),
2. ``kubectl create namespace``,
3. put CRC's bundled ``oc`` on PATH when the host has no ``oc``,
4. **grant the SCCs**,
5. label the namespace ``pod-security…=privileged``,
6. create the pull secret and patch the default ServiceAccount.

Steps 4 and 5 are before step 6 because the pull secret's creation is the
first thing that can be followed by a pod-creating apply; a grant that lands
after the first pod is admitted does not retroactively admit it. Step 3 is
before step 4 for the obvious reason and step 1 before step 2 because
``create namespace`` against a terminating namespace fails in a way bash then
swallows with ``|| true``.
"""

from __future__ import annotations

import json
import time
from typing import Any, Callable, Optional

from aap_demo.cluster import pull_secret as pull_secret_mod
from aap_demo.cluster import scc as scc_mod
from aap_demo.core.context import AppContext
from aap_demo.exec import kubectl
from aap_demo.exec.runner import EnvRunner

#: Bash polls 15 times at 2s while a namespace finishes terminating
#: (aap-demo.sh:2303-2308) — 30 seconds, then force-clears.
TERMINATING_ATTEMPTS = 15
TERMINATING_INTERVAL = 2

PSA_LABELS = (
    "pod-security.kubernetes.io/enforce=privileged",
    "pod-security.kubernetes.io/audit=privileged",
    "pod-security.kubernetes.io/warn=privileged",
)


def phase(ctx: AppContext, namespace: str) -> str:
    return kubectl.jsonpath(ctx.runner, "namespace", namespace, path="{.status.phase}")


def _force_clear_finalizers(ctx: AppContext, namespace: str) -> None:
    """Ports the ``kubectl replace --raw …/finalize`` escape hatch (aap-demo.sh:2313).

    Bash pipes the namespace JSON through ``python3 -c`` to blank
    ``spec.finalizers``; here that is just ``json`` in-process, but the API
    call and the ``|| true`` tolerance are identical.
    """
    ctx.console.out("  Force-clearing stuck namespace...")
    current = ctx.runner.run(["kubectl", "get", "namespace", namespace, "-o", "json"])
    try:
        document = json.loads(current.stdout or "{}")
    except ValueError:
        return
    document.setdefault("spec", {})["finalizers"] = []
    ctx.runner.run(
        [
            "kubectl",
            "replace",
            "--raw",
            f"/api/v1/namespaces/{namespace}/finalize",
            "-f",
            "-",
        ],
        input=json.dumps(document),
    )


def clear_terminating(
    ctx: AppContext, namespace: str, *, sleep: Callable[[float], None] = time.sleep
) -> None:
    if phase(ctx, namespace) != "Terminating":
        return
    ctx.console.out(f"  Namespace {namespace} is terminating, waiting...")
    status = "Terminating"
    for _ in range(TERMINATING_ATTEMPTS):
        sleep(TERMINATING_INTERVAL)
        status = phase(ctx, namespace)
        if status != "Terminating":
            break
    if status == "Terminating":
        _force_clear_finalizers(ctx, namespace)
        sleep(2)


def _prepend_oc_to_path(ctx: AppContext, which: Callable[[str], Optional[str]]) -> None:
    """Step 3 — CRC ships an ``oc`` the host may not have (aap-demo.sh:2318)."""
    extra = scc_mod.oc_env_path(ctx, which=which)
    if not extra:
        return
    env = dict(ctx.env)
    env["PATH"] = extra + ":" + env.get("PATH", "")
    ctx.env = env
    inner = ctx.runner.inner if isinstance(ctx.runner, EnvRunner) else ctx.runner
    ctx.runner = EnvRunner(inner, ctx.kube_env())


def label(ctx: AppContext, namespace: str) -> Any:
    return ctx.runner.run(["kubectl", "label", "namespace", namespace, *PSA_LABELS, "--overwrite"])


def ensure(
    ctx: AppContext,
    namespace: Optional[str] = None,
    *,
    which: Callable[[str], Optional[str]] = None,  # type: ignore[assignment]
    sleep: Callable[[float], None] = time.sleep,
) -> Optional[str]:
    """Ports ``setup_namespace``. Returns the pull-secret path bash left in ``PULL_SECRET``."""
    import shutil

    resolve = which if which is not None else shutil.which
    ns = namespace or ctx.namespace

    ctx.console.progress(f"Setting up namespace {ns}")
    clear_terminating(ctx, ns, sleep=sleep)
    # Bash swallows the failure: the namespace usually already exists.
    ctx.runner.run(["kubectl", "create", "namespace", ns])

    _prepend_oc_to_path(ctx, resolve)
    scc_mod.grant_namespace_sccs(ctx, ns, which=resolve)
    label(ctx, ns)

    path = pull_secret_mod.ensure(ctx, ns)
    return str(path) if path is not None else None


__all__ = ["PSA_LABELS", "clear_terminating", "ensure", "label", "phase"]
