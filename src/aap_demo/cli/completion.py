"""``aap-demo completion`` — phase 0 stub.

bash/zsh completion is backed by argcomplete over the argparse parser; fish and
PowerShell get hand-written scripts shipped as package data (design §3.1).
"""

from __future__ import annotations

import argparse

from aap_demo.core.context import AppContext
from aap_demo.core.errors import NotImplementedYetError


def completion(ctx: AppContext, args: argparse.Namespace) -> int:
    raise NotImplementedYetError("completion")
