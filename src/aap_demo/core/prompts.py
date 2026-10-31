"""Interactive confirmations (design §2.1 ``core/prompts.py``).

Bash's destructive-action gate is ``read -t 10 -r || true`` (aap-demo.sh:748,
1930): it prints what is about to be destroyed, waits ten seconds for Enter,
and *proceeds anyway* on timeout. Ctrl+C is the only way to say no. That is
reproduced exactly rather than "improved" into a y/N prompt, because scripts
and CI already rely on the auto-continue, and ``QUIET`` already disables it.
"""

from __future__ import annotations

import sys
from typing import Any, Callable, Optional


def _wait_for_enter(seconds: float) -> None:
    """Block for up to ``seconds`` waiting on a line from stdin.

    ``select`` on a non-tty or a closed stdin returns immediately, which is
    the behavior bash's ``read -t`` has there too.
    """
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


__all__ = ["timed_continue"]
