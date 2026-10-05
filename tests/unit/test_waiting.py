"""``core/waiting.py`` — the one poll primitive (design §14 R5).

Every test here runs on an injected clock; none of them sleep.
"""

from __future__ import annotations

import pytest

from aap_demo.core import waiting


class Clock:
    """A monotonic clock that only advances when ``sleep`` is called."""

    def __init__(self) -> None:
        self.now = 0.0
        self.slept: list = []

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.now += seconds


def test_success_on_the_first_attempt_never_sleeps() -> None:
    clock = Clock()
    result = waiting.wait_for(
        lambda n: "value", timeout=100, interval=5, sleep=clock.sleep, clock=clock
    )
    assert result.ok and result.attempts == 1 and result.value == "value"
    assert clock.slept == []


def test_success_after_several_attempts_reports_the_count_and_elapsed() -> None:
    clock = Clock()
    result = waiting.wait_for(
        lambda n: n >= 4, timeout=100, interval=5, sleep=clock.sleep, clock=clock
    )
    assert result.ok and result.attempts == 4
    assert result.elapsed == pytest.approx(15.0)
    assert clock.slept == [5, 5, 5]


def test_timeout_is_reported_not_swallowed() -> None:
    """The whole point of R5: a timeout must be distinguishable from success."""
    clock = Clock()
    result = waiting.wait_for(
        lambda n: False, timeout=20, interval=5, sleep=clock.sleep, clock=clock
    )
    assert result.ok is False
    assert bool(result) is False
    assert result.attempts == 4
    assert result.elapsed <= 20


def test_the_last_attempt_is_not_followed_by_a_sleep() -> None:
    clock = Clock()
    waiting.wait_for(lambda n: False, timeout=10, interval=5, sleep=clock.sleep, clock=clock)
    assert clock.slept == [5]


def test_on_attempt_fires_only_for_failed_attempts() -> None:
    clock = Clock()
    seen: list = []
    waiting.wait_for(
        lambda n: n == 3,
        timeout=100,
        interval=1,
        on_attempt=lambda n, elapsed, value: seen.append(n),
        sleep=clock.sleep,
        clock=clock,
    )
    assert seen == [1, 2]


def test_aborted_stops_the_loop_immediately() -> None:
    """A predicate that knows the wait can never succeed exits without burning the budget."""
    clock = Clock()

    def predicate(n: int) -> bool:
        if n == 2:
            raise waiting.Aborted("terminal", value="detail")
        return False

    result = waiting.wait_for(predicate, timeout=1000, interval=5, sleep=clock.sleep, clock=clock)
    assert result.ok is False
    assert result.attempts == 2
    assert result.value == "detail"
    assert clock.slept == [5]


def test_aborted_still_notifies_on_attempt() -> None:
    clock = Clock()
    seen: list = []

    def predicate(n: int) -> bool:
        raise waiting.Aborted("nope", value=n)

    waiting.wait_for(
        predicate,
        timeout=10,
        interval=1,
        on_attempt=lambda n, elapsed, value: seen.append(value),
        sleep=clock.sleep,
        clock=clock,
    )
    assert seen == [1]
