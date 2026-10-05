"""SCC grants for every service account in the namespace (design §14 R3).

Ports ``_grant_sccs`` (aap-demo.sh:2262-2295). Two implementations, kept
because they are not equivalent: ``oc adm policy add-scc-to-group`` and a
``kubectl`` fallback that creates a ClusterRoleBinding named
``system:openshift:scc:<scc>:<ns>``. ``diagnose`` already has to recognize
both (aap-demo.sh:1106-1113), so collapsing them here would silently change
what a fresh deploy leaves behind on a machine without ``oc``.

*Three* shapes have to be recognized, though, not two — see
:func:`shared_binding_name` for the one a live MicroShift 4.22 cluster
actually produces, which bash knows nothing about.

Both grants are attempted even when the first fails, matching bash: it sets
``_rc=1`` and keeps going rather than returning early, so a user who is
missing only ``privileged`` still gets ``anyuid`` and sees both fix hints.
"""

from __future__ import annotations

import shutil
from typing import Callable, List, Optional

from aap_demo.core.context import AppContext

#: The two SCCs, in the order bash grants them.
SCCS = ("anyuid", "privileged")


def group_for(namespace: str) -> str:
    return f"system:serviceaccounts:{namespace}"


def binding_name(scc: str, namespace: str) -> str:
    """The fallback path's ClusterRoleBinding name (aap-demo.sh:2285)."""
    return f"system:openshift:scc:{scc}:{namespace}"


def _grant_with_oc(ctx: AppContext, namespace: str) -> bool:
    ok = True
    for scc in SCCS:
        result = ctx.runner.run(
            ["oc", "adm", "policy", "add-scc-to-group", scc, group_for(namespace)]
        )
        if result.ok:
            continue
        ok = False
        ctx.console.failure(f"Failed to grant {scc} SCC to namespace {namespace}")
        # Bash captures stderr into stdout (``2>&1``) and echoes it verbatim.
        detail = (result.stderr or result.stdout or "").strip()
        ctx.console.out(f"  oc output: {detail}")
        ctx.console.out(
            f"  Fix manually: oc adm policy add-scc-to-group {scc} {group_for(namespace)}"
        )
    return ok


def _grant_with_kubectl(ctx: AppContext, namespace: str) -> bool:
    ctx.console.out("  'oc' not found — granting SCCs via kubectl...")
    ok = True
    for scc in SCCS:
        name = binding_name(scc, namespace)
        if ctx.runner.run(["kubectl", "get", "clusterrolebinding", name]).ok:
            continue
        created = ctx.runner.run(
            [
                "kubectl",
                "create",
                "clusterrolebinding",
                name,
                f"--clusterrole=system:openshift:scc:{scc}",
                f"--group={group_for(namespace)}",
            ]
        )
        if not created.ok:
            ok = False
            ctx.console.failure(f"Failed to create ClusterRoleBinding for {scc} SCC")
    return ok


def grant_namespace_sccs(
    ctx: AppContext,
    namespace: Optional[str] = None,
    *,
    which: Callable[[str], Optional[str]] = shutil.which,
) -> bool:
    """Ports ``_grant_sccs`` — returns False where bash returned ``_rc=1``."""
    ns = namespace or ctx.namespace
    if which("oc") is not None:
        return _grant_with_oc(ctx, ns)
    return _grant_with_kubectl(ctx, ns)


def oc_env_path(
    ctx: AppContext, *, which: Callable[[str], Optional[str]] = shutil.which
) -> Optional[str]:
    """Ports the ``crc oc-env`` PATH prepend in ``setup_namespace`` (aap-demo.sh:2318-2322).

    Bash only reaches for CRC's bundled ``oc`` when ``oc`` is missing but
    ``crc`` is present, and it takes the *first* directory of the first
    ``PATH=`` line ``crc oc-env`` prints. Returned rather than exported so the
    caller can decide how to fold it into the runner's environment — a Python
    process has no ambient ``export`` for its children (see cluster/preflight).
    """
    if which("oc") is not None or which("crc") is None:
        return None
    result = ctx.runner.run(["crc", "oc-env"])
    if not result.ok:
        return None
    for line in result.stdout.splitlines():
        if "PATH=" not in line:
            continue
        _, _, rest = line.partition("PATH=")
        candidate = rest.strip().strip('"').split(":")[0]
        if candidate:
            return candidate
    return None


def shared_binding_name(scc: str) -> str:
    """The name a modern ``oc adm policy add-scc-to-group`` actually creates.

    Found on a live MicroShift 4.22 cluster during phase-3 validation, and it
    is a *third* shape neither bash's grant paths nor ``cmd_diagnose``'s two
    detections know about. ``oc`` no longer edits the SCC object's ``groups``
    list (``kubectl get scc anyuid -o jsonpath='{.groups}'`` still reports only
    ``system:cluster-admins`` after a successful grant). Instead it appends the
    group to the subjects of one cluster-wide ClusterRoleBinding per SCC::

        system:openshift:scc:anyuid -> [system:serviceaccounts:<ns>, …]

    which is neither ``.groups`` (aap-demo.sh:1106) nor the per-namespace
    ``system:openshift:scc:<scc>:<ns>`` the kubectl fallback creates
    (aap-demo.sh:2285). A ``diagnose`` that checks only the first two reports a
    false "SCCs not granted" on this cluster.
    """
    return f"system:openshift:scc:{scc}"


def grant_present(ctx: AppContext, scc: str, namespace: Optional[str] = None) -> bool:
    """True when the group holds ``scc`` by *any* of the three grant shapes."""
    import json

    ns = namespace or ctx.namespace
    group = group_for(ns)

    groups = ctx.runner.run(["kubectl", "get", "scc", scc, "-o", "jsonpath={.groups}"])
    if groups.ok and group in groups.stdout:
        return True

    if ctx.runner.run(["kubectl", "get", "clusterrolebinding", binding_name(scc, ns)]).ok:
        return True

    shared = ctx.runner.run(
        ["kubectl", "get", "clusterrolebinding", shared_binding_name(scc), "-o", "json"]
    )
    if not shared.ok:
        return False
    try:
        document = json.loads(shared.stdout or "{}")
    except ValueError:
        return False
    return any(subject.get("name") == group for subject in (document.get("subjects") or []))


__all__: List[str] = [
    "SCCS",
    "binding_name",
    "grant_namespace_sccs",
    "grant_present",
    "group_for",
    "oc_env_path",
    "shared_binding_name",
]
