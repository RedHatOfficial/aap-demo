"""Cluster and AAP lifecycle commands (design §12.4).

``deploy``, ``clean``, ``redeploy``, ``setup``, ``create`` and ``destroy`` are
implemented. ``redeploy-all``, ``start``, ``stop`` and ``repair`` stay stubs.
The command functions are thin: every decision lives in ``cluster/``, which
is what lets the GUI reach the same behavior without importing ``cli/`` (§2.2).
"""

from __future__ import annotations

import argparse
import time
from typing import Callable

from aap_demo.cluster import aap as aap_mod
from aap_demo.cluster import bootstrap as bootstrap_mod
from aap_demo.cluster import deploy as deploy_mod
from aap_demo.cluster import runtime as runtime_mod
from aap_demo.cluster import status as status_mod
from aap_demo.core import prompts
from aap_demo.core.context import AppContext
from aap_demo.core.errors import NotImplementedYetError
from aap_demo.core.output import is_structured, render
from aap_demo.infra import crc as infra_crc

#: ``read -t 10`` before the destructive clean (aap-demo.sh:748).
CLEAN_CONFIRM_SECONDS = 10


def create(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``aap-demo create`` for the MicroShift preset."""
    del args
    bootstrap_mod.create(ctx)
    return 0


def deploy(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_deploy`` (aap-demo.sh:2018).

    Exit status follows bash: reaching the CR and then timing out in
    ``watch_aap`` is a failure (bash's ``return 1``), while the
    already-exists short-circuit is a success.
    """
    deploy_mod.ensure_cluster_running(ctx)
    result = deploy_mod.run(ctx, cr_name=getattr(args, "deploy__cr", None) or None)
    if is_structured(ctx.output):
        render(ctx.console, result.as_dict(), output=ctx.output)
    return 0 if (result.ready or result.skipped_existing) else 1


def redeploy(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_redeploy`` (aap-demo.sh:1902): clean, pause, deploy."""
    _clean(ctx)
    time.sleep(2)
    ctx.console.out("")
    ctx.console.out("Redeploying AAP...")
    ctx.console.out("")
    result = deploy_mod.run(ctx, cr_name=getattr(args, "deploy__cr", None) or None)
    if is_structured(ctx.output):
        render(ctx.console, result.as_dict(), output=ctx.output)
    return 0 if result.ready else 1


def redeploy_all(ctx: AppContext, args: argparse.Namespace) -> int:
    raise NotImplementedYetError("redeploy-all")


def setup(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_setup`` (aap-demo.sh:2013), which is one ``echo`` and nothing else.

    The help text still advertises "Run setup only (storage, coredns, mkcert)",
    but that work moved into ``crc-create.sh`` long ago and the command has
    been a pointer ever since. Porting the *advertised* behavior instead of
    the actual behavior would invent a command that has never existed.
    """
    ctx.console.out("CRC setup is handled during 'aap-demo create'")
    return 0


def start(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_start``."""
    del args
    runtime_mod.start(ctx)
    return 0


def stop(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_stop``."""
    del args
    runtime_mod.stop(ctx)
    return 0


def destroy(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_destroy``. ``--reset`` clears the YAML config file."""
    bootstrap_mod.destroy(ctx, reset=bool(getattr(args, "reset", False)))
    return 0


def clean(ctx: AppContext, args: argparse.Namespace) -> int:
    _clean(ctx)
    return 0


def repair(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_repair``."""
    del args
    runtime_mod.repair(ctx)
    return 0


def _clean(ctx: AppContext, *, wait: Callable[[float], None] = None) -> None:  # type: ignore[assignment]
    """Ports ``_clean_operator``'s warning banner plus ``cluster/aap.py::teardown``."""
    ns = ctx.namespace

    from aap_demo.exec import kubectl

    if not kubectl.exists(ctx.runner, "namespace", ns):
        ctx.console.out(f"Namespace {ns} not found - nothing to clean")
        return

    ctx.console.out("")
    ctx.console.out("WARNING: AAP CLEANUP - DESTRUCTIVE OPERATION!")
    ctx.console.out("")
    status_mod.show_cluster_info(ctx)
    ctx.console.out("")

    listing = ctx.runner.run(
        ["kubectl", "get", "aap", "-n", ns, "--no-headers", "--request-timeout=2s"]
    )
    names = [line.split()[0] for line in (listing.stdout or "").splitlines() if line.strip()]
    if names:
        ctx.console.out("  AAP resources that will be DELETED:")
        for name in names:
            ctx.console.out(f"    - {name}")
        ctx.console.out("")

    ctx.console.out(f"This will DELETE the namespace '{ns}' and all resources within it!")
    ctx.console.out("")
    prompts.timed_continue(ctx.console, seconds=CLEAN_CONFIRM_SECONDS, quiet=ctx.quiet, wait=wait)

    import shutil

    steps = ["Deleting the AAP instance", "Deleting the namespace", "Pruning unused images"]
    if shutil.which("operator-sdk") is not None:
        steps.insert(0, "Cleaning up OLM")
    ctx.console.tasks(steps)
    if not aap_mod.teardown(ctx, namespace=ns):
        return
    ctx.console.step("Pruning unused images")
    pruned = infra_crc.prune_images(ctx)
    if pruned:
        ctx.console.checkpoint(f"Pruned {pruned} unused images")
    else:
        ctx.console.checkpoint("No unused images to prune")
    ctx.console.success("AAP operator deployment removed")
