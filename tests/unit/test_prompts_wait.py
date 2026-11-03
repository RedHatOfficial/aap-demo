"""The destroy/clean gate waits on Windows too, where select cannot read stdin."""

from __future__ import annotations

import sys

import pytest

from aap_demo.core import prompts


class _Clock:
    def __init__(self) -> None:
        self.now = 0.0
        self.slept = 0.0

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds
        self.slept += seconds


class _Keys:
    """msvcrt stand-in: each key arrives after ``delay`` seconds of polling."""

    def __init__(self, clock: _Clock, keys: list[str], delay: float = 1.0) -> None:
        self.clock = clock
        self.keys = list(keys)
        self.delay = delay

    def kbhit(self) -> bool:
        return bool(self.keys) and self.clock.now >= self.delay

    def getwch(self) -> str:
        return self.keys.pop(0)


class _Tty:
    def __init__(self, tty: bool) -> None:
        self.tty = tty

    def isatty(self) -> bool:
        return self.tty


def test_windows_wait_runs_the_full_timeout_without_a_key(monkeypatch) -> None:
    monkeypatch.setattr(sys, "stdin", _Tty(True))
    clock = _Clock()
    prompts._wait_for_enter_windows(10, msvcrt=_Keys(clock, []), clock=clock)
    assert clock.now >= 10


def test_windows_wait_ends_on_enter_and_ignores_other_keys(monkeypatch) -> None:
    monkeypatch.setattr(sys, "stdin", _Tty(True))
    clock = _Clock()
    keys = _Keys(clock, ["x", "\r", "y"])
    prompts._wait_for_enter_windows(10, msvcrt=keys, clock=clock)
    assert 1 <= clock.now < 2
    assert keys.keys == ["y"]


def test_windows_wait_returns_at_once_without_a_console(monkeypatch) -> None:
    monkeypatch.setattr(sys, "stdin", _Tty(False))
    clock = _Clock()
    prompts._wait_for_enter_windows(10, msvcrt=_Keys(clock, []), clock=clock)
    assert clock.now == 0


def test_wait_for_enter_uses_the_windows_path_on_win32(monkeypatch) -> None:
    calls: list[float] = []
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setattr(prompts, "_wait_for_enter_windows", calls.append)
    prompts._wait_for_enter(10)
    assert calls == [10]


@pytest.mark.skipif(sys.platform == "win32", reason="select path is POSIX only")
def test_wait_for_enter_uses_select_elsewhere(monkeypatch) -> None:
    import select

    seen: list[float] = []

    def fake_select(r, w, x, timeout):
        seen.append(timeout)
        return [], [], []

    monkeypatch.setattr(select, "select", fake_select)
    monkeypatch.setattr(prompts, "_wait_for_enter_windows", lambda s: pytest.fail("windows path"))
    monkeypatch.setattr(sys, "stdin", open(__file__, encoding="utf-8"))
    try:
        prompts._wait_for_enter(3)
    finally:
        sys.stdin.close()
    assert seen == [3]
