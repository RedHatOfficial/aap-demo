"""kubectl helpers that raise ``AddonError`` with kubectl's own output as the hint."""

from __future__ import annotations

import json
from typing import Any, Dict, List, Optional, cast

from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.exec import kubectl


def as_dict(value: Any) -> Dict[str, Any]:
    if isinstance(value, dict):
        return cast(Dict[str, Any], value)
    return {}


def is_missing(detail: str) -> bool:
    """True when kubectl output says the object does not exist."""
    text = detail.lower()
    return "notfound" in text or "not found" in text


def output_of(result: Any) -> str:
    return (result.stderr or result.stdout or "").strip()


def read_object(
    ctx: AppContext, kind: str, name: str, *, namespace: str = ""
) -> Optional[Dict[str, Any]]:
    """The object as a dict, or None when it does not exist. Other errors raise."""
    argv = ["kubectl", "get", kind, name]
    if namespace:
        argv.extend(["-n", namespace])
    argv.extend(["-o", "json"])
    result = ctx.runner.run(argv)
    if not result.ok:
        detail = result.stderr or result.stdout or ""
        if is_missing(detail):
            return None
        raise AddonError(
            f"could not read {kind} {name}",
            hint=detail.strip() or None,
        )
    try:
        document = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise AddonError(f"could not read {kind} {name}", hint=str(exc)) from exc
    return document if isinstance(document, dict) else None


def run_or_raise(ctx: AppContext, argv: List[str], *, message: str) -> None:
    result = ctx.runner.run(argv)
    if not result.ok:
        raise AddonError(message, hint=output_of(result) or None)


def apply_or_raise(ctx: AppContext, manifest: str, *, message: str) -> None:
    applied = kubectl.apply_stdin(ctx.runner, manifest)
    if not applied.ok:
        raise AddonError(message, hint=output_of(applied) or None)
