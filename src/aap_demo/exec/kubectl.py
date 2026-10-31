"""Thin ``kubectl`` helpers over the ``CommandRunner`` seam (design §2.1).

Functions, not a client class: every call still goes through the runner the
tests substitute, and the argv stays visible at the call site so a
``FakeRunner`` assertion reads like the bash line it ports. Phase-1's
``cluster/status.py`` predates this module and still builds its argv inline;
it is not retrofitted here because that would mean re-reviewing output the
maintainer already verified byte-for-byte against bash.
"""

from __future__ import annotations

from typing import Any, List, Optional, Sequence


def run(runner: Any, *args: str, **kwargs: Any) -> Any:
    return runner.run(["kubectl", *args], **kwargs)


def cluster_reachable(runner: Any) -> bool:
    """``kubectl cluster-info &>/dev/null``."""
    return bool(run(runner, "cluster-info").ok)


def current_context(runner: Any) -> str:
    result = run(runner, "config", "current-context")
    return result.stdout.strip() if result.ok else ""


def jsonpath(runner: Any, *args: str, path: str, default: str = "") -> str:
    """``kubectl get … -o jsonpath='…' 2>/dev/null || echo "<default>"``."""
    result = run(runner, "get", *args, "-o", f"jsonpath={path}")
    if not result.ok:
        return default
    text = result.stdout.strip()
    return text if text else default


def exists(runner: Any, *args: str) -> bool:
    """``kubectl get … &>/dev/null`` — presence, not content."""
    return bool(run(runner, "get", *args).ok)


def apply_stdin(runner: Any, manifest: str, *extra: str) -> Any:
    """``… | kubectl apply -f -`` with the manifest on stdin, never a temp file."""
    argv: List[str] = ["kubectl", "apply", "-f", "-", *extra]
    return runner.run(argv, input=manifest)


def delete(runner: Any, *args: str, timeout: Optional[str] = None) -> Any:
    argv: Sequence[str] = ["delete", *args]
    if timeout:
        argv = [*argv, f"--timeout={timeout}"]
    return run(runner, *argv)


__all__ = [
    "apply_stdin",
    "cluster_reachable",
    "current_context",
    "delete",
    "exists",
    "jsonpath",
    "run",
]
