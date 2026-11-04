"""Interactive prompts.

Bash's destructive-action gate is ``read -t 10 -r || true``: it prints what is
about to be destroyed, waits ten seconds for Enter, and *proceeds
anyway* on timeout. Ctrl+C is the only way to say no. That is
reproduced exactly rather than "improved" into a y/N prompt, because scripts
and CI already rely on the auto-continue, and ``QUIET`` already disables it.

``vm_size`` asks for the CRC VM size when ``create`` has a person to ask. See
ADR-034.
"""

from __future__ import annotations

import importlib
import sys
import time
from typing import Any, Callable, Mapping, Optional, Tuple

from aap_demo.core.errors import AapDemoError


def _wait_for_enter_windows(seconds: float, *, msvcrt: Any = None, clock: Any = None) -> None:
    """Windows has no ``select`` on console handles, so poll ``msvcrt`` instead.

    Enter ends the wait early; other keys are read and ignored. A stdin that is
    not a console returns immediately, as ``read -t`` does on a non-tty.
    """
    if msvcrt is None:
        msvcrt = importlib.import_module("msvcrt")
    if clock is None:
        clock = time
    try:
        if not sys.stdin.isatty():
            return
    except (AttributeError, OSError, ValueError):
        return
    deadline = clock.monotonic() + seconds
    while clock.monotonic() < deadline:
        if msvcrt.kbhit():
            if msvcrt.getwch() in ("\r", "\n"):
                return
            continue
        clock.sleep(0.05)


def _wait_for_enter(seconds: float) -> None:
    """Block for up to ``seconds`` waiting on a line from stdin.

    ``select`` on a non-tty or a closed stdin returns immediately, which is
    the behavior bash's ``read -t`` has there too. Windows uses
    :func:`_wait_for_enter_windows`, because ``select`` there only takes sockets.
    """
    if sys.platform == "win32":
        _wait_for_enter_windows(seconds)
        return

    import select

    stream = sys.stdin
    if not hasattr(stream, "fileno"):
        return
    try:
        ready, _, _ = select.select([stream], [], [], seconds)
    except (OSError, ValueError):
        return
    if ready:
        stream.readline()


def timed_continue(
    console: Any,
    *,
    seconds: float = 10,
    quiet: bool = False,
    wait: Optional[Callable[[float], None]] = None,
) -> None:
    """``read -t <seconds>`` — auto-continues; ``KeyboardInterrupt`` cancels."""
    if quiet:
        return
    console.out("Press Ctrl+C to cancel, or press Enter to continue immediately...")
    console.out(f"Auto-continuing in {int(seconds)} seconds...")
    (wait or _wait_for_enter)(seconds)
    console.out("")


def can_ask(env: Mapping[str, str]) -> bool:
    """True with a terminal on both ends, or when ``AAP_DEMO_INTERACTIVE=1`` asks for it."""
    if env.get("AAP_DEMO_INTERACTIVE") == "1":
        return True
    return sys.stdin.isatty() and sys.stdout.isatty()


def _whole_number(label: str, raw: str) -> int:
    if not (raw.isascii() and raw.isdigit()) or int(raw) <= 0:
        raise AapDemoError(f"Invalid {label}: '{raw}'", hint="Enter a positive whole number.")
    return int(raw)


def vm_size(
    console: Any,
    *,
    cpus: int,
    memory_mb: int,
    host: Tuple[int, int],
    read: Callable[[str], str] = input,
) -> Tuple[int, int]:
    """Ask for vCPUs and memory. Enter keeps a default, and end of input keeps them all."""
    host_cpus, host_memory_mb = host
    if host_cpus > 0:
        cpus = min(cpus, host_cpus)
    if host_memory_mb > 0:
        memory_mb = min(memory_mb, host_memory_mb)
    console.out("")
    console.out("Resource allocation for the CRC VM:")
    if host_cpus > 0 and host_memory_mb > 0:
        console.out(f"  Host: {host_cpus} CPUs, {host_memory_mb // 1024}GB RAM")
    try:
        cpu_answer = read(f"  CPUs [{cpus}]: ").strip()
        memory_answer = read(f"  Memory in GB [{memory_mb // 1024}]: ").strip()
    except EOFError:
        console.out("")
        return cpus, memory_mb
    console.out("")
    chosen_cpus = _whole_number("CPU count", cpu_answer) if cpu_answer else cpus
    chosen_memory = (
        _whole_number("memory value", memory_answer) * 1024 if memory_answer else memory_mb
    )
    return chosen_cpus, chosen_memory


def confirm(question: str, *, read: Callable[[str], str] = input) -> bool:
    """Yes only on an explicit yes. Enter and end of input mean no."""
    try:
        answer = read(question).strip().lower()
    except EOFError:
        return False
    return answer in ("y", "yes")


__all__ = ["can_ask", "confirm", "timed_continue", "vm_size"]
