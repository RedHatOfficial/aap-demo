"""Pre-provisioned PVCs for the operator-managed workloads.

Ports ``_ensure_aap_storage_pvcs`` (aap-demo.sh:2400-2422). The operator would
otherwise create postgres and hub-redis PVCs against the cluster *default*
StorageClass, which on this cluster is ``topolvm-provisioner``; creating them
first, bound to ``nfs-local-rwx``, is how RWX storage gets used without making
it the cluster default.

The whole thing is a no-op when ``nfs-local-rwx`` does not exist — bash
returns 0 silently there, and so does this. Standing up the NFS server itself
is ``crc-create.sh``'s job and therefore phase 4.
"""

from __future__ import annotations

from typing import Any, Optional

from aap_demo import data
from aap_demo.core.context import AppContext
from aap_demo.exec import kubectl

STORAGE_CLASS = "nfs-local-rwx"
PVC_MANIFEST = "aap-storage-pvcs.yaml"


def render_pvcs(template: str, *, namespace: str, aap_name: str) -> str:
    """Ports the ``sed -e s/__NAMESPACE__/…/g -e s/__AAP_NAME__/…/g`` pipeline.

    Kept as literal placeholder substitution rather than YAML manipulation:
    unlike the CR and OLM edits (§14 R6), these placeholders are *designed*
    substitution points that appear inside composed names
    (``postgres-15-__AAP_NAME__-postgres-15-0``), not values a YAML path could
    address.
    """
    return template.replace("__NAMESPACE__", namespace).replace("__AAP_NAME__", aap_name)


def has_rwx_class(ctx: AppContext) -> bool:
    return kubectl.exists(ctx.runner, "sc", STORAGE_CLASS)


def ensure_aap_pvcs(ctx: AppContext, *, aap_name: str, namespace: Optional[str] = None) -> bool:
    """Returns True when the PVCs were applied, False when skipped."""
    ns = namespace or ctx.namespace
    if not has_rwx_class(ctx):
        return False
    ctx.console.progress("Ensuring postgres and hub-redis PVCs use nfs-local-rwx")
    manifest = render_pvcs(data.read(data.MANIFESTS, PVC_MANIFEST), namespace=ns, aap_name=aap_name)
    kubectl.apply_stdin(ctx.runner, manifest)
    return True


def pending_pvcs(ctx: AppContext, namespace: Optional[str] = None) -> Any:
    """Names of PVCs stuck in ``Pending`` — the ``.claude/CLAUDE.md`` symptom."""
    ns = namespace or ctx.namespace
    raw = kubectl.jsonpath(
        ctx.runner,
        "pvc",
        "-n",
        ns,
        path='{range .items[?(@.status.phase=="Pending")]}{.metadata.name}{"\\n"}{end}',
    )
    return [line.strip() for line in raw.splitlines() if line.strip()]


__all__ = [
    "PVC_MANIFEST",
    "STORAGE_CLASS",
    "ensure_aap_pvcs",
    "has_rwx_class",
    "pending_pvcs",
    "render_pvcs",
]
