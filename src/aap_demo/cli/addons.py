"""Addon commands — phase 0 stubs (the addon platform lands in phase 5+6)."""

from __future__ import annotations

import argparse

from aap_demo.core.context import AppContext
from aap_demo.core.errors import NotImplementedYetError


def enable(ctx: AppContext, args: argparse.Namespace) -> int:
    raise NotImplementedYetError("enable")


def disable(ctx: AppContext, args: argparse.Namespace) -> int:
    raise NotImplementedYetError("disable")


def addon(ctx: AppContext, args: argparse.Namespace) -> int:
    action = getattr(args, "addon_action", None) or "addon"
    raise NotImplementedYetError(f"addon {action}".strip())
