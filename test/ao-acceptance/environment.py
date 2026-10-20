"""Safe target inspection and preparation for AO live acceptance runs."""

from dataclasses import dataclass
from datetime import UTC, datetime
import subprocess
import time

try:
    from .model import CheckResult, CheckStatus, FailureClass, RunConfig
except ImportError:  # Direct execution via run.sh or python runner.py.
    from model import CheckResult, CheckStatus, FailureClass, RunConfig


@dataclass(frozen=True)
class CommandResult:
    """The non-secret result of one external command."""

    returncode: int
    stdout: str
    stderr: str


class CommandRunner:
    """Run argv commands without a shell and capture their text output."""

    def run(self, args: list[str], *, check: bool = False, timeout: int = 60) -> CommandResult:
        try:
            completed = subprocess.run(
                args,
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except FileNotFoundError as error:
            result = CommandResult(127, "", str(error))
        except subprocess.TimeoutExpired as error:
            result = CommandResult(
                124,
                error.stdout or "",
                error.stderr or "command timed out",
            )
        else:
            result = CommandResult(completed.returncode, completed.stdout, completed.stderr)
        if check and result.returncode:
            raise subprocess.CalledProcessError(
                result.returncode, args, output=result.stdout, stderr=result.stderr
            )
        return result


class TargetInspector:
    """Read only the cluster state needed to select an execution mode."""

    def __init__(self, runner: CommandRunner, config: RunConfig):
        self.runner = runner
        self.namespace = config.namespace
        self.aap_namespace = config.aap_namespace
        self.timeout = config.timeout_seconds

    def current_context(self) -> str:
        result = self.runner.run(["kubectl", "config", "current-context"], timeout=self.timeout)
        return result.stdout.strip() if result.returncode == 0 else ""

    def credentials_ready(self) -> bool:
        result = self.runner.run(
            ["kubectl", "auth", "can-i", "get", "namespaces"], timeout=self.timeout
        )
        return result.returncode == 0 and result.stdout.strip().lower() == "yes"

    def _ready_resource(self, get_args: list[str], wait_args: list[str]) -> bool:
        return (
            self.runner.run(get_args, timeout=self.timeout).returncode == 0
            and self.runner.run(wait_args, timeout=self.timeout).returncode == 0
        )

    def aap_demo_ready(self) -> bool:
        return self._ready_resource(
            ["kubectl", "get", "deployment", "aap-controller-web", "-n", self.aap_namespace, "-o", "json"],
            ["kubectl", "wait", "--for=condition=Available", "deployment/aap-controller-web", "-n", self.aap_namespace, f"--timeout={self.timeout}s"],
        )

    def ao_ready(self) -> bool:
        return self._ready_resource(
            ["kubectl", "get", "automationorchestrator", "automation-orchestrator", "-n", self.namespace, "-o", "json"],
            ["kubectl", "wait", "--for=condition=Ready", "automationorchestrator/automation-orchestrator", "-n", self.namespace, f"--timeout={self.timeout}s"],
        )

    def required_addons_ready(self) -> dict[str, bool]:
        mcp_ready = self._ready_resource(
            ["kubectl", "get", "deployment", "aap-mcp-server", "-n", self.aap_namespace, "-o", "json"],
            ["kubectl", "wait", "--for=condition=Available", "deployment/aap-mcp-server", "-n", self.aap_namespace, f"--timeout={self.timeout}s"],
        )
        status = self.runner.run(["aap-demo", "status"], timeout=self.timeout)
        product_demos_ready = status.returncode == 0 and "product-demos" in status.stdout and "enabled" in status.stdout
        return {"mcp": mcp_ready, "product_demos": product_demos_ready}


def _check(check_id: str, component: str, status: CheckStatus, summary: str, *, details=None) -> CheckResult:
    now = datetime.now(UTC).isoformat()
    return CheckResult(
        check_id=check_id,
        component=component,
        status=status,
        failure_class=FailureClass.PREREQUISITE if status in (CheckStatus.FAIL, CheckStatus.BLOCKED) else None,
        summary=summary,
        started_at=now,
        finished_at=now,
        duration_seconds=0.0,
        details=details or {},
    )


def validate_target(config: RunConfig, inspector: TargetInspector) -> list[CheckResult]:
    """Return context, credential, and prerequisite results without mutation."""
    results: list[CheckResult] = []
    context = inspector.current_context()
    if not context:
        return [_check("target.context", "target", CheckStatus.BLOCKED, "unable to determine Kubernetes context")]
    if config.context and config.context != context:
        return [_check("target.context", "target", CheckStatus.BLOCKED, "selected context does not match the active Kubernetes context", details={"expected": config.context, "actual": context})]
    results.append(_check("target.context", "target", CheckStatus.PASS, "Kubernetes context verified", details={"context": context}))
    if not inspector.credentials_ready():
        return results + [_check("target.credentials", "target", CheckStatus.BLOCKED, "current Kubernetes credentials cannot read namespaces")]
    results.append(_check("target.credentials", "target", CheckStatus.PASS, "Kubernetes credentials verified"))

    readiness = {
        "aap_demo": inspector.aap_demo_ready(),
        "ao": inspector.ao_ready(),
        **inspector.required_addons_ready(),
    }
    for component, ready in readiness.items():
        if ready:
            results.append(_check(f"target.{component}", component, CheckStatus.PASS, f"{component} is ready", details={"ready": True}))
        elif config.mode == "validate":
            results.append(_check(f"target.{component}", component, CheckStatus.FAIL, f"{component} is a required prerequisite", details={"ready": False}))
        else:
            results.append(_check(f"target.{component}", component, CheckStatus.SKIP, f"{component} is missing and may be provisioned", details={"ready": False}))
    return results


def prepare_target(config: RunConfig, runner: CommandRunner, missing: set[str] | None = None) -> list[CheckResult]:
    """Run only the AAP-Demo lifecycle commands selected by the mode."""
    required = {"aap_demo", "ao", "mcp", "product_demos"} if config.mode == "provision" else (missing or set())
    commands: list[tuple[str, list[str], set[str]]] = [
        ("aap_demo", ["aap-demo", "deploy"], {"aap_demo"}),
        ("ao", ["aap-demo", "enable", "ao"], {"ao", "mcp"}),
        ("product_demos", ["aap-demo", "enable", "product-demos"], {"product_demos"}),
    ]
    results: list[CheckResult] = []
    for component, args, covers in commands:
        if not required.intersection(covers):
            continue
        started = time.monotonic()
        outcome = runner.run(args, timeout=config.timeout_seconds)
        status = CheckStatus.PASS if outcome.returncode == 0 else CheckStatus.FAIL
        now = datetime.now(UTC).isoformat()
        results.append(CheckResult(
            check_id=f"prepare.{component}", component=component, status=status,
            failure_class=None if status == CheckStatus.PASS else FailureClass.EXECUTION,
            summary=f"{'completed' if status == CheckStatus.PASS else 'failed'}: {' '.join(args)}",
            started_at=now, finished_at=now, duration_seconds=time.monotonic() - started,
            details={"returncode": outcome.returncode},
        ))
        if status == CheckStatus.FAIL:
            break
    return results
