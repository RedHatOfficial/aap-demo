"""Representative, bounded execution checks for managed execution environments."""

from datetime import UTC, datetime
import time
from typing import TYPE_CHECKING

try:
    from ..inventory import ManagedResourceInventory
    from ..model import CheckResult, CheckStatus, FailureClass
    from ..redaction import redact_text
except ImportError:  # Direct execution via run.sh or python runner.py.
    from inventory import ManagedResourceInventory
    from model import CheckResult, CheckStatus, FailureClass
    from redaction import redact_text

if TYPE_CHECKING:
    from ..clients.aap import AapClient
    from ..environment import CommandRunner


_SUCCESS_STATES = {"successful"}
_TERMINAL_STATES = _SUCCESS_STATES | {"failed", "error", "canceled"}
_EXPECTED_IMAGES = {
    "product demos ee": "quay.io/ansible-product-demos/apd-ee-27:latest",
}
_SAFE_REPRESENTATIVE_TEMPLATES = {
    "product demos ee": {"AAP-Demo Acceptance | Product Demos Read-Only Diagnostic"},
    "openshift": {"AAP-Demo Acceptance | OpenShift Read-Only Diagnostic"},
}
_DEFAULT_POLL_TIMEOUT_SECONDS = 60
_AAP_TASK_SELECTOR = "app.kubernetes.io/name=aap-controller-task"


def _same_id(left: object, right: object) -> bool:
    return str(left) == str(right)


def _id_sort_key(value: object) -> tuple[int, object]:
    return (0, value) if isinstance(value, int) and not isinstance(value, bool) else (1, str(value))


def _result(check_id: str, component: str, status: CheckStatus, failure_class: FailureClass | None, summary: str, *, details: dict[str, object]) -> CheckResult:
    now = datetime.now(UTC).isoformat()
    return CheckResult(check_id, component, status, failure_class, summary, now, now, 0.0, details)


def enumerate_supported(inventory: ManagedResourceInventory) -> list[dict]:
    """Return only managed EEs referenced by managed job templates, in stable order."""
    referenced_ids = {template.get("execution_environment_id") for template in inventory.job_templates if template.get("execution_environment_id") is not None}
    supported = [dict(ee) for ee in inventory.execution_environments if any(_same_id(ee.get("id"), reference) for reference in referenced_ids)]
    return sorted(supported, key=lambda ee: _id_sort_key(ee.get("id")))


def _template_for(inventory: ManagedResourceInventory, ee: dict) -> dict | None:
    allowed_names = _SAFE_REPRESENTATIVE_TEMPLATES.get(str(ee.get("name", "")).casefold(), set())
    candidates = [
        template for template in inventory.job_templates
        if _same_id(template.get("execution_environment_id"), ee.get("id"))
        and template.get("can_start") is True
        and template.get("name") in allowed_names
    ]
    return min(candidates, key=lambda template: (str(template.get("name", "")).casefold(), str(template.get("id", ""))), default=None)


def _poll_job(aap: "AapClient", job_id: int, timeout_seconds: int, sleep) -> tuple[str | None, str | None]:
    deadline = time.monotonic() + max(timeout_seconds, 1)
    while True:
        try:
            payload = aap.job_status(job_id)
        except Exception as error:  # Client already redacts API diagnostics.
            return None, redact_text(str(error))
        status = str(payload.get("status", "")).casefold() if isinstance(payload, dict) else ""
        if status in _TERMINAL_STATES:
            return status, None
        if time.monotonic() >= deadline:
            return None, "job did not reach a terminal state before the acceptance timeout"
        sleep(min(2.0, max(0.0, deadline - time.monotonic())))


