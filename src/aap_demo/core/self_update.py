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
    """Upgrade the pipx install and say whether the version changed."""
    info = version_info(ctx.runner)
    pipx = shutil.which("pipx")
    if not pipx:
        raise PrerequisiteError(
            "pipx is not on PATH",
            hint="Install pipx, then run: pipx install aap-demo",
        )

    ctx.console.tasks(list(STEPS), title=TITLE)
    ctx.console.step(STEPS[0])
    source, before = _installed_source(ctx, pipx)
    if info.install_mode == "checkout":
        ctx.console.warn(
            "This command is a source checkout. "
            "The update applies to the pipx install, not this tree."
        )
    direct = _is_direct_source(source)
    if direct:
        ctx.console.warn(
            f"This install tracks {source}, not the published release. "
            "To switch back: pipx install --force aap-demo"
        )
    ctx.console.checkpoint(f"Installed {before or info.version}")

    ctx.console.step(STEPS[1], timed=True)
    result = _run_pipx(ctx, [pipx, "upgrade", PACKAGE], timeout=UPGRADE_TIMEOUT, action="upgrade")
    output = " ".join(f"{result.stdout or ''} {result.stderr or ''}".split())
    if result.returncode != 0:
        raise AapDemoError(
            f"pipx upgrade exited {result.returncode}",
            hint=output or "Run: pipx upgrade aap-demo",
        )
    _source, after = _installed_source(ctx, pipx)
    ctx.console.checkpoint("pipx finished")
    ctx.console.finish_checklist()
    ctx.console.success(
        _summary(before or info.version, after, output, direct=direct, source=source)
    )
    ctx.console.next_steps([("aap-demo version", "Show the installed release")])
    return 0


def _summary(before: str, after: Optional[str], output: str, *, direct: bool, source: str) -> str:
    """One line that says whether anything changed."""
    if after is None:
        upgraded = _UPGRADED.search(output)
        if upgraded:
            before, after = upgraded.group(1), upgraded.group(2)
        else:
            latest = _LATEST.search(output)
            if latest:
                before = after = latest.group(1)
    if after is None:
        return "pipx upgrade finished"
    if after != before:
        return f"Updated {before} to {after}"
    if direct:
        return f"Reinstalled {after} from {source}"
    return f"Already up to date: {after}"


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


def _installed_source(ctx: AppContext, pipx: str) -> tuple[str, Optional[str]]:
    """``(package_or_url, package_version)`` for the pipx app.

    Raises when pipx did not install aap-demo. The version is None when pipx
    does not report one.
    """
    listing = _run_pipx(ctx, [pipx, "list", "--json"], timeout=LIST_TIMEOUT, action="list")
    if not listing.ok:
        detail = (listing.stderr or listing.stdout or "").strip()
        raise AapDemoError("Could not read the pipx install list", hint=detail or None)
    try:
        payload = json.loads(listing.stdout or "")
    except json.JSONDecodeError as exc:
        raise AapDemoError("Could not read the pipx install list") from exc
    source, version, gaps = _package_record(payload)
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
    return source, version


def _package_record(payload: Any) -> tuple[Optional[str], Optional[str], list[str]]:
    """``(package_or_url, package_version, missing field names)`` for aap-demo."""
    venvs = payload.get("venvs") if isinstance(payload, dict) else None
    if not isinstance(venvs, dict):
        return None, None, []
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
        version = main.get("package_version")
        return str(spec), (str(version) if version else None), gaps
    return None, None, []


def _is_direct_source(spec: str) -> bool:
    """True when pipx installed from a URL or a path instead of the PyPI release."""
    text = spec.strip()
    if text in {"", PACKAGE}:
        return False
    return "://" in text or "/" in text or text.startswith((".", "~"))
