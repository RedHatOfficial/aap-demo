"""Read-only observation commands (design §2.2, §3.3 phase 1)."""

from __future__ import annotations

import argparse

from aap_demo.cluster import runtime as runtime_mod
from aap_demo.cluster import status as status_mod
from aap_demo.core import output
from aap_demo.core.context import AppContext
from aap_demo.core.output import is_structured
from aap_demo.diagnostics import checks as diagnose_checks
from aap_demo.diagnostics import report as diagnose_report


def status(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_status`` (aap-demo.sh:1685-1884).

    Bash also runs ``_check_for_updates`` (aap-demo.sh:2792) before ``status``.
    That is **deliberately deferred**, not forgotten: §12.3 replaces the
    ``git fetch``-and-prompt mechanism with a release-manifest check
    (``core/updater.py``, §10.5) that only exists once the ``update`` command
    and the signed-release pipeline do — phase 2/3 work. Porting the git
    version now would build the thing the design deletes.
    """
    report = status_mod.gather(ctx)
    if not is_structured(ctx.output):
        # status_mod.render_text writes through the console directly, since it
        # colors specific tokens inline (e.g. the cluster state word) rather
        # than whole lines — output.render's text branch assumes the latter.
        status_mod.render_text(ctx.console, report)
    else:
        output.render(ctx.console, report.as_dict(), output=ctx.output)
    return 0


def watch(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``watch_aap``."""
    del args
    return runtime_mod.watch(ctx)


def diagnose(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_diagnose``, including ``--ai`` when the flag is set."""
    report = diagnose_checks.run(ctx.runner, ctx.namespace)

    if is_structured(ctx.output):
        output.render(ctx.console, report.as_dict(), output=ctx.output)
    else:
        diagnose_report.render_text(ctx.console, report)

    # Bash returns 1 *only* when kubectl cannot connect (aap-demo.sh:1046):
    # issues found on a reachable cluster still exit 0. That is deliberate,
    # not an oversight — §3.4 requires exit codes 0/1/2 stay "exactly as today
    # for anything scripted against the tool", and scripts today read
    # `diagnose`'s status as "did we get a report?", not "is everything
    # green?". Callers that want the issue count read --output json.
    status = 1 if not report.cluster_reachable else 0
    if getattr(args, "ai", False):
        ai_status = runtime_mod.analyze(ctx)
        if ai_status != 0:
            return ai_status
    return status


def must_gather(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_must_gather``."""
    return runtime_mod.must_gather(ctx, getattr(args, "dest", None))
