"""Update the pipx install of aap-demo.

``aap-demo update`` is the supported upgrade. It checks how this command was
installed, then runs ``pipx upgrade aap-demo``. Later checks belong here, not
in a second command.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from typing import Any, Optional, Sequence

from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, PrerequisiteError
from aap_demo.core.version import version_info
from aap_demo.exec.runner import CompletedCommand

PACKAGE = "aap-demo"
LIST_TIMEOUT = 60.0
UPGRADE_TIMEOUT = 600.0


TITLE = "Updating aap-demo"
STEPS = ("Checking the install", "Upgrading with pipx")

_UPGRADED = re.compile(r"upgraded package aap-demo from (\S+) to (\S+)")
_LATEST = re.compile(r"aap-demo is already at latest version (\S+)")


def run(ctx: AppContext) -> int:
    """Upgrade the pipx install and report how this command was installed."""
    info = version_info(ctx.runner)
    pipx = shutil.which("pipx")
    if not pipx:
        raise PrerequisiteError(
            "pipx is not on PATH",
            hint="Install pipx, then run: pipx install aap-demo",
        )

    ctx.console.tasks(list(STEPS), title=TITLE)
    ctx.console.step(STEPS[0])
    source = _installed_source(ctx, pipx)
    if info.install_mode == "checkout":
        ctx.console.warn(
            "This command is a source checkout. "
            "The update applies to the pipx install, not this tree."
        )
    if _is_direct_source(source):
        ctx.console.warn(
            f"This pipx install tracks {source}. "
            "The published release is: pipx install --force aap-demo"
        )
    ctx.console.checkpoint(f"Installed: {info.version}")

    ctx.console.step(STEPS[1], timed=True)
    result = _run_pipx(ctx, [pipx, "upgrade", PACKAGE], timeout=UPGRADE_TIMEOUT, action="upgrade")
    output = " ".join(f"{result.stdout or ''} {result.stderr or ''}".split())
    if result.returncode != 0:
        raise AapDemoError(
            f"pipx upgrade exited {result.returncode}",
            hint=output or "Run: pipx upgrade aap-demo",
        )
    upgraded = _UPGRADED.search(output)
    latest = _LATEST.search(output)
    if upgraded:
        summary = f"Updated {upgraded.group(1)} to {upgraded.group(2)}"
    elif latest:
        summary = f"Already on the latest release, {latest.group(1)}"
    else:
        summary = "pipx upgrade finished"
    ctx.console.checkpoint("Upgraded with pipx")
    ctx.console.finish_checklist()
    ctx.console.success(summary)
    ctx.console.next_steps([("aap-demo version", "Show the installed release")])
    return 0


def _run_pipx(
    ctx: AppContext,
    argv: Sequence[str],
    *,
    timeout: float,
    action: str,
    capture: bool = True,
) -> CompletedCommand:
    """Run one pipx step. A stall becomes an ``aap-demo update`` error."""
    try:
        return ctx.runner.run(list(argv), capture=capture, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise _timeout_error(action, timeout) from exc
    except AapDemoError as exc:
        if "timed out" not in str(exc):
            raise
        raise _timeout_error(action, timeout) from exc


def _timeout_error(action: str, timeout: float) -> AapDemoError:
    return AapDemoError(
        f"pipx {action} timed out after {int(timeout)}s",
        hint="Check the network, then run aap-demo update again.",
    )


def _installed_source(ctx: AppContext, pipx: str) -> str:
    """``package_or_url`` for the pipx app, or raise when pipx did not install it."""
    listing = _run_pipx(ctx, [pipx, "list", "--json"], timeout=LIST_TIMEOUT, action="list")
    if not listing.ok:
        detail = (listing.stderr or listing.stdout or "").strip()
        raise AapDemoError("Could not read the pipx install list", hint=detail or None)
    try:
        payload = json.loads(listing.stdout or "")
    except json.JSONDecodeError as exc:
        raise AapDemoError("Could not read the pipx install list") from exc
    source, gaps = _package_record(payload)
    if source is None:
        raise AapDemoError(
            "aap-demo is not installed with pipx",
            hint="Install the published release with: pipx install aap-demo",
        )
    if gaps:
        missing = " and ".join(gaps)
        ctx.console.warn(
            f"pipx did not report {missing} for aap-demo, so the install is treated as the "
            "published release. If it tracks a git URL or a path, switch with: "
            "pipx install --force aap-demo"
        )
    return source


def _package_record(payload: Any) -> tuple[Optional[str], list[str]]:
    """``(package_or_url, missing field names)`` for the aap-demo pipx app."""
    venvs = payload.get("venvs") if isinstance(payload, dict) else None
    if not isinstance(venvs, dict):
        return None, []
    for name, env in venvs.items():
        if not isinstance(env, dict):
            continue
        raw_metadata = env.get("metadata")
        metadata = raw_metadata if isinstance(raw_metadata, dict) else {}
        raw_main = metadata.get("main_package")
        main = raw_main if isinstance(raw_main, dict) else {}
        package_name = main.get("package")
        gaps: list[str] = []
        if not package_name:
            gaps.append("package")
            package_name = name
        if str(package_name) != PACKAGE and name != PACKAGE:
            continue
        spec = main.get("package_or_url")
        if not spec:
            gaps.append("package_or_url")
            spec = PACKAGE
        return str(spec), gaps
    return None, []


def _is_direct_source(spec: str) -> bool:
    """True when pipx installed from a URL or a path instead of the PyPI release."""
    text = spec.strip()
    if text in {"", PACKAGE}:
        return False
    return "://" in text or "/" in text or text.startswith((".", "~"))
