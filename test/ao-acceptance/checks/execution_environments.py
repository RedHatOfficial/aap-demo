"""Representative, bounded execution checks for managed execution environments."""

import re
import time
from typing import TYPE_CHECKING

try:
    from ..check_timing import CheckTimer
    from ..inventory import ManagedResourceInventory
    from ..model import CheckResult, CheckStatus, FailureClass
    from ..redaction import redact_text
    from ..scenarios import Scenario
    from . import workflows
except ImportError:  # Direct execution via run.sh or python runner.py.
    from check_timing import CheckTimer
    from inventory import ManagedResourceInventory
    from model import CheckResult, CheckStatus, FailureClass
    from redaction import redact_text
    from scenarios import Scenario
    from checks import workflows

if TYPE_CHECKING:
    from ..clients.aap import AapClient
    from ..environment import CommandRunner


_SUCCESS_STATES = {"successful"}
_TERMINAL_STATES = _SUCCESS_STATES | {"failed", "error", "canceled"}
_EXPECTED_CONTRACTS = {
    "product demos ee": {
        "image": "quay.io/ansible-product-demos/apd-ee-27:latest",
        "template": "AAP-Demo Acceptance | Product Demos Read-Only Diagnostic",
        "workflow": "AAP-Demo Acceptance | Product Demos Read-Only",
        "project": "APD Bootstrap Project",
        "project_url": "https://github.com/ansible/product-demos",
        "playbook": "acceptance-read-only.yml",
    },
}
_IMMUTABLE_REF = re.compile(r"^[0-9a-f]{40,64}$")
_DEFAULT_POLL_TIMEOUT_SECONDS = 60
_PROBE_PAUSE_SECONDS = 30


def _same_id(left: object, right: object) -> bool:
    return str(left) == str(right)


def _id_sort_key(value: object) -> tuple[int, object]:
    return (0, value) if isinstance(value, int) and not isinstance(value, bool) else (1, str(value))


def _result(
    check_id: str,
    component: str,
    status: CheckStatus,
    failure_class: FailureClass | None,
    summary: str,
    *,
    details: dict[str, object],
    timer: CheckTimer | None = None,
) -> CheckResult:
    started_at, finished_at, duration_seconds = (timer or CheckTimer.start()).finish()
    return CheckResult(
        check_id,
        component,
        status,
        failure_class,
        summary,
        started_at,
        finished_at,
        duration_seconds,
        details,
    )


def enumerate_supported(inventory: ManagedResourceInventory) -> list[dict]:
    """Return every managed EE so an unreferenced one cannot be silently skipped."""
    return sorted(
        (dict(ee) for ee in inventory.execution_environments),
        key=lambda ee: _id_sort_key(ee.get("id")),
    )


def _template_for(inventory: ManagedResourceInventory, ee: dict) -> dict | None:
    contract = _EXPECTED_CONTRACTS.get(str(ee.get("name", "")).casefold())
    if contract is None:
        return None
    projects = {project.get("id"): project for project in inventory.projects}
    candidates = [
        template for template in inventory.job_templates
        if _same_id(template.get("execution_environment_id"), ee.get("id"))
        and template.get("can_start") is True
        and template.get("name") == contract["template"]
        and template.get("project_name") == contract["project"]
        and template.get("playbook") == contract["playbook"]
        and template.get("ask_variables_on_launch") is True
    ]
    for template in sorted(
        candidates,
        key=lambda item: (str(item.get("name", "")).casefold(), str(item.get("id", ""))),
    ):
        project = projects.get(template.get("project_id"))
        if not project:
            continue
        branch = str(project.get("scm_branch", ""))
        project_url = str(project.get("scm_url", "")).rstrip("/").removesuffix(".git").casefold()
        if (
            project.get("name") == contract["project"]
            and project.get("scm_type") == "git"
            and project_url == contract["project_url"]
            and _IMMUTABLE_REF.fullmatch(branch)
            and project.get("scm_revision") == branch
            and project.get("scm_update_on_launch") is False
        ):
            return template
    return None


def _workflow_for(inventory: ManagedResourceInventory, template: dict, ee: dict) -> dict | None:
    """Resolve the explicit AO representative for a managed EE/template pair."""
    contract = _EXPECTED_CONTRACTS.get(str(ee.get("name", "")).casefold())
    if not contract:
        return None
    expected_pair = (str(template.get("id")), str(template.get("name")))
    for workflow in inventory.ao_workflows:
        if workflow.get("name") != contract["workflow"]:
            continue
        for node in workflow.get("aap_job_template_nodes", []):
            observed_pair = (str(node.get("job_template_id")), str(node.get("job_template_name")))
            if observed_pair == expected_pair:
                return workflow
    return None


