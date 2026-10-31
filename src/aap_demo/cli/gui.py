"""``aap-demo gui`` — phase 0 stub (the GUI lands in phase 7)."""

from __future__ import annotations

import argparse

from aap_demo.core.context import AppContext
from aap_demo.core.errors import NotImplementedYetError


def gui(ctx: AppContext, args: argparse.Namespace) -> int:
    raise NotImplementedYetError("gui")
