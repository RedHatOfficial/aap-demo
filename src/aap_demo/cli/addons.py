"""Addon commands. Only ``fleet`` is implemented."""

from __future__ import annotations

import argparse

from aap_demo.addons import get, names
from aap_demo.core.context import AppContext
from aap_demo.core.errors import NotImplementedYetError, UsageError
from aap_demo.core.output import is_structured, render


def enable(ctx: AppContext, args: argparse.Namespace) -> int:
    addon_name = getattr(args, "addon", None)
    if not addon_name:
        available = list(names())
        if is_structured(ctx.output):
            render(ctx.console, available, output=ctx.output)
            return 0
        for name in available:
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
    action = getattr(args, "addon_action", None)
    command = "addon" if not action else f"addon {action}"
    raise NotImplementedYetError(command)
