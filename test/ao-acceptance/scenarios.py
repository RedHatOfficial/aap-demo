"""Versioned AO acceptance scenario manifest contracts."""

from dataclasses import dataclass
import json
from pathlib import Path


@dataclass(frozen=True)
class Scenario:
    """One bounded, explicitly selected AO execution scenario."""

    scenario_id: str
    component: str
    workflow_name: str | None
    job_template_names: list[str]
    timeout_seconds: int
    poll_seconds: int
    expected_workflow_states: list[str]
    expected_job_states: list[str]
    success_markers: list[str]
    launch: bool
    read_only: bool
    success_marker_fields: list[str]
    blocked_reason: str | None


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
    "launch",
    "read_only",
    "success_marker_fields",
    "blocked_reason",
)

_EXECUTION_EVIDENCE_FIELDS = frozenset({"stdout", "output", "result", "status"})


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
    for field in ("scenario_id", "component"):
        if not isinstance(value[field], str) or not value[field].strip():
            raise ValueError(f"scenario {field} must be a non-empty string")
    if value["workflow_name"] is not None and (
        not isinstance(value["workflow_name"], str) or not value["workflow_name"].strip()
    ):
        raise ValueError("scenario workflow_name must be a non-empty string or null")
    for field in ("timeout_seconds", "poll_seconds"):
        if isinstance(value[field], bool) or not isinstance(value[field], int) or value[field] <= 0:
            raise ValueError(f"scenario {field} must be a positive integer")
    for field in ("launch", "read_only"):
        if not isinstance(value[field], bool):
            raise ValueError(f"scenario {field} must be a boolean")
    if value["launch"] and not value["read_only"]:
        raise ValueError("a launchable scenario must be declared read_only")
    blocked_reason = value["blocked_reason"]
    if blocked_reason is not None and (not isinstance(blocked_reason, str) or not blocked_reason.strip()):
        raise ValueError("scenario blocked_reason must be a non-empty string or null")
    if not value["launch"] and not value["read_only"] and blocked_reason is None:
        raise ValueError("a non-read-only non-launchable scenario requires blocked_reason")
    success_markers = _strings(value["success_markers"], "success_markers", allow_empty=True)
    success_marker_fields = _strings(value["success_marker_fields"], "success_marker_fields", allow_empty=True)
    unsupported_evidence_fields = set(success_marker_fields) - _EXECUTION_EVIDENCE_FIELDS
    if unsupported_evidence_fields:
        raise ValueError(
            "scenario success_marker_fields must contain only explicit execution evidence fields "
            f"({', '.join(sorted(_EXECUTION_EVIDENCE_FIELDS))}); unsupported: "
            f"{', '.join(sorted(unsupported_evidence_fields))}"
        )
    if success_markers and not success_marker_fields:
        raise ValueError("scenario success_marker_fields must declare execution evidence fields when success_markers are set")
    return Scenario(
        scenario_id=value["scenario_id"],
        component=value["component"],
        workflow_name=value["workflow_name"],
        job_template_names=_strings(value["job_template_names"], "job_template_names", allow_empty=True),
        timeout_seconds=value["timeout_seconds"],
        poll_seconds=value["poll_seconds"],
        expected_workflow_states=_strings(value["expected_workflow_states"], "expected_workflow_states"),
        expected_job_states=_strings(value["expected_job_states"], "expected_job_states"),
        success_markers=success_markers,
        launch=value["launch"],
        read_only=value["read_only"],
        success_marker_fields=success_marker_fields,
        blocked_reason=blocked_reason,
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
