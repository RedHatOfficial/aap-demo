"""Day-2 playbook commands — phase 0 stubs (the day2 package lands in phase 6b).

Named ``day2`` rather than ``playbooks`` because ``cli/ops.py`` already carries
idle/ssh/config; the user-facing noun everywhere is still "playbooks".
"""

from __future__ import annotations

import argparse

from aap_demo.core.context import AppContext
from aap_demo.core.errors import NotImplementedYetError


def playbooks(ctx: AppContext, args: argparse.Namespace) -> int:
    action = getattr(args, "playbooks_action", None) or ""
    raise NotImplementedYetError(f"playbooks {action}".strip())
