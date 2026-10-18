"""Persisted fleet options. The namespace default lives in ``images.NAMESPACE``."""

from __future__ import annotations

from typing import Any, Dict, List

from aap_demo.addons.fleet import images
from aap_demo.core.context import AppContext
from aap_demo.core.errors import UsageError


def fleet_options(ctx: AppContext) -> Dict[str, Any]:
    options = ctx.config.get("addons.options") or {}
    if not isinstance(options, dict):
        return {}
    fleet = options.get("fleet")
    return dict(fleet) if isinstance(fleet, dict) else {}


def save_options(ctx: AppContext, fleet: Dict[str, Any]) -> None:
    options = ctx.config.get("addons.options") or {}
    if not isinstance(options, dict):
        options = {}
    merged = dict(options)
    merged["fleet"] = fleet
    ctx.config.set("addons.options", merged)
    ctx.config.save()


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


def enabled_names(ctx: AppContext) -> List[str]:
    raw = ctx.config.get("addons.enabled") or []
    if not isinstance(raw, list):
        return []
    return [str(name) for name in raw]


def set_enabled(ctx: AppContext, present: bool) -> None:
    names = enabled_names(ctx)
    if present and "fleet" not in names:
        names.append("fleet")
    if not present:
        names = [name for name in names if name != "fleet"]
    ctx.config.set("addons.enabled", names)


def require_os(os_id: str) -> None:
    if os_id not in images.IMAGES:
        raise UsageError(
            f"unknown OS {os_id!r}",
            hint="OS ids: " + ", ".join(images.OS_IDS),
        )
