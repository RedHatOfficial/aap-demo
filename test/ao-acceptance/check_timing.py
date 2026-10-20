"""Monotonic timing fields for acceptance check results."""

from dataclasses import dataclass
from datetime import UTC, datetime
import time


@dataclass(frozen=True)
class CheckTimer:
    """Capture wall-clock timestamps and monotonic elapsed time for one check."""

    started_at: str
    started_counter: float

    @classmethod
    def start(cls) -> "CheckTimer":
        return cls(datetime.now(UTC).isoformat(), time.perf_counter())

    def finish(self) -> tuple[str, str, float]:
        finished_at = datetime.now(UTC).isoformat()
        duration_seconds = max(time.perf_counter() - self.started_counter, 0.0)
        return self.started_at, finished_at, duration_seconds
