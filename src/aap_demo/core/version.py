"""Package version plus git build metadata when running from a checkout.

Git metadata is meaningful only from a source tree; an installed wheel reports
its site-packages location instead. Nothing here may raise when ``git`` is
absent — the bash helper already fell back to "unknown" and that behavior is
preserved.

An install from a git URL (``pipx install git+https://...@ref``) carries the
same version number as the release it was branched from, so the version alone
cannot tell them apart. pip records where the package came from in
``direct_url.json`` (PEP 610); that record supplies the commit and the URL.
"""

from __future__ import annotations

import json
import platform
import sys
from dataclasses import asdict, dataclass
from importlib import metadata
from pathlib import Path
from typing import Any, Dict, Optional

import aap_demo
from aap_demo import __version__

UNKNOWN = "unknown"
DIST_NAME = "aap-demo"


@dataclass(frozen=True)
class VersionInfo:
    version: str
    source: str
    install_mode: str  # "checkout" | "package" | "git" | "local" | "archive"
    full_version: str = ""
    installed_from: str = ""
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


def _direct_url() -> Dict[str, Any]:
    """pip's PEP 610 record for this install, or {} for an index install."""
    try:
        raw = metadata.distribution(DIST_NAME).read_text("direct_url.json")
    except Exception:  # noqa: BLE001 - metadata missing must never crash `version`
        return {}
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def direct_source(record: Optional[Dict[str, Any]] = None) -> Dict[str, str]:
    """``mode``, ``spec`` and ``sha`` for a git, local-path or archive-URL install, else {}.

    ``spec`` is the ``git+URL@ref`` string a user would pass to pipx again.
    """
    data = _direct_url() if record is None else record
    url = str(data.get("url") or "")
    if not url:
        return {}
    vcs = data.get("vcs_info")
    if isinstance(vcs, dict) and vcs.get("vcs") == "git":
        commit = str(vcs.get("commit_id") or "")
        ref = str(vcs.get("requested_revision") or "")
        spec = f"git+{url}@{ref}" if ref else f"git+{url}"
        return {"mode": "git", "spec": spec, "sha": commit[:7] or UNKNOWN}
    if isinstance(data.get("dir_info"), dict):
        return {"mode": "local", "spec": url, "sha": UNKNOWN}
    return {"mode": "archive", "spec": url, "sha": UNKNOWN}


def display_version(sha: str = UNKNOWN) -> str:
    """The package version, with ``+g<sha>`` when it was built from a commit."""
    if sha and sha != UNKNOWN:
        return f"{__version__}+g{sha}"
    return __version__


def short_version() -> str:
    """``-V``: no git call, only pip's record of a git install."""
    return display_version(direct_source().get("sha", UNKNOWN))


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
        direct = direct_source()
        sha = direct.get("sha", UNKNOWN)
        return VersionInfo(
            source=str(Path(aap_demo.__file__).resolve().parent),
            install_mode=direct.get("mode", "package"),
            full_version=display_version(sha),
            installed_from=direct.get("spec", ""),
            git_sha=sha,
            **common,
        )
    if runner is None:
        from aap_demo.exec.runner import SubprocessRunner

        runner = SubprocessRunner()
    sha = _git(runner, root, ["rev-parse", "--short", "HEAD"])
    return VersionInfo(
        source=str(root),
        install_mode="checkout",
        full_version=display_version(sha),
        git_sha=sha,
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
    lines = [f"aap-demo {info.full_version or info.version}"]
    if info.install_mode == "git":
        lines.append(f"  commit:   {info.git_sha}")
        lines.append(f"  from:     {info.installed_from}")
        lines.append("  note:     a git install, not the published release")
    elif info.install_mode == "local":
        lines.append(f"  from:     {info.installed_from}")
        lines.append("  note:     a local path install, not the published release")
    elif info.install_mode == "archive":
        lines.append(f"  from:     {info.installed_from}")
        lines.append("  note:     installed from a file URL, not the package index")
    if info.install_mode == "checkout":
        lines.append(f"  commit:   {info.git_sha} ({info.git_branch})")
        lines.append(f"  built:    {info.git_date}")
    lines.append(f"  source:   {info.source}")
    lines.append(f"  python:   {info.python} ({sys.executable})")
    lines.append(f"  platform: {info.platform}")
    return "\n".join(lines)
