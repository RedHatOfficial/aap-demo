"""Read-only observation commands."""

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
    """Ports ``cmd_status``.

    Bash also runs ``_check_for_updates`` before ``status``.
    That is deliberately not ported. The ``git fetch``-and-prompt mechanism is
    meant to be replaced by a release-manifest check, not carried over.
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
    """Ports ``cmd_diagnose``, without bash's ``--ai``."""
    report = diagnose_checks.run(ctx.runner, ctx.namespace)

    if is_structured(ctx.output):
        output.render(ctx.console, report.as_dict(), output=ctx.output)
    else:
        diagnose_report.render_text(ctx.console, report)

    # Bash returns 1 *only* when kubectl cannot connect:
    # issues found on a reachable cluster still exit 0. That is deliberate,
    # not an oversight — exit codes must 0/1/2 stay "exactly as today
    # for anything scripted against the tool", and scripts today read
    # `diagnose`'s status as "did we get a report?", not "is everything
    # green?". Callers that want the issue count read --output json.
    return 1 if not report.cluster_reachable else 0


def must_gather(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_must_gather``."""
    return runtime_mod.must_gather(ctx, getattr(args, "dest", None))