def _execution_environment_id(payload: dict) -> object | None:
    value = payload.get("execution_environment")
    if isinstance(value, dict):
        return value.get("id")
    if value is not None:
        return value
    summary = payload.get("summary_fields")
    if isinstance(summary, dict):
        value = summary.get("execution_environment")
        if isinstance(value, dict):
            return value.get("id")
    return None


def _poll_job(aap: "AapClient", job_id: int, timeout_seconds: int, sleep) -> tuple[str | None, str | None, object | None]:
    deadline = time.monotonic() + max(timeout_seconds, 1)
    while True:
        try:
            payload = aap.job_status(job_id)
        except Exception as error:  # Client already redacts API diagnostics.
            return None, redact_text(str(error)), None
        status = str(payload.get("status", "")).casefold() if isinstance(payload, dict) else ""
        if status in _TERMINAL_STATES:
            observed_ee_id = _execution_environment_id(payload) if isinstance(payload, dict) else None
            return status, None, observed_ee_id
        if time.monotonic() >= deadline:
            return None, "job did not reach a terminal state before the acceptance timeout", None
        sleep(min(2.0, max(0.0, deadline - time.monotonic())))


def _wait_for_job_pod(
    runner: "CommandRunner",
    namespace: str,
    selector: str,
    timeout_seconds: int,
    sleep,
):
    attempts = max(timeout_seconds, 1)
    for attempt in range(attempts):
        result = runner.run(
            [
                "kubectl", "get", "pods", "-n", namespace, "-l", selector,
                "--field-selector=status.phase=Running",
                "-o", "jsonpath={.items[0].metadata.name}",
            ],
            timeout=timeout_seconds,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result
        if attempt == attempts - 1:
            return result
        sleep(1.0)


def run(
    inventory: ManagedResourceInventory,
    aap: "AapClient",
    runner: "CommandRunner",
    probes=None,
    *,
    ao=None,
) -> list[CheckResult]:
    """Execute one explicit AO representative workflow for every managed EE."""
    results: list[CheckResult] = []
    timeout_seconds = max(int(getattr(runner, "timeout_seconds", _DEFAULT_POLL_TIMEOUT_SECONDS)), 1)
    sleep = getattr(runner, "sleep", time.sleep)
    supported = enumerate_supported(inventory)
    referenced_ids = {template.get("execution_environment_id") for template in inventory.job_templates if template.get("execution_environment_id") is not None}
    discovered_ids = {ee.get("id") for ee in supported}
    for reference in sorted(referenced_ids, key=str):
        if not any(_same_id(reference, discovered) for discovered in discovered_ids):
            results.append(_result(f"ee.{reference}.definition", f"ee:{reference}", CheckStatus.FAIL, FailureClass.CONTRACT_DRIFT, "managed job template references an unknown execution environment", details={"execution_environment_id": reference}, timer=CheckTimer.start()))
    for ee in supported:
        definition_timer = CheckTimer.start()
        ee_id = ee.get("id")
        component = f"ee:{ee.get('name', ee_id)}"
        contract = _EXPECTED_CONTRACTS.get(str(ee.get("name", "")).casefold())
        expected_image = contract.get("image") if contract else None
        image_ok = bool(expected_image) and ee.get("image") == expected_image
        definition_ok = bool(contract and ee.get("name") and image_ok and ee.get("available") is True)
        results.append(_result(
            f"ee.{ee_id}.definition", component,
            CheckStatus.PASS if definition_ok else CheckStatus.FAIL,
            None if definition_ok else FailureClass.CONTRACT_DRIFT,
            "managed execution environment has a name, image, and is available" if definition_ok else "managed execution environment is missing its expected name, image, or availability",
            details={"execution_environment_id": ee_id, "name": ee.get("name"), "image": ee.get("image"), "expected_image": expected_image},
            timer=definition_timer,
        ))
        representative_timer = CheckTimer.start()
        template = _template_for(inventory, ee)
        if template is None:
            results.append(_result(f"ee.{ee_id}.representative-job", component, CheckStatus.FAIL, FailureClass.CONTRACT_DRIFT, "managed execution environment has no deterministic startable representative job", details={"execution_environment_id": ee_id, "name": ee.get("name")}, timer=representative_timer))
            continue
        if not definition_ok:
            continue
        workflow = _workflow_for(inventory, template, ee)
        if workflow is None:
            results.append(_result(
                f"ee.{ee_id}.representative-job", component, CheckStatus.FAIL,
                FailureClass.CONTRACT_DRIFT,
                "managed execution environment has no AO representative workflow",
                details={
                    "execution_environment_id": ee_id,
                    "job_template_id": template.get("id"),
                    "job_template_name": template.get("name"),
                },
                timer=representative_timer,
            ))
            continue
        if ao is None:
            results.append(_result(
                f"ee.{ee_id}.representative-job", component, CheckStatus.FAIL,
                FailureClass.PREREQUISITE,
                "AO client is required for representative execution",
                details={"execution_environment_id": ee_id, "workflow_name": workflow.get("name")},
                timer=representative_timer,
            ))
            continue
        template_id = template.get("id")
        if isinstance(template_id, bool) or not isinstance(template_id, int):
            results.append(_result(f"ee.{ee_id}.representative-job", component, CheckStatus.FAIL, FailureClass.CONTRACT_DRIFT, "representative job template has no numeric identifier", details={"execution_environment_id": ee_id, "job_template_name": template.get("name")}, timer=representative_timer))
            continue
        scenario = Scenario(
            scenario_id=f"ee-{ee_id}-representative",
            component=component,
            workflow_name=str(workflow.get("name")),
            job_template_names=[str(template.get("name"))],
            timeout_seconds=timeout_seconds,
            poll_seconds=2,
            expected_workflow_states=["successful"],
            expected_job_states=["successful"],
            success_markers=[],
            launch=True,
            read_only=True,
            success_marker_fields=[],
            blocked_reason=None,
            scenario_type="workflow",
            mcp_tool_name=None,
            mcp_arguments={},
        )
        workflow_checks = workflows.run([scenario], inventory, ao, aap)
        workflow_check = workflow_checks[0]
        if workflow_check.status is not CheckStatus.PASS:
            results.append(_result(
                f"ee.{ee_id}.representative-job", component, CheckStatus.FAIL,
                workflow_check.failure_class or FailureClass.EXECUTION,
                "AO representative workflow did not complete successfully",
                details={
                    "execution_environment_id": ee_id,
                    "job_template_id": template_id,
                    "workflow_id": workflow.get("id"),
                    "error": redact_text(workflow_check.summary),
                },
                timer=representative_timer,
            ))
            continue
        job_ids = workflow_check.details.get("job_ids", [])
        if not isinstance(job_ids, list) or len(job_ids) != 1 or not isinstance(job_ids[0], int):
            results.append(_result(
                f"ee.{ee_id}.representative-job", component, CheckStatus.FAIL,
                FailureClass.CONTRACT_DRIFT,
                "AO representative workflow did not report exactly one linked AAP job",
                details={"execution_environment_id": ee_id, "workflow_id": workflow.get("id"), "job_ids": job_ids},
                timer=representative_timer,
            ))
            continue
        job_id = job_ids[0]
        namespace = getattr(runner, "aap_namespace", "aap-operator")
        job_selector = f"ansible-awx-job-id={job_id}"
        pod_result = _wait_for_job_pod(
            runner, namespace, job_selector, timeout_seconds, sleep
        )
        if pod_result.returncode != 0 or not pod_result.stdout.strip():
            results.append(_result(
                f"ee.{ee_id}.representative-job", component, CheckStatus.FAIL,
                FailureClass.PREREQUISITE,
                "representative job launched but no running AAP controller task pod was observed",
                details={"execution_environment_id": ee_id, "job_template_id": template_id, "job_id": job_id},
                timer=representative_timer,
            ))
            continue
        mcp_tools = None
        mcp_context_ok = True
        if probes is not None:
            observe_tools = getattr(probes, "mcp_tools_from_pod", None)
            mcp_tools = (
                observe_tools(namespace, job_selector)
                if callable(observe_tools) else None
            )
            mcp_context_ok = isinstance(mcp_tools, list) and bool(mcp_tools)
        environment_ids = workflow_check.details.get("job_execution_environments", [])
        observed_ee_id = environment_ids[0] if isinstance(environment_ids, list) and environment_ids else None
        status = "successful"
        error = None
        execution_environment_ok = _same_id(observed_ee_id, ee_id)
        passed = (
            status in _SUCCESS_STATES
            and execution_environment_ok
            and mcp_context_ok
        )
        if passed:
            failure_class = None
        elif status in _SUCCESS_STATES and not execution_environment_ok:
            failure_class = FailureClass.CONTRACT_DRIFT
        elif status in _SUCCESS_STATES and not mcp_context_ok:
            failure_class = FailureClass.PREREQUISITE
        elif status is None and error and "timeout" in error:
            failure_class = FailureClass.TIMEOUT
        else:
            failure_class = FailureClass.EXECUTION
        results.append(_result(
            f"ee.{ee_id}.representative-job", component,
            CheckStatus.PASS if passed else CheckStatus.FAIL,
            failure_class,
            "representative job and authenticated in-EE MCP probe completed successfully" if passed else "representative job or authenticated in-EE MCP probe did not complete successfully",
            details={"execution_environment_id": ee_id, "observed_execution_environment_id": observed_ee_id, "workflow_id": workflow.get("id"), "job_template_id": template_id, "job_id": job_id, "job_pod_observed": True, "mcp_tool_count": len(mcp_tools) if isinstance(mcp_tools, list) else None, "status": status, "error": error},
            timer=representative_timer,
        ))
    return results
