"""Addon state in ``config.yaml``: ``addons.enabled`` and ``addons.options.<name>``."""

from __future__ import annotations

from typing import Any, Dict, List

from aap_demo.core.context import AppContext


def enabled_names(ctx: AppContext) -> List[str]:
    raw = ctx.config.get("addons.enabled") or []
    if not isinstance(raw, list):
        return []
    return [str(name) for name in raw]


def set_enabled_names(ctx: AppContext, names: List[str], *, save: bool) -> None:
    """Replace ``addons.enabled``. ``save=False`` leaves writing to the caller."""
    ctx.config.set("addons.enabled", names)
    if save:
        ctx.config.save()


def options_for(ctx: AppContext, name: str) -> Dict[str, Any]:
    """A copy of ``addons.options.<name>``. Empty when unset or malformed."""
    options = ctx.config.get("addons.options") or {}
    if not isinstance(options, dict):
        return {}
    value = options.get(name)
    return dict(value) if isinstance(value, dict) else {}


def save_options_for(ctx: AppContext, name: str, value: Dict[str, Any]) -> None:
    """Write ``addons.options.<name>`` and save, keeping other addons' options."""
    options = ctx.config.get("addons.options") or {}
    if not isinstance(options, dict):
        options = {}
    merged = dict(options)
    merged[name] = value
    ctx.config.set("addons.options", merged)
    ctx.config.save()
