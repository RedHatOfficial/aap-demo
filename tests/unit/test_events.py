"""The event/progress abstraction (design §9.4)."""

from __future__ import annotations

import dataclasses

import pytest

from aap_demo.core.console import RecordingConsole
from aap_demo.core.events import EVENT_KINDS, ConsoleSink, Event, EventEmitter, ListSink, NullSink


def test_seq_is_monotonic_per_emitter() -> None:
    """SSE reconnect correctness (Last-Event-ID -> replay_since) falls out of this."""
    sink = ListSink()
    emitter = EventEmitter(sink=sink)
    for i in range(5):
        emitter.log(f"line {i}")
    assert [e.seq for e in sink.events] == [0, 1, 2, 3, 4]


def test_separate_emitters_have_separate_sequences() -> None:
    a, b = ListSink(), ListSink()
    EventEmitter(sink=a).log("x")
    EventEmitter(sink=b).log("y")
    assert a.events[0].seq == b.events[0].seq == 0


def test_events_are_immutable() -> None:
    event = Event(kind="log", ts=0.0, seq=0, text="x")
    with pytest.raises(dataclasses.FrozenInstanceError):
        event.text = "y"  # type: ignore[misc]


def test_unknown_kind_is_rejected() -> None:
    with pytest.raises(ValueError):
        EventEmitter(sink=NullSink()).emit("nonsense", "x")


@pytest.mark.parametrize("kind", EVENT_KINDS)
def test_every_kind_is_emittable(kind: str) -> None:
    sink = ListSink()
    EventEmitter(sink=sink).emit(kind, "text")
    assert sink.events[0].kind == kind


def test_step_carries_its_name() -> None:
    sink = ListSink()
    EventEmitter(sink=sink).step("grant-sccs", "Granting SCCs")
    assert sink.events[0].step == "grant-sccs"
    assert sink.events[0].text == "Granting SCCs"


def test_result_carries_structured_data() -> None:
    sink = ListSink()
    EventEmitter(sink=sink).result({"routes": 3}, text="done")
    assert sink.events[0].data == {"routes": 3}


def test_to_dict_is_serializable() -> None:
    import json

    payload = Event(kind="log", ts=1.0, seq=7, text="x").to_dict()
    assert json.loads(json.dumps(payload))["seq"] == 7


def test_console_sink_routes_kinds_to_the_right_stream() -> None:
    console = RecordingConsole()
    emitter = EventEmitter(sink=ConsoleSink(console))
    emitter.step("build", "Building")
    emitter.progress("halfway")
    emitter.warning("careful")
    emitter.error("boom")
    emitter.result({}, text="finished")

    assert "Building" in console.stdout
    assert "halfway" in console.stdout
    assert "finished" in console.stdout
    assert "careful" in console.stderr
    assert "boom" in console.stderr


def test_console_sink_hides_log_lines_unless_verbose() -> None:
    quiet_console = RecordingConsole()
    EventEmitter(sink=ConsoleSink(quiet_console)).log("chatty")
    assert quiet_console.stdout == ""

    verbose_console = RecordingConsole()
    EventEmitter(sink=ConsoleSink(verbose_console, verbose=True)).log("chatty")
    assert "chatty" in verbose_console.stdout


def test_null_sink_swallows_everything() -> None:
    EventEmitter(sink=NullSink()).log("x")


def test_list_sink_filters_by_kind() -> None:
    sink = ListSink()
    emitter = EventEmitter(sink=sink)
    emitter.log("a")
    emitter.progress("b")
    assert sink.texts("log") == ["a"]
    assert sink.texts() == ["a", "b"]
