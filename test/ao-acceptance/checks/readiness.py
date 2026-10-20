"""Read-only live-service readiness checks."""

from datetime import UTC, datetime
from typing import TYPE_CHECKING

try:
    from ..inventory import ManagedResourceInventory
    from ..model import CheckResult, CheckStatus, FailureClass
except ImportError:  # Direct execution via run.sh or python runner.py.
    from inventory import ManagedResourceInventory
    from model import CheckResult, CheckStatus, FailureClass

if TYPE_CHECKING:
    from ..probes import ProbeSet


def _check(component: str, ready: bool) -> CheckResult:
    now = datetime.now(UTC).isoformat()
    return CheckResult(
        check_id=f"readiness.{component}",
        component=component,
        status=CheckStatus.PASS if ready else CheckStatus.FAIL,
        failure_class=None if ready else FailureClass.PREREQUISITE,
        summary=f"{component} is {'ready' if ready else 'not ready'}",
        started_at=now,
        finished_at=now,
        duration_seconds=0.0,
        details={"resource": component},
    )


def run(inventory: ManagedResourceInventory, probes: "ProbeSet") -> list[CheckResult]:
    """Check AAP, AO, and MCP without making a mutating API request."""
    del inventory
    results = []
    for component in ("aap", "ao", "mcp"):
        probe = getattr(probes, f"{component}_ready", None)
        ready = bool(probe()) if callable(probe) else False
        results.append(_check(component, ready))
    return results
