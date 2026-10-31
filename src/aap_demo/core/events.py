"""The one progress-reporting abstraction (design §9.4).

The core concept is an *event stream*, not an SSE stream. Long-running core
operations need progress reporting for the CLI anyway; defining it once means
the GUI's SSE fan-out, the desktop tray, and the tests all consume the same
thing. ``seq`` is monotonic per emitter because SSE reconnect correctness
(``Last-Event-ID`` → ``replay_since``) falls out of it rather than being bolted
on later.
"""

from __future__ import annotations

import itertools
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Literal, Optional, Protocol

EventKind = Literal["step", "log", "progress", "warning", "error", "result"]

EVENT_KINDS = ("step", "log", "progress", "warning", "error", "result")


@dataclass(frozen=True)
class Event:
    kind: str
    ts: float
    seq: int
    step: Optional[str] = None
    text: Optional[str] = None
    data: Optional[Dict[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "kind": self.kind,
            "ts": self.ts,
            "seq": self.seq,
            "step": self.step,
            "text": self.text,
            "data": self.data,
        }


class EventSink(Protocol):
    def emit(self, event: Event) -> None: ...


class NullSink:
    def emit(self, event: Event) -> None:
        return None


class ListSink:
    """Collecting sink for tests; assert on ``events``."""

    def __init__(self) -> None:
        self.events: List[Event] = []

    def emit(self, event: Event) -> None:
        self.events.append(event)

    def texts(self, kind: Optional[str] = None) -> List[str]:
        return [e.text or "" for e in self.events if kind is None or e.kind == kind]


class ConsoleSink:
    """Renders events to the terminal through ``core/console.py``."""

    def __init__(self, console: Any, *, verbose: bool = False) -> None:
        self._console = console
        self._verbose = verbose

    def emit(self, event: Event) -> None:
        if event.kind == "step":
            self._console.step(event.text or event.step or "")
        elif event.kind == "log":
            if self._verbose:
                self._console.detail(event.text or "")
        elif event.kind == "progress":
            progress = getattr(self._console, "progress", None)
            if progress is not None:
                progress(event.text or "")
            else:
                self._console.info(event.text or "")
        elif event.kind == "warning":
            self._console.warn(event.text or "")
        elif event.kind == "error":
            self._console.failure(event.text or "")
        elif event.kind == "result":
            if event.text:
                self._console.success(event.text)


@dataclass
class EventEmitter:
    """Stamps ``ts`` and a monotonic ``seq`` onto events bound for one sink."""

    sink: Any = field(default_factory=NullSink)
    _counter: Any = field(default_factory=lambda: itertools.count(), init=False, repr=False)
    _lock: threading.Lock = field(default_factory=threading.Lock, init=False, repr=False)

    def emit(
        self,
        kind: str,
        text: Optional[str] = None,
        *,
        step: Optional[str] = None,
        data: Optional[Dict[str, Any]] = None,
    ) -> Event:
        if kind not in EVENT_KINDS:
            raise ValueError(f"unknown event kind: {kind!r}")
        with self._lock:
            seq = next(self._counter)
        event = Event(kind=kind, ts=time.time(), seq=seq, step=step, text=text, data=data)
        self.sink.emit(event)
        return event

    # Convenience wrappers — the shapes callers actually use.
    def step(self, name: str, text: Optional[str] = None) -> Event:
        return self.emit("step", text or name, step=name)

    def log(self, text: str, *, step: Optional[str] = None) -> Event:
        return self.emit("log", text, step=step)

    def progress(self, text: str, *, step: Optional[str] = None) -> Event:
        return self.emit("progress", text, step=step)

    def warning(self, text: str, *, step: Optional[str] = None) -> Event:
        return self.emit("warning", text, step=step)

    def error(self, text: str, *, step: Optional[str] = None) -> Event:
        return self.emit("error", text, step=step)

    def result(self, data: Dict[str, Any], *, text: Optional[str] = None) -> Event:
        return self.emit("result", text, data=data)
