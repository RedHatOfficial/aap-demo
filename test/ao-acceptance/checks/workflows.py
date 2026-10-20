"""Bounded AO workflow execution checks for acceptance scenarios."""

from datetime import UTC, datetime
import json
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


def _same_name(left: object, right: object) -> bool:
    return str(left) == str(right)


def _validate(scenarios: list[Scenario], inventory: ManagedResourceInventory) -> tuple[list[tuple[Scenario, dict, list[dict]]], list[CheckResult]]:
    """Resolve every manifest reference before executing any scenario."""
    workflows = _by_name(inventory.ao_workflows)
    templates = _by_name(inventory.job_templates)
    resolved: list[tuple[Scenario, dict, list[dict]]] = []
    failures: list[CheckResult] = []
    for scenario in scenarios:
        workflow = workflows.get(scenario.workflow_name)
        template_records = [templates[name] for name in scenario.job_template_names if name in templates]
        template_ids = [record.get("id") for record in template_records]
        missing_templates = [name for name in scenario.job_template_names if name not in templates]
        workflow_id = workflow.get("id") if workflow else None
        nodes = workflow.get("aap_job_template_nodes", []) if workflow else []
        node_names = [node.get("job_template_name") for node in nodes if isinstance(node, dict)]
        unlinked_templates = [name for name in scenario.job_template_names if not any(_same_name(name, linked) for linked in node_names)]
        if workflow is None or missing_templates or unlinked_templates:
            reasons = []
            if workflow is None:
                reasons.append(f"AO workflow {scenario.workflow_name!r} is missing")
            if missing_templates:
                reasons.append(f"AAP job templates are missing: {', '.join(missing_templates)}")
            if unlinked_templates and workflow is not None:
                reasons.append(f"workflow is missing declared AAP job-template links: {', '.join(unlinked_templates)}")
            failures.append(_result(
                scenario,
                CheckStatus.FAIL,
                FailureClass.CONTRACT_DRIFT,
                "; ".join(reasons),
                workflow_id=workflow_id,
                job_template_ids=template_ids,
                job_ids=[],
                details={"workflow_name": scenario.workflow_name, "job_template_names": scenario.job_template_names},
            ))
            continue
        resolved.append((scenario, workflow, template_records))
    return resolved, failures


def _status(payload: object) -> str:
    return str(payload.get("status", "")).casefold() if isinstance(payload, dict) else ""


def _linked_job_ids(payload: object) -> list[int]:
    """Extract linked AAP job IDs while ignoring similarly named templates."""
    found: list[int] = []

    def add(value: object) -> None:
        if isinstance(value, int) and not isinstance(value, bool) and value not in found:
            found.append(value)
        elif isinstance(value, str) and value.isdecimal() and int(value) not in found:
            found.append(int(value))

    def visit(value: object, key: str = "") -> None:
        if isinstance(value, dict):
            for item_key, item_value in value.items():
                normalized = str(item_key).casefold()
                if normalized in {"job_id", "aap_job_id"}:
                    add(item_value)
                elif normalized in {"job_ids", "aap_job_ids"} and isinstance(item_value, list):
                    for item in item_value:
                        add(item)
                elif normalized in {"jobs", "aap_jobs"} and isinstance(item_value, list):
                    for item in item_value:
                        if isinstance(item, dict):
                            add(item.get("id", item.get("job_id", item.get("aap_job_id"))))
                        else:
                            add(item)
                visit(item_value, normalized)
        elif isinstance(value, list):
            for item in value:
                visit(item, key)

    visit(payload)
    return found


def _contains_markers(payloads: list[dict], markers: list[str]) -> bool:
    if not markers:
        return True
    observed = json.dumps(payloads, sort_keys=True).casefold()
    return all(marker.casefold() in observed for marker in markers)


def _poll(status_fn, expected_states: list[str], timeout_seconds: int, poll_seconds: int) -> tuple[dict | None, str | None]:
    deadline = time.monotonic() + timeout_seconds
    expected = {state.casefold() for state in expected_states}
    last_payload: dict | None = None
    while True:
        try:
            payload = status_fn()
        except Exception as error:  # API-client errors redact their own response values.
            return None, redact_text(str(error))
        if isinstance(payload, dict):
            last_payload = payload
        state = _status(payload)
        if state in _TERMINAL_STATES:
            return payload, None if state in expected else f"terminal state {state or 'missing'} is not expected"
        if time.monotonic() >= deadline:
            return last_payload, "acceptance timeout expired before a terminal state was observed"
        time.sleep(min(poll_seconds, max(0.0, deadline - time.monotonic())))


