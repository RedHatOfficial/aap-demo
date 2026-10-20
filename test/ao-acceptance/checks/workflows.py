"""Bounded AO workflow execution checks for acceptance scenarios."""

from datetime import UTC, datetime
import time
from typing import TYPE_CHECKING

try:
    from ..inventory import ManagedResourceInventory
    from ..model import CheckResult, CheckStatus, FailureClass
    from ..redaction import redact_text
    from ..scenarios import Scenario
except ImportError:  # Direct execution via run.sh or python runner.py.
    from inventory import ManagedResourceInventory
    from model import CheckResult, CheckStatus, FailureClass
    from redaction import redact_text
    from scenarios import Scenario

if TYPE_CHECKING:
    from ..clients.aap import AapClient
    from ..clients.ao import AoClient


_TERMINAL_STATES = {"successful", "failed", "error", "canceled", "cancelled"}
_DEFAULT_EVIDENCE_FIELDS = ("stdout", "output", "result")
_EXECUTION_EVIDENCE_FIELDS = frozenset((*_DEFAULT_EVIDENCE_FIELDS, "status"))


def _result(
    scenario: Scenario,
    status: CheckStatus,
    failure_class: FailureClass | None,
    summary: str,
    *,
    workflow_id: object | None,
    job_template_ids: list[object],
    job_ids: list[int],
    details: dict[str, object] | None = None,
) -> CheckResult:
    now = datetime.now(UTC).isoformat()
    linked = {
        "scenario_id": scenario.scenario_id,
        "workflow_id": workflow_id,
        "job_template_ids": job_template_ids,
        "job_template_names": scenario.job_template_names,
        "job_ids": job_ids,
    }
    if details:
        linked.update(details)
    return CheckResult(
        check_id=f"workflow.{scenario.scenario_id}",
        component=scenario.component,
        status=status,
        failure_class=failure_class,
        summary=summary,
        started_at=now,
        finished_at=now,
        duration_seconds=0.0,
        details=linked,
    )


def _by_name(resources: list[dict]) -> dict[str, dict]:
    return {str(resource.get("name")): resource for resource in resources if resource.get("name")}


def _template_pair(template_id: object, template_name: object) -> tuple[str, str]:
    return str(template_id), str(template_name)


def _validate(
    scenarios: list[Scenario], inventory: ManagedResourceInventory
) -> tuple[list[tuple[Scenario, dict | None, list[dict]]], list[CheckResult]]:
    """Resolve every manifest reference and workflow template edge before execution."""
    workflows = _by_name(inventory.ao_workflows)
    templates = _by_name(inventory.job_templates)
    resolved: list[tuple[Scenario, dict | None, list[dict]]] = []
    failures: list[CheckResult] = []
    for scenario in scenarios:
        workflow = workflows.get(scenario.workflow_name) if scenario.workflow_name else None
        template_records = [templates[name] for name in scenario.job_template_names if name in templates]
        template_ids = [record.get("id") for record in template_records]
        missing_templates = [name for name in scenario.job_template_names if name not in templates]
        workflow_id = workflow.get("id") if workflow else None
        expected_pairs = {
            _template_pair(record.get("id"), record.get("name")) for record in template_records
        }
        nodes = workflow.get("aap_job_template_nodes", []) if workflow else []
        observed_pairs = {
            _template_pair(node.get("job_template_id"), node.get("job_template_name"))
            for node in nodes if isinstance(node, dict)
        }
        missing_links = expected_pairs - observed_pairs if workflow else set()
        unexpected_links = observed_pairs - expected_pairs if workflow else set()
        reasons = []
        if scenario.workflow_name and workflow is None:
            reasons.append(f"AO workflow {scenario.workflow_name!r} is missing")
        if missing_templates:
            reasons.append(f"AAP job templates are missing: {', '.join(missing_templates)}")
        if missing_links:
            reasons.append("workflow is missing declared AAP job-template ID/name links")
        if unexpected_links:
            reasons.append("workflow has AAP job-template links outside the declared allowlist")
        if reasons:
            failures.append(_result(
                scenario,
                CheckStatus.FAIL,
                FailureClass.CONTRACT_DRIFT,
                "; ".join(reasons),
                workflow_id=workflow_id,
                job_template_ids=template_ids,
                job_ids=[],
                details={
                    "workflow_name": scenario.workflow_name,
                    "allowed_job_template_pairs": sorted(expected_pairs),
                    "observed_workflow_job_template_pairs": sorted(observed_pairs),
                },
            ))
            continue
        resolved.append((scenario, workflow, template_records))
    return resolved, failures


def _status(payload: object) -> str:
    return str(payload.get("status", "")).casefold() if isinstance(payload, dict) else ""


def _as_job_id(value: object) -> int | None:
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    if isinstance(value, str) and value.isdecimal():
        return int(value)
    return None


