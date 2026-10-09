"""Detect the bash v1 ``aap-demo`` launcher and get it off PATH.

``./install.sh`` symlinks ``~/.local/bin/aap-demo`` to ``aap-demo.sh``. pipx
installs the v2 command at that same path, so a leftover bash launcher earlier
on ``PATH`` still wins. An interactive run can uninstall that launcher or
rename it to ``aap-demo-v1``.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Callable, List, Mapping, Optional, Sequence, TextIO

COMPLETION_RELATIVE = (
    (".zsh", "completions", "_aap-demo"),
    (".local", "share", "bash-completion", "completions", "aap-demo"),
)


def is_bash_v1(path: Path) -> bool:
    """True for the bash CLI, including a symlink to ``aap-demo.sh``."""
    try:
        if path.resolve().name == "aap-demo.sh":
            return True
        text = path.read_text(encoding="utf-8", errors="replace")[:2000]
    except OSError:
        return False
    lines = text.splitlines()
    first = lines[0] if lines else ""
    if "python" in first.lower():
        return False
    return first.startswith("#!") and "bash" in first and "aap-demo" in text


def bash_launchers(env: Mapping[str, str], *, our: Optional[Path] = None) -> List[Path]:
    """Bash v1 ``aap-demo`` entries on ``PATH``, excluding the command now running."""
    our_resolved = _resolve(our) if our is not None else None
    found: List[Path] = []
    seen = set()
    for directory in env.get("PATH", "").split(os.pathsep):
        if not directory:
            continue
        candidate = Path(directory) / "aap-demo"
        resolved = _resolve(candidate)
        if resolved is None or resolved == our_resolved:
            continue
        if resolved in seen or not is_bash_v1(candidate):
            continue
        seen.add(resolved)
        found.append(candidate)
    return found


def rename_launcher(path: Path) -> Path:
    """Point the same symlink or file at the name ``aap-demo-v1``."""
    destination = path.with_name("aap-demo-v1")
    if destination.exists():
        raise FileExistsError(destination)
    path.rename(destination)
    return destination


def uninstall_launcher(path: Path, home: Path) -> List[Path]:
    """Remove the launcher and the completions ``install.sh`` copied in.

    Cluster data and ``~/.aap-demo`` are left in place.
    """
    removed: List[Path] = []
    if path.is_symlink() or path.is_file():
        path.unlink()
        removed.append(path)
    for parts in COMPLETION_RELATIVE:
        completion = home.joinpath(*parts)
        if completion.is_symlink() or completion.is_file():
            completion.unlink()
            removed.append(completion)
    return removed


def offer_cleanup(
    launchers: Sequence[Path],
    home: Path,
    *,
    input_func: Callable[[str], str] = input,
    output: Optional[TextIO] = None,
) -> List[str]:
    """Ask once per launcher. Returns a log of what was done."""
    stream = output if output is not None else sys.stdout
    log: List[str] = []
    for launcher in launchers:
        shown = _display(launcher, home)
        stream.write(f"Bash aap-demo v1 is still on PATH: {shown}\n")
        stream.write("That command runs instead of v2 when it comes first on PATH.\n")
        stream.write("[u]ninstall, [r]ename to aap-demo-v1, or [k]eep: ")
        stream.flush()
        try:
            answer = input_func("").strip().lower()
        except EOFError:
            answer = "k"
        if answer in {"u", "uninstall"}:
            removed = uninstall_launcher(launcher, home)
            stream.write(f"Removed {shown}\n")
            log.append(f"uninstalled {removed[0]}")
        elif answer in {"r", "rename"}:
            try:
                destination = rename_launcher(launcher)
            except FileExistsError:
                existing = _display(destination_of(launcher), home)
                stream.write(f"Left {shown} in place; {existing} already exists\n")
                log.append(f"kept {launcher}")
            else:
                stream.write(f"Renamed {shown} to {_display(destination, home)}\n")
                log.append(f"renamed {destination}")
        else:
            stream.write(f"Left {shown} on PATH. This choice is remembered.\n")
            log.append(f"kept {launcher}")
    return log


def keep_marker(env: Mapping[str, str]) -> Path:
    """Set when the user chooses to leave the bash v1 command on PATH."""
    from aap_demo.core.paths import resolve_paths

    return resolve_paths(env).state_dir / "bash-v1-kept"


def maybe_offer(
    env: Mapping[str, str],
    *,
    our: Optional[Path] = None,
    input_func: Callable[[str], str] = input,
) -> None:
    """Prompt on an interactive terminal. Quiet and non-tty runs do nothing."""
    if env.get("QUIET") or env.get("AAP_DEMO_KEEP_BASH"):
        return
    if keep_marker(env).is_file():
        return
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        return
    home = Path(env.get("HOME") or Path.home())
    launchers = bash_launchers(env, our=our if our is not None else Path(sys.argv[0]))
    if not launchers:
        return
    log = offer_cleanup(launchers, home, input_func=input_func)
    if any(entry.startswith("kept ") for entry in log):
        marker = keep_marker(env)
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("kept\n", encoding="utf-8")


def destination_of(path: Path) -> Path:
    return path.with_name("aap-demo-v1")


def _resolve(path: Path) -> Optional[Path]:
    try:
        if not path.exists():
            return None
        return path.resolve()
    except OSError:
        return None


def _display(path: Path, home: Path) -> str:
    try:
        relative = path.absolute().relative_to(home)
    except ValueError:
        return str(path)
    return "~/" + relative.as_posix()