def run(
    scenarios: list[Scenario],
    inventory: ManagedResourceInventory,
    ao: "AoClient",
    aap: "AapClient",
) -> list[CheckResult]:
    """Launch each validated scenario once, then verify AO and linked AAP jobs."""
    resolved, validation_failures = _validate(scenarios, inventory)
    if validation_failures:
        return validation_failures

    results: list[CheckResult] = []
    for scenario, workflow, template_records in resolved:
        workflow_id = workflow.get("id")
        template_ids = [record.get("id") for record in template_records]
        if not isinstance(workflow_id, str) or not workflow_id:
            results.append(_result(
                scenario, CheckStatus.FAIL, FailureClass.CONTRACT_DRIFT,
                "resolved AO workflow has no string identifier",
                workflow_id=workflow_id, job_template_ids=template_ids, job_ids=[],
            ))
            continue
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
            lambda: ao.workflow_status(execution_id),
            scenario.expected_workflow_states,
            scenario.timeout_seconds,
            scenario.poll_seconds,
        )
        job_ids = _linked_job_ids(workflow_payload) if workflow_payload else []
        if workflow_error:
            failure_class = FailureClass.TIMEOUT if "timeout" in workflow_error else FailureClass.EXECUTION
            results.append(_result(
                scenario, CheckStatus.FAIL, failure_class,
                "AO workflow did not complete with an expected state",
                workflow_id=workflow_id, job_template_ids=template_ids, job_ids=job_ids,
                details={"execution_id": execution_id, "workflow_status": _status(workflow_payload), "error": workflow_error},
            ))
            continue
        if scenario.job_template_names and not job_ids:
            results.append(_result(
                scenario, CheckStatus.FAIL, FailureClass.EXECUTION,
                "AO workflow completed without linked AAP job IDs",
                workflow_id=workflow_id, job_template_ids=template_ids, job_ids=[],
                details={"execution_id": execution_id, "workflow_status": _status(workflow_payload)},
            ))
            continue
        job_payloads: list[dict] = []
        job_error: str | None = None
        for job_id in job_ids:
            payload, error = _poll(
                lambda job_id=job_id: aap.job_status(job_id),
                scenario.expected_job_states,
                scenario.timeout_seconds,
                scenario.poll_seconds,
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
        job_event_payloads: list[dict] = []
        if scenario.success_markers:
            try:
                for job_id in job_ids:
                    job_event_payloads.extend(aap.list_all(f"/api/v2/jobs/{job_id}/job_events/"))
            except Exception as error:  # Client boundaries redact their own response values.
                results.append(_result(
                    scenario, CheckStatus.FAIL, FailureClass.EXECUTION,
                    "linked AAP job events could not be observed for success markers",
                    workflow_id=workflow_id, job_template_ids=template_ids, job_ids=job_ids,
                    details={"execution_id": execution_id, "error": redact_text(str(error))},
                ))
                continue
        observed_payloads = [workflow_payload, *job_payloads, *job_event_payloads]
        if not _contains_markers([payload for payload in observed_payloads if isinstance(payload, dict)], scenario.success_markers):
            results.append(_result(
                scenario, CheckStatus.FAIL, FailureClass.EXECUTION,
                "AO workflow and linked AAP jobs completed without every declared success marker",
                workflow_id=workflow_id, job_template_ids=template_ids, job_ids=job_ids,
                details={"execution_id": execution_id, "success_markers": scenario.success_markers},
            ))
            continue
        results.append(_result(
            scenario, CheckStatus.PASS, None,
            "AO workflow and linked AAP jobs completed with expected states and markers",
            workflow_id=workflow_id, job_template_ids=template_ids, job_ids=job_ids,
            details={"execution_id": execution_id, "workflow_status": _status(workflow_payload)},
        ))
    return results
