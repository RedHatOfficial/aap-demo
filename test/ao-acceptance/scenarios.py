"""Versioned AO acceptance scenario manifest contracts."""

from dataclasses import dataclass
import json
from pathlib import Path


@dataclass(frozen=True)
class Scenario:
    """One bounded, explicitly selected AO execution scenario."""

    scenario_id: str
    component: str
    workflow_name: str
    job_template_names: list[str]
    timeout_seconds: int
    poll_seconds: int
    expected_workflow_states: list[str]
    expected_job_states: list[str]
    success_markers: list[str]


_REQUIRED_FIELDS = (
    "scenario_id",
    "component",
    "workflow_name",
    "job_template_names",
    "timeout_seconds",
    "poll_seconds",
    "expected_workflow_states",
    "expected_job_states",
    "success_markers",
)


def _strings(value: object, field: str, *, allow_empty: bool = False) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) and item.strip() for item in value):
        raise ValueError(f"scenario {field} must be a list of non-empty strings")
    if not allow_empty and not value:
        raise ValueError(f"scenario {field} must not be empty")
    return value


def _scenario(value: object) -> Scenario:
    if not isinstance(value, dict):
        raise ValueError("each scenario must be an object")
    missing = [field for field in _REQUIRED_FIELDS if field not in value]
    if missing:
        raise ValueError(f"scenario is missing required fields: {', '.join(missing)}")
    for field in ("scenario_id", "component", "workflow_name"):
        if not isinstance(value[field], str) or not value[field].strip():
            raise ValueError(f"scenario {field} must be a non-empty string")
    for field in ("timeout_seconds", "poll_seconds"):
        if isinstance(value[field], bool) or not isinstance(value[field], int) or value[field] <= 0:
            raise ValueError(f"scenario {field} must be a positive integer")
    return Scenario(
        scenario_id=value["scenario_id"],
        component=value["component"],
        workflow_name=value["workflow_name"],
        job_template_names=_strings(value["job_template_names"], "job_template_names", allow_empty=True),
        timeout_seconds=value["timeout_seconds"],
        poll_seconds=value["poll_seconds"],
        expected_workflow_states=_strings(value["expected_workflow_states"], "expected_workflow_states"),
        expected_job_states=_strings(value["expected_job_states"], "expected_job_states"),
        success_markers=_strings(value["success_markers"], "success_markers", allow_empty=True),
    )


def load(path: Path) -> list[Scenario]:
    """Load a complete, validated manifest before any workflow launch."""
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ValueError(f"could not read scenario manifest {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise ValueError(f"scenario manifest {path} is not valid JSON: {error.msg}") from error
    if not isinstance(payload, dict) or set(payload) != {"scenarios"}:
        raise ValueError("scenario manifest must contain only a scenarios list")
    raw_scenarios = payload["scenarios"]
    if not isinstance(raw_scenarios, list) or not raw_scenarios:
        raise ValueError("scenario manifest scenarios must be a non-empty list")
    loaded = [_scenario(value) for value in raw_scenarios]
    scenario_ids = [scenario.scenario_id for scenario in loaded]
    if len(set(scenario_ids)) != len(scenario_ids):
        raise ValueError("scenario manifest contains duplicate scenario IDs")
    return loaded
