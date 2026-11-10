"""Persisted fleet options. The namespace default lives in ``images.NAMESPACE``."""

from __future__ import annotations

from typing import Any, Dict, List

from aap_demo.addons.common import state as addon_state
from aap_demo.addons.common.state import enabled_names
from aap_demo.addons.fleet import images
from aap_demo.core.context import AppContext
from aap_demo.core.errors import UsageError


def fleet_options(ctx: AppContext) -> Dict[str, Any]:
    return addon_state.options_for(ctx, "fleet")


def save_options(ctx: AppContext, fleet: Dict[str, Any]) -> None:
    addon_state.save_options_for(ctx, "fleet", fleet)


def namespace_token_for(ctx: AppContext) -> str:
    return str(fleet_options(ctx).get("namespace_token") or "")


def remember_namespace_token(ctx: AppContext, token: str) -> None:
    """Record the token without marking Fleet enabled or rewriting its nodes."""
    fleet = fleet_options(ctx)
    if fleet.get("namespace_token") == token:
        return
    fleet["namespace_token"] = token
    save_options(ctx, fleet)


def namespace_uid_for(ctx: AppContext, key: str) -> str:
    return str(fleet_options(ctx).get(key) or "")


def remember_namespace_uid(ctx: AppContext, key: str, uid: str) -> None:
    """Record the API server UID. It cannot be copied onto another namespace."""
    if not uid:
        return
    fleet = fleet_options(ctx)
    if fleet.get(key) == uid:
        return
    fleet[key] = uid
    save_options(ctx, fleet)


def forget_cluster_state(ctx: AppContext) -> None:
    """Drop what described a cluster that no longer exists.

    The node list stays, so the next ``enable fleet`` builds the same nodes.
    """
    fleet = fleet_options(ctx)
    stale = [
        key
        for key in ("namespace_token", "namespace_uid", "runner_namespace_uid", "import")
        if key in fleet
    ]
    was_enabled = "fleet" in enabled_names(ctx)
    if not stale and not was_enabled:
        return
    for key in stale:
        del fleet[key]
    if was_enabled:
        set_enabled(ctx, False)
    save_options(ctx, fleet)


def forget_namespace_uid(ctx: AppContext, key: str) -> None:
    """The namespace is gone, so its UID can't describe anything on this cluster."""
    fleet = fleet_options(ctx)
    if key in fleet:
        del fleet[key]
        save_options(ctx, fleet)


def namespace_for(ctx: AppContext) -> str:
    raw = fleet_options(ctx).get("namespace")
    text = str(raw).strip() if raw else ""
    return text or images.NAMESPACE


def disk_size_for(ctx: AppContext) -> str:
    raw = fleet_options(ctx).get("disk_size")
    text = str(raw).strip() if raw else ""
    return text or images.DISK_SIZE


def storage_class_for(ctx: AppContext) -> str:
    """Empty means the cluster default StorageClass. The playbook omits the field."""
    raw = fleet_options(ctx).get("storage_class")
    return str(raw).strip() if raw else ""


def nodes_of(ctx: AppContext) -> List[Dict[str, str]]:
    raw = fleet_options(ctx).get("nodes") or []
    if not isinstance(raw, list):
        return []
    nodes = []
    for item in raw:
        if isinstance(item, dict) and item.get("name") and item.get("os"):
            nodes.append({"name": str(item["name"]), "os": str(item["os"])})
    return nodes


def set_enabled(ctx: AppContext, present: bool) -> None:
    """Add or remove fleet in ``addons.enabled``. The caller saves config."""
    names = enabled_names(ctx)
    if present and "fleet" not in names:
        names.append("fleet")
    if not present:
        names = [name for name in names if name != "fleet"]
    addon_state.set_enabled_names(ctx, names, save=False)


def validate_certs_for(ctx: AppContext) -> bool:
    """Certificate checks stay on unless the operator turns them off."""
    raw = fleet_options(ctx).get("validate_certs", True)
    if isinstance(raw, str):
        return raw.strip().lower() not in {"0", "false", "no"}
    return bool(raw)


def ca_path_for(ctx: AppContext) -> str:
    path = ctx.paths.ingress_ca
    return str(path) if path.is_file() else ""


def require_os(os_id: str) -> None:
    if os_id not in images.IMAGES:
        raise UsageError(
            f"unknown OS {os_id!r}",
            hint="OS ids: " + ", ".join(images.OS_IDS),
        )