def _linked_jobs(payload: object) -> list[dict[str, object]]:
    """Extract AO-reported linked jobs together with their template identity."""
    found: list[dict[str, object]] = []

    def add(value: object) -> None:
        record = value if isinstance(value, dict) else {"id": value}
        job_id = _as_job_id(record.get("id", record.get("job_id", record.get("aap_job_id"))))
        if job_id is None or any(item["job_id"] == job_id for item in found):
            return
        template = record.get("job_template")
        template = template if isinstance(template, dict) else {}
        found.append({
            "job_id": job_id,
            "job_template_id": record.get("job_template_id", template.get("id")),
            "job_template_name": record.get("job_template_name", template.get("name")),
        })

    def visit(value: object) -> None:
        if isinstance(value, dict):
            for key, item in value.items():
                normalized = str(key).casefold()
                if normalized in {"job_ids", "aap_job_ids"} and isinstance(item, list):
                    for job in item:
                        add({"job_id": job})
                elif normalized in {"jobs", "aap_jobs"} and isinstance(item, list):
                    for job in item:
                        add(job)
                elif normalized in {"job_id", "aap_job_id"}:
                    add({"job_id": item})
                visit(item)
        elif isinstance(value, list):
            for item in value:
                visit(item)

    visit(payload)
    return found


def _path_values(payload: object, field: str) -> list[object]:
    value = payload
    for part in field.split("."):
        if not isinstance(value, dict) or part not in value:
            return []
        value = value[part]
    return [value]


def _contains_markers(
    payloads: list[dict], markers: list[str], evidence_fields: list[str] | tuple[str, ...] = _DEFAULT_EVIDENCE_FIELDS
) -> bool:
    """Match markers only against declared execution-output fields."""
    if not markers:
        return True
    allowed_fields = tuple(field for field in evidence_fields if field in _EXECUTION_EVIDENCE_FIELDS)
    observed = "\n".join(
        str(value).casefold()
        for payload in payloads
        for field in allowed_fields
        for value in _path_values(payload, field)
    )
    return all(marker.casefold() in observed for marker in markers)


def _poll(status_fn, expected_states: list[str], deadline: float, poll_seconds: int) -> tuple[dict | None, str | None]:
    """Poll only while the caller's one scenario deadline has remaining time."""
    expected = {state.casefold() for state in expected_states}
    last_payload: dict | None = None
    while True:
        if time.monotonic() >= deadline:
            return last_payload, "acceptance timeout expired before a terminal state was observed"
        try:
            payload = status_fn()
        except Exception as error:  # API-client errors redact their own response values.
            return None, redact_text(str(error))
        if isinstance(payload, dict):
            last_payload = payload
        state = _status(payload)
        if state in _TERMINAL_STATES:
            return payload, None if state in expected else f"terminal state {state or 'missing'} is not expected"
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return last_payload, "acceptance timeout expired before a terminal state was observed"
        time.sleep(min(poll_seconds, remaining))


def _deadline_expired(deadline: float) -> bool:
    return time.monotonic() >= deadline


def _contract_drift_for_runtime_links(
    template_records: list[dict], jobs: list[dict[str, object]]
) -> str | None:
    allowed = {_template_pair(record.get("id"), record.get("name")) for record in template_records}
    observed = {_template_pair(job.get("job_template_id"), job.get("job_template_name")) for job in jobs}
    if allowed and not jobs:
        return "AO workflow completed without declared linked AAP jobs"
    if any(pair not in allowed for pair in observed):
        return "AO workflow reported linked AAP jobs outside the declared allowlist"
    if allowed - observed:
        return "AO workflow did not report every declared linked AAP job-template ID/name"
    if not allowed and jobs:
        return "AO workflow reported linked AAP jobs but the scenario declares no allowed links"
    return None


def _timeout_result(
    scenario: Scenario, workflow_id: object, template_ids: list[object], job_ids: list[int], execution_id: object
) -> CheckResult:
    return _result(
        scenario, CheckStatus.FAIL, FailureClass.TIMEOUT,
        "scenario deadline expired before all AO and linked AAP evidence was accepted",
        workflow_id=workflow_id, job_template_ids=template_ids, job_ids=job_ids,
        details={"execution_id": execution_id},
    )


