"""Data contracts shared by the AO live acceptance checks."""

from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import Path
from typing import Any


class CheckStatus(str, Enum):
    PASS = "PASS"
    FAIL = "FAIL"
    SKIP = "SKIP"
    BLOCKED = "BLOCKED"


class FailureClass(str, Enum):
    PREREQUISITE = "prerequisite"
    WIRING = "wiring"
    EXECUTION = "execution"
    TIMEOUT = "timeout"
    CONTRACT_DRIFT = "contract_drift"


@dataclass
class CheckResult:
    check_id: str
    component: str
    status: CheckStatus
    failure_class: FailureClass | None
    summary: str
    started_at: str
    finished_at: str
    duration_seconds: float
    details: dict[str, object]

    def to_dict(self) -> dict[str, Any]:
        """Return a JSON-compatible representation without changing values."""
        values = asdict(self)
        values["status"] = self.status.value
        if self.failure_class is not None:
            values["failure_class"] = self.failure_class.value
        return values


@dataclass
class RunConfig:
    mode: str
    namespace: str
    artifact_dir: Path
    context: str | None
    scenario_file: Path
    timeout_seconds: int
    dry_run: bool
    aap_namespace: str = "aap-operator"
