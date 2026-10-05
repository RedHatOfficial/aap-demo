"""Package version plus git build metadata when running from a checkout (§8.2).

Git metadata is meaningful only from a source tree; an installed wheel reports
its site-packages location instead. Nothing here may raise when ``git`` is
absent — the bash helper already fell back to "unknown" and that behavior is
preserved.
"""

from __future__ import annotations

import platform
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Dict, Optional

import aap_demo
from aap_demo import __version__

UNKNOWN = "unknown"


@dataclass(frozen=True)
class VersionInfo:
    version: str
    source: str
    install_mode: str  # "checkout" | "package"
    git_sha: str = UNKNOWN
    git_branch: str = UNKNOWN
    git_date: str = UNKNOWN
    python: str = ""
    platform: str = ""

    def as_dict(self) -> Dict[str, Any]:
        return asdict(self)


def _repo_root() -> Optional[Path]:
    # src/aap_demo/core/version.py -> src/aap_demo -> src -> repo root
    candidate = Path(aap_demo.__file__).resolve().parent.parent.parent
    return candidate if (candidate / ".git").exists() else None


def _git(runner: Any, root: Path, args: list) -> str:
    try:
        result = runner.run(["git", "-C", str(root), *args], capture=True)
    except Exception:  # noqa: BLE001 - git absent or failing must never crash `version`
        return UNKNOWN
    if not result.ok:
        return UNKNOWN
    return result.stdout.strip() or UNKNOWN


def version_info(runner: Any = None) -> VersionInfo:
    root = _repo_root()
    common = {
        "version": __version__,
        "python": platform.python_version(),
        "platform": f"{platform.system()} {platform.machine()}",
    }
    if root is None:
        return VersionInfo(
            source=str(Path(aap_demo.__file__).resolve().parent),
            install_mode="package",
            **common,
        )
    if runner is None:
        from aap_demo.exec.runner import SubprocessRunner

        runner = SubprocessRunner()
    return VersionInfo(
        source=str(root),
        install_mode="checkout",
        git_sha=_git(runner, root, ["rev-parse", "--short", "HEAD"]),
        git_branch=_git(runner, root, ["rev-parse", "--abbrev-ref", "HEAD"]),
        git_date=_git(runner, root, ["log", "-1", "--format=%cI"]),
        **common,
    )


def remote_url(runner: Any = None) -> str:
    """``git remote get-url origin``, or ``UNKNOWN`` outside a checkout (aap-demo-version.sh:21)."""
    root = _repo_root()
    if root is None:
        return UNKNOWN
    if runner is None:
        from aap_demo.exec.runner import SubprocessRunner

        runner = SubprocessRunner()
    return _git(runner, root, ["remote", "get-url", "origin"])


def render_text(info: VersionInfo) -> str:
    lines = [f"aap-demo {info.version}"]
    if info.install_mode == "checkout":
        lines.append(f"  commit:   {info.git_sha} ({info.git_branch})")
        lines.append(f"  built:    {info.git_date}")
    lines.append(f"  source:   {info.source}")
    lines.append(f"  python:   {info.python} ({sys.executable})")
    lines.append(f"  platform: {info.platform}")
    return "\n".join(lines)