def run(
    scenarios: list[Scenario], inventory: ManagedResourceInventory, ao: "AoClient", aap: "AapClient"
) -> list[CheckResult]:
    """Launch each validated read-only scenario once under a single deadline."""
    blocked_results = [
        _result(
            scenario,
            CheckStatus.BLOCKED,
            FailureClass.PREREQUISITE,
            scenario.blocked_reason,
            workflow_id=None,
            job_template_ids=[],
            job_ids=[],
        )
        for scenario in scenarios
        if not scenario.launch and scenario.blocked_reason
    ]
    executable_scenarios = [
        scenario
        for scenario in scenarios
        if scenario.launch or not scenario.blocked_reason
    ]
    resolved, validation_failures = _validate(executable_scenarios, inventory)
    if validation_failures:
        return [*blocked_results, *validation_failures]

    results = blocked_results
    for scenario, workflow, template_records in resolved:
        workflow_id = workflow.get("id") if workflow else None
        template_ids = [record.get("id") for record in template_records]
        if not scenario.launch:
            results.append(_result(
                scenario, CheckStatus.BLOCKED, FailureClass.CONTRACT_DRIFT,
                scenario.blocked_reason or "scenario is contract-only and is not launched",
                workflow_id=workflow_id, job_template_ids=template_ids, job_ids=[],
            ))
            continue
        if workflow is None or not isinstance(workflow_id, str) or not workflow_id:
            results.append(_result(
                scenario, CheckStatus.FAIL, FailureClass.CONTRACT_DRIFT,
                "resolved AO workflow has no string identifier",
                workflow_id=workflow_id, job_template_ids=template_ids, job_ids=[],
            ))
            continue
        deadline = time.monotonic() + scenario.timeout_seconds
        try:
            execution_id = ao.launch_workflow(workflow_id)
        except Exception as error:
            results.append(_result(
                scenario, CheckStatus.FAIL, FailureClass.EXECUTION,
                "AO workflow could not be launched",
                workflow_id=workflow_id, job_template_ids=template_ids, job_ids=[],
                details={"error": redact_text(str(error))},
            ))
            continue
        workflow_payload, workflow_error = _poll(
            lambda: ao.workflow_status(execution_id), scenario.expected_workflow_states, deadline, scenario.poll_seconds
        )
        jobs = _linked_jobs(workflow_payload) if workflow_payload else []
        job_ids = [int(job["job_id"]) for job in jobs]
        if workflow_error:
            failure_class = FailureClass.TIMEOUT if "timeout" in workflow_error else FailureClass.EXECUTION
            results.append(_result(
                scenario, CheckStatus.FAIL, failure_class,
                "AO workflow did not complete with an expected state",
                workflow_id=workflow_id, job_template_ids=template_ids, job_ids=job_ids,
                details={"execution_id": execution_id, "workflow_status": _status(workflow_payload), "error": workflow_error},
            ))
            continue
        link_error = _contract_drift_for_runtime_links(template_records, jobs)
        if link_error:
            results.append(_result(
                scenario, CheckStatus.FAIL, FailureClass.CONTRACT_DRIFT, link_error,
                workflow_id=workflow_id, job_template_ids=template_ids, job_ids=job_ids,
                details={"execution_id": execution_id, "observed_linked_jobs": jobs},
            ))
            continue
        job_payloads: list[dict] = []
        job_error: str | None = None
        for job_id in job_ids:
            payload, error = _poll(
                lambda job_id=job_id: aap.job_status(job_id), scenario.expected_job_states, deadline, scenario.poll_seconds
            )
            if isinstance(payload, dict):
                job_payloads.append(payload)
            if error:
                job_error = error
                break
        if job_error:
            failure_class = FailureClass.TIMEOUT if "timeout" in job_error else FailureClass.EXECUTION
            results.append(_result(
                scenario, CheckStatus.FAIL, failure_class,
                "linked AAP job did not complete with an expected state",
                workflow_id=workflow_id, job_template_ids=template_ids, job_ids=job_ids,
                details={"execution_id": execution_id, "workflow_status": _status(workflow_payload), "error": job_error},
            ))
            continue
        if _deadline_expired(deadline):
            results.append(_timeout_result(scenario, workflow_id, template_ids, job_ids, execution_id))
            continue
        job_event_payloads: list[dict] = []
        if scenario.success_markers:
            try:
                for job_id in job_ids:
                    if _deadline_expired(deadline):
                        raise TimeoutError("scenario deadline expired")
                    job_event_payloads.extend(aap.list_all(f"/api/v2/jobs/{job_id}/job_events/"))
            except TimeoutError:
                results.append(_timeout_result(scenario, workflow_id, template_ids, job_ids, execution_id))
                continue
            except Exception as error:  # Client boundaries redact their own response values.
                results.append(_result(
                    scenario, CheckStatus.FAIL, FailureClass.EXECUTION,
                    "linked AAP job events could not be observed for success markers",
                    workflow_id=workflow_id, job_template_ids=template_ids, job_ids=job_ids,
                    details={"execution_id": execution_id, "error": redact_text(str(error))},
                ))
                continue
        if _deadline_expired(deadline):
            results.append(_timeout_result(scenario, workflow_id, template_ids, job_ids, execution_id))
            continue
        observed_payloads = [workflow_payload, *job_payloads, *job_event_payloads]
        if not _contains_markers(
            [payload for payload in observed_payloads if isinstance(payload, dict)],
            scenario.success_markers,
            scenario.success_marker_fields,
        ):
            results.append(_result(
                scenario, CheckStatus.FAIL, FailureClass.EXECUTION,
                "AO workflow and linked AAP jobs completed without every declared success marker",
                workflow_id=workflow_id, job_template_ids=template_ids, job_ids=job_ids,
                details={"execution_id": execution_id, "success_markers": scenario.success_markers},
            ))
            continue
        results.append(_result(
            scenario, CheckStatus.PASS, None,
            "AO workflow and linked AAP jobs completed with expected states and execution evidence",
            workflow_id=workflow_id, job_template_ids=template_ids, job_ids=job_ids,
            details={"execution_id": execution_id, "workflow_status": _status(workflow_payload)},
        ))
    return results
