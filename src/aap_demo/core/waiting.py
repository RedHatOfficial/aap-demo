"""One polling primitive for every long wait (design §14 R5).

R5's finding is that bash's waits use ``kubectl wait … || true``, ``|| true``
around the catalog poll, and bare ``for i in $(seq …)`` loops, so a timeout is
indistinguishable from success at the call site. Every phase-3 wait goes
through :func:`wait_for` instead: it returns a :class:`WaitResult` whose
``ok`` the caller *must* look at, and the clock and the sleep are injected so
the unit tests run in microseconds instead of the real 10-minute budgets.

This module is not in the design's §2.1 tree. It lives in ``core/`` rather
than being duplicated across the seven ``cluster/`` modules that need it,
because R5 asks for exactly one helper with exactly one timeout policy.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Callable, Optional


@dataclass(frozen=True)
class WaitResult:
    """Outcome of a poll loop. ``value`` is the predicate's last return value."""

    ok: bool
    attempts: int
    elapsed: float
    value: Any = None

    def __bool__(self) -> bool:
        return self.ok


class Aborted(Exception):
    """Raised by a predicate that has decided the wait can never succeed.

    Bash's catalog wait exits the loop early when the pod is in a terminal
    image-pull failure rather than burning the remaining ten minutes; this is
    that early exit, kept distinct from an ordinary "not yet".
    """

    def __init__(self, reason: str = "", *, value: Any = None) -> None:
        super().__init__(reason)
        self.reason = reason
        self.value = value


def wait_for(
    predicate: Callable[[int], Any],
    *,
    timeout: float,
    interval: float,
    description: str = "",
    on_attempt: Optional[Callable[[int, float, Any], None]] = None,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> WaitResult:
    """Poll ``predicate(attempt)`` until it returns truthy, or until ``timeout``.

    ``attempt`` is 1-based, matching bash's ``for i in $(seq 1 N)`` so the
    progress lines this replaces keep printing the same numbers. A wait with
    ``timeout == interval * n`` makes exactly ``n`` attempts and ``n - 1``
    sleeps: bash's loop sleeps after its final attempt too, but that sleep can
    only delay the caller's failure message, never change the outcome.
    """
    started = clock()
    attempt = 0
    last: Any = None
    while True:
        attempt += 1
        try:
            last = predicate(attempt)
        except Aborted as abort:
            elapsed = clock() - started
            if on_attempt is not None:
                on_attempt(attempt, elapsed, abort.value)
            return WaitResult(ok=False, attempts=attempt, elapsed=elapsed, value=abort.value)
        elapsed = clock() - started
        if last:
            return WaitResult(ok=True, attempts=attempt, elapsed=elapsed, value=last)
        if on_attempt is not None:
            on_attempt(attempt, elapsed, last)
        if elapsed + interval >= timeout:
            return WaitResult(ok=False, attempts=attempt, elapsed=elapsed, value=last)
        sleep(interval)


__all__ = ["Aborted", "WaitResult", "wait_for"]
