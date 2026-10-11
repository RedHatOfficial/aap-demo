"""Update the pipx install of aap-demo.

``aap-demo update`` is the supported upgrade. It checks how this command was
installed, then runs ``pipx upgrade aap-demo``. Later checks belong here, not
in a second command.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from typing import Any, Optional, Sequence

from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, PrerequisiteError
from aap_demo.core.version import version_info

PACKAGE = "aap-demo"
LIST_TIMEOUT = 60.0
UPGRADE_TIMEOUT = 600.0


def run(ctx: AppContext) -> int:
    """Upgrade the pipx install and report how this command was installed."""
    info = version_info(ctx.runner)
    ctx.console.out(f"Current: {info.version}")
    if info.install_mode == "checkout":
        ctx.console.out(
            "This command is a source checkout. "
            "The update applies to the pipx install, not this tree."
        )

    pipx = shutil.which("pipx")
    if not pipx:
        raise PrerequisiteError(
            "pipx is not on PATH",
            hint="Install pipx, then run: pipx install aap-demo",
        )

    source = _installed_source(ctx, pipx)
    if _is_direct_source(source):
        ctx.console.warn(f"This pipx install tracks {source}")
        ctx.console.out("The published release is: pipx install --force aap-demo")

    ctx.console.out("Upgrading the pipx install...")
    result = _run_pipx(
        ctx,
        [pipx, "upgrade", PACKAGE],
        timeout=UPGRADE_TIMEOUT,
        capture=False,
        action="upgrade",
    )
    if result.returncode != 0:
        return result.returncode
    ctx.console.out("Update complete. Run `aap-demo version` to see the installed release.")
    return 0


def _run_pipx(
    ctx: AppContext,
    argv: Sequence[str],
    *,
    timeout: float,
    action: str,
    capture: bool = True,
):
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
    source = _package_or_url(payload)
    if source is None:
        raise AapDemoError(
            "aap-demo is not installed with pipx",
            hint="Install the published release with: pipx install aap-demo",
        )
    return source


def _package_or_url(payload: Any) -> Optional[str]:
    venvs = payload.get("venvs") if isinstance(payload, dict) else None
    if not isinstance(venvs, dict):
        return None
    for name, env in venvs.items():
        if not isinstance(env, dict):
            continue
        raw_metadata = env.get("metadata")
        metadata = raw_metadata if isinstance(raw_metadata, dict) else {}
        raw_main = metadata.get("main_package")
        main = raw_main if isinstance(raw_main, dict) else {}
        package = str(main.get("package") or name)
        if package != PACKAGE and name != PACKAGE:
            continue
        spec = main.get("package_or_url")
        return str(spec) if spec else PACKAGE
    return None


def _is_direct_source(spec: str) -> bool:
    """True when pipx installed from a URL or a path instead of the PyPI release."""
    text = spec.strip()
    if text in {"", PACKAGE}:
        return False
    return "://" in text or "/" in text or text.startswith((".", "~"))
