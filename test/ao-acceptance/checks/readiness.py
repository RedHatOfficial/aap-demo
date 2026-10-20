"""Read-only live-service readiness checks."""

from typing import TYPE_CHECKING

try:
    from ..check_timing import CheckTimer
    from ..inventory import ManagedResourceInventory
    from ..model import CheckResult, CheckStatus, FailureClass
except ImportError:  # Direct execution via run.sh or python runner.py.
    from check_timing import CheckTimer
    from inventory import ManagedResourceInventory
    from model import CheckResult, CheckStatus, FailureClass

if TYPE_CHECKING:
    from ..probes import ProbeSet


def _check(component: str, ready: bool, timer: CheckTimer) -> CheckResult:
    started_at, finished_at, duration_seconds = timer.finish()
    return CheckResult(
        check_id=f"readiness.{component}",
        component=component,
        status=CheckStatus.PASS if ready else CheckStatus.FAIL,
        failure_class=None if ready else FailureClass.PREREQUISITE,
        summary=f"{component} is {'ready' if ready else 'not ready'}",
        started_at=started_at,
        finished_at=finished_at,
        duration_seconds=duration_seconds,
        details={"resource": component},
    )


def run(inventory: ManagedResourceInventory, probes: "ProbeSet") -> list[CheckResult]:
    """Check services and the prepared Product Demos representative."""
    results = []
    for component in ("aap", "ao", "mcp"):
        timer = CheckTimer.start()
        probe = getattr(probes, f"{component}_ready", None)
        ready = bool(probe()) if callable(probe) else False
        results.append(_check(component, ready, timer))
    product_demos_timer = CheckTimer.start()
    product_project = next(
        (
            item for item in inventory.projects
            if item.get("name") == "APD Bootstrap Project"
        ),
        None,
    )
    product_ee = next(
        (
            item for item in inventory.execution_environments
            if item.get("name") == "Product Demos EE"
        ),
        None,
    )
    product_template = next(
        (
            item for item in inventory.job_templates
            if item.get("name")
            == "AAP-Demo Acceptance | Product Demos Read-Only Diagnostic"
        ),
        None,
    )
    product_demos_ready = bool(
        product_project
        and product_ee
        and product_ee.get("image")
        == "quay.io/ansible-product-demos/apd-ee-27:latest"
        and product_ee.get("available") is True
        and product_template
        and product_template.get("project_id") == product_project.get("id")
        and product_template.get("execution_environment_id") == product_ee.get("id")
        and product_template.get("playbook") == "acceptance-read-only.yml"
        and product_template.get("can_start") is True
        and product_template.get("ask_variables_on_launch") is True
    )
    results.append(_check("product_demos", product_demos_ready, product_demos_timer))
    return results
