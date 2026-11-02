"""Attach a subscription manifest to AAP, when the user has agreed to.

Attaching uses up the subscription's capacity, so it is off by default. See
ADR-036. The manifest is a credential: it is read only to send it to this AAP
over a verified connection, and its content never reaches logs or errors.
"""

from __future__ import annotations

import base64
import json
import ssl
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Tuple

from aap_demo.core import prompts
from aap_demo.core.context import AppContext
from aap_demo.core.paths import Paths, display_path

MANIFEST_GLOB = "manifest*.zip"
MANIFEST_DOWNLOAD = "https://access.redhat.com/management/subscription_allocations"
CONFIG_PATH = "/api/controller/v2/config/"
REQUEST_TIMEOUT = 90


def locate(configured: str, paths: Paths) -> Optional[Path]:
    """The manifest to use, or None.

    An explicit path wins and is not replaced by a default when it is missing.
    Otherwise the newest match in the config directory, then in the state
    directory. The file is only read, never moved or copied.
    """
    raw = configured.strip()
    if raw:
        path = Path(raw).expanduser()
        return path if path.is_file() else None
    for folder in (paths.config_dir, paths.state_dir):
        found = [path for path in folder.glob(MANIFEST_GLOB) if path.is_file()]
        if found:
            return max(found, key=lambda path: path.stat().st_mtime)
    return None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect must not carry the admin password or the manifest to another host."""

    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _open(request: urllib.request.Request, *, timeout: float, context: ssl.SSLContext) -> Any:
    opener = urllib.request.build_opener(_NoRedirect, urllib.request.HTTPSHandler(context=context))
    return opener.open(request, timeout=timeout)


def _call(
    route: str,
    password: str,
    cafile: Path,
    *,
    body: Optional[bytes] = None,
    opener: Callable[..., Any] = _open,
) -> Tuple[int, Dict[str, Any]]:
    token = base64.b64encode(f"admin:{password}".encode()).decode()
    request = urllib.request.Request(
        f"https://{route}{CONFIG_PATH}",
        data=body,
        headers={"Authorization": f"Basic {token}", "Content-Type": "application/json"},
    )
    context = ssl.create_default_context(cafile=str(cafile))
    try:
        with opener(request, timeout=REQUEST_TIMEOUT, context=context) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as exc:
        status, raw = exc.code, exc.read()
    try:
        parsed = json.loads(raw or b"{}")
    except ValueError:
        parsed = {}
    return status, parsed if isinstance(parsed, dict) else {}


def _agreed(ctx: AppContext, manifest: Path, shown: str, read: Callable[[str], str]) -> bool:
    if ctx.config.get("deploy.auto_license", False):
        return True
    # --yes answers the tool's own questions. It doesn't agree to spend a license.
    if ctx.assume_yes or not prompts.can_ask(ctx.env):
        ctx.console.note(f"AAP has no subscription. Found {shown}, and did not apply it.")
        ctx.console.note("To apply it: aap-demo deploy --auto-license")
        return False
    return prompts.confirm(
        f"Apply {manifest.name} to this AAP? It uses capacity from your subscription. [y/N]: ",
        read=read,
    )


def ensure(
    ctx: AppContext,
    *,
    route: str,
    password: str,
    read: Callable[[str], str] = input,
    opener: Callable[..., Any] = _open,
) -> None:
    """Never fails the deploy: AAP works without a subscription."""
    cafile = ctx.paths.ingress_ca
    if not route or not password or not cafile.is_file():
        return
    try:
        status, current = _call(route, password, cafile, opener=opener)
        if status != 200:
            ctx.console.warn(f"Could not read the AAP subscription: HTTP {status}")
            return
        info = current.get("license_info")
        if isinstance(info, dict) and info.get("valid_key"):
            return

        configured = str(ctx.config.get("deploy.manifest_path", "") or "")
        manifest = locate(configured, ctx.paths)
        home = Path(ctx.env.get("HOME") or Path.home())
        if manifest is None:
            if configured.strip():
                ctx.console.warn(f"Subscription manifest not found: {configured}")
            folder = display_path(ctx.paths.config_dir, home)
            ctx.console.note("AAP has no subscription, so it can't register hosts yet.")
            ctx.console.note(f"Save a manifest in {folder}/ or pass --manifest PATH.")
            ctx.console.note(
                f"Then run aap-demo deploy --auto-license. Get one: {MANIFEST_DOWNLOAD}"
            )
            return

        shown = display_path(manifest, home)
        if manifest.stat().st_mode & 0o077:
            ctx.console.warn(f"{shown} is readable by other users. Run: chmod 600 {shown}")
        if not _agreed(ctx, manifest, shown, read):
            return

        ctx.console.progress(f"Applying the subscription manifest {shown}")
        encoded = base64.b64encode(manifest.read_bytes()).decode()
        body = json.dumps({"manifest": encoded, "eula_accepted": True}).encode()
        status, result = _call(route, password, cafile, body=body, opener=opener)
    except (OSError, ssl.SSLError) as exc:
        # The reason only: nothing here holds the manifest or the password.
        ctx.console.warn(f"Could not apply a subscription: {type(exc).__name__}")
        return
    if status == 200 and result.get("valid_key"):
        ctx.console.checkpoint(f"Subscription applied: {result.get('subscription_name', '')}")
        return
    reason = str(result.get("error") or result.get("detail") or f"HTTP {status}")
    ctx.console.warn(f"AAP did not accept {shown}: {reason}")
    ctx.console.note("Check that it holds a subscription that is active today.")


__all__ = ["MANIFEST_GLOB", "ensure", "locate"]
