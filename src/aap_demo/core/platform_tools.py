"""Platform-specific external tool discovery shared by setup and addons."""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Callable, List, Optional


def find_bash(
    which: Callable[[str], Optional[str]] = shutil.which,
    *,
    windows: Optional[bool] = None,
) -> Optional[str]:
    """Find Git Bash on Windows without selecting the WSL System32 launcher."""
    is_windows = os.name == "nt" if windows is None else windows
    if not is_windows:
        return which("bash")

    candidates: List[Path] = []
    for root in (
        os.environ.get("ProgramFiles"),
        os.environ.get("ProgramFiles(x86)"),
        os.environ.get("LOCALAPPDATA"),
    ):
        if root:
            base = Path(root)
            candidates.extend(
                (base / "Git" / "bin" / "bash.exe", base / "Programs" / "Git" / "bin" / "bash.exe")
            )

    git = which("git")
    if git:
        git_path = Path(git)
        candidates.extend(
            (git_path.parent / "bash.exe", git_path.parent.parent / "bin" / "bash.exe")
        )
    candidates.extend((which("bash.exe"), which("bash")))

    for candidate in candidates:
        if not candidate:
            continue
        path = Path(candidate)
        normalized = str(path).replace("/", "\\").lower()
        if normalized.endswith("\\windows\\system32\\bash.exe"):
            continue
        if path.is_file():
            return str(path.resolve())
    return None


def find_bash_tool(
    name: str,
    which: Callable[[str], Optional[str]] = shutil.which,
    *,
    windows: Optional[bool] = None,
) -> Optional[str]:
    """Find a Git-for-Windows utility shipped beside the selected Bash."""
    is_windows = os.name == "nt" if windows is None else windows
    if not is_windows or Path(name).name != name:
        return None
    bash = find_bash(which, windows=True)
    if not bash:
        return None
    candidate = Path(bash).resolve().parent.parent / "usr" / "bin" / f"{name}.exe"
    return str(candidate.resolve()) if candidate.is_file() else None
