"""Addon commands. Only ``fleet`` is implemented."""

from __future__ import annotations

import argparse

from aap_demo.addons import get, names
from aap_demo.core.context import AppContext
from aap_demo.core.errors import NotImplementedYetError, UsageError


def enable(ctx: AppContext, args: argparse.Namespace) -> int:
    addon_name = getattr(args, "addon", None)
    if not addon_name:
        for name in names():
            ctx.console.out(name)
        return 0
    return int(get(addon_name).enable(ctx, args) or 0)


def disable(ctx: AppContext, args: argparse.Namespace) -> int:
    addon_name = getattr(args, "addon", None)
    if not addon_name:
        raise UsageError(
            "disable needs an addon name",
            hint="Implemented addons: " + ", ".join(names()),
        )
    return int(get(addon_name).disable(ctx, args) or 0)


def addon(ctx: AppContext, args: argparse.Namespace) -> int:
    action = getattr(args, "addon_action", None) or "addon"
    raise NotImplementedYetError(f"addon {action}".strip())