def run(inventory: ManagedResourceInventory, aap: "AapClient", runner: "CommandRunner") -> list[CheckResult]:
    """Launch one deterministic, startable managed job for every supported EE."""
    results: list[CheckResult] = []
    timeout_seconds = max(int(getattr(runner, "timeout_seconds", _DEFAULT_POLL_TIMEOUT_SECONDS)), 1)
    sleep = getattr(runner, "sleep", time.sleep)
    supported = enumerate_supported(inventory)
    referenced_ids = {template.get("execution_environment_id") for template in inventory.job_templates if template.get("execution_environment_id") is not None}
    discovered_ids = {ee.get("id") for ee in supported}
    for reference in sorted(referenced_ids, key=str):
        if not any(_same_id(reference, discovered) for discovered in discovered_ids):
            results.append(_result(f"ee.{reference}.definition", f"ee:{reference}", CheckStatus.FAIL, FailureClass.CONTRACT_DRIFT, "managed job template references an unknown execution environment", details={"execution_environment_id": reference}))
    for ee in supported:
        ee_id = ee.get("id")
        component = f"ee:{ee.get('name', ee_id)}"
        expected_image = _EXPECTED_IMAGES.get(str(ee.get("name", "")).casefold())
        image_ok = bool(ee.get("image")) and (expected_image is None or ee.get("image") == expected_image)
        definition_ok = bool(ee.get("name")) and image_ok and ee.get("available") is True
        results.append(_result(
            f"ee.{ee_id}.definition", component,
            CheckStatus.PASS if definition_ok else CheckStatus.FAIL,
            None if definition_ok else FailureClass.CONTRACT_DRIFT,
            "managed execution environment has a name, image, and is available" if definition_ok else "managed execution environment is missing its expected name, image, or availability",
            details={"execution_environment_id": ee_id, "name": ee.get("name"), "image": ee.get("image"), "expected_image": expected_image},
        ))
        template = _template_for(inventory, ee)
        if template is None:
            results.append(_result(f"ee.{ee_id}.representative-job", component, CheckStatus.FAIL, FailureClass.CONTRACT_DRIFT, "managed execution environment has no deterministic startable representative job", details={"execution_environment_id": ee_id, "name": ee.get("name")}))
            continue
        if not definition_ok:
            continue
        template_id = template.get("id")
        if isinstance(template_id, bool) or not isinstance(template_id, int):
            results.append(_result(f"ee.{ee_id}.representative-job", component, CheckStatus.FAIL, FailureClass.CONTRACT_DRIFT, "representative job template has no numeric identifier", details={"execution_environment_id": ee_id, "job_template_name": template.get("name")}))
            continue
        try:
            job_id = aap.launch_job_template(template_id)
        except Exception as error:  # Client boundaries redact their own errors.
            results.append(_result(f"ee.{ee_id}.representative-job", component, CheckStatus.FAIL, FailureClass.EXECUTION, "representative job could not be launched", details={"execution_environment_id": ee_id, "job_template_id": template_id, "error": redact_text(str(error))}))
            continue
        pod_result = runner.run(
            [
                "kubectl", "get", "pods", "-n", getattr(runner, "aap_namespace", "aap-operator"),
                "-l", getattr(runner, "ee_selector", _AAP_TASK_SELECTOR),
                "--field-selector=status.phase=Running",
                "-o", "jsonpath={.items[0].metadata.name}",
            ],
            timeout=timeout_seconds,
        )
        if pod_result.returncode != 0 or not pod_result.stdout.strip():
            results.append(_result(
                f"ee.{ee_id}.representative-job", component, CheckStatus.FAIL,
                FailureClass.PREREQUISITE,
                "representative job launched but no running AAP controller task pod was observed",
                details={"execution_environment_id": ee_id, "job_template_id": template_id, "job_id": job_id},
            ))
            continue
        status, error = _poll_job(aap, job_id, timeout_seconds, sleep)
        passed = status in _SUCCESS_STATES
        failure_class = None if passed else (FailureClass.TIMEOUT if status is None and error and "timeout" in error else FailureClass.EXECUTION)
        results.append(_result(
            f"ee.{ee_id}.representative-job", component,
            CheckStatus.PASS if passed else CheckStatus.FAIL,
            failure_class,
            "representative job completed successfully" if passed else "representative job did not complete successfully",
            details={"execution_environment_id": ee_id, "job_template_id": template_id, "job_id": job_id, "task_pod_observed": True, "status": status, "error": error},
        ))
    return results
