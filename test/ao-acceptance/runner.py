"""Command-line scaffold for AO/AAP-Demo live acceptance checks."""

import argparse
from dataclasses import asdict
from datetime import UTC, datetime
import os
from pathlib import Path
import re
import sys

try:
    from .model import CheckResult, CheckStatus, FailureClass, RunConfig
    from .environment import CommandRunner, TargetInspector, prepare_target, validate_target
    from .inventory import build_inventory
    from .checks import execution_environments, readiness, security, wiring, workflows
    from .clients import AapClient, AoClient
    from .probes import McpToolsClient, ProbeSet
    from .redaction import redact_text
    from . import artifacts
    from . import scenarios as scenario_manifest
except ImportError:  # Direct execution via run.sh or python runner.py.
    from model import CheckResult, CheckStatus, FailureClass, RunConfig
    from environment import CommandRunner, TargetInspector, prepare_target, validate_target
    from inventory import build_inventory
    from checks import execution_environments, readiness, security, wiring, workflows
    from clients import AapClient, AoClient
    from probes import McpToolsClient, ProbeSet
    from redaction import redact_text
    import artifacts
    import scenarios as scenario_manifest


DEFAULT_ARTIFACT_DIR = Path("artifacts/ao-acceptance")
DEFAULT_SCENARIO_FILE = Path("test/ao-acceptance/scenarios/critical-path.json")
DEFAULT_MANAGED_MARKERS = {key: "aap-demo" for key in (
    "organizations",
    "projects",
    "inventories",
    "credentials",
    "job_templates",
    "execution_environments",
    "ao_integrations",
    "ao_workflows",
)}


def parse_args(argv: list[str]) -> RunConfig:
    parser = argparse.ArgumentParser(description="Run AO live acceptance checks")
    parser.add_argument(
        "--mode",
        choices=("auto", "provision", "validate"),
        default="auto",
        help="target preparation mode",
    )
    parser.add_argument(
        "--namespace",
        default="automation-orchestrator",
        help="Kubernetes namespace containing AO",
    )
    parser.add_argument("--context", help="Kubernetes context to validate")
    parser.add_argument(
        "--artifact-dir",
        type=Path,
        default=DEFAULT_ARTIFACT_DIR,
        help="directory for acceptance artifacts",
    )
    parser.add_argument(
        "--scenario-file",
        type=Path,
        default=DEFAULT_SCENARIO_FILE,
        help="JSON scenario manifest",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        dest="timeout_seconds",
        help="per-check timeout in seconds",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="parse options and report the run without contacting a cluster",
    )
    args = parser.parse_args(argv)
    return RunConfig(
        mode=args.mode,
        namespace=args.namespace,
        artifact_dir=args.artifact_dir,
        context=args.context,
        scenario_file=args.scenario_file,
        timeout_seconds=args.timeout_seconds,
        dry_run=args.dry_run,
    )


def _config_dict(config: RunConfig) -> dict[str, object]:
    values = asdict(config)
    values["artifact_dir"] = str(config.artifact_dir)
    values["scenario_file"] = str(config.scenario_file)
    return values


def run_managed_checks(
    aap,
    ao,
    probes,
    scenarios=None,
    managed_markers: dict[str, str] | None = None,
    command_runner: CommandRunner | None = None,
) -> list[CheckResult]:
    """Build a redacted managed-resource inventory and run read-only checks.

    Client construction remains outside this helper so the runner does not read
    or print credentials.  The eventual live configuration layer supplies the
    authenticated clients explicitly.
    """
    inventory = build_inventory(aap, ao, managed_markers or DEFAULT_MANAGED_MARKERS)
    command_runner = command_runner or getattr(probes, "runner", None) or CommandRunner()
    results = [
        *readiness.run(inventory, probes),
        *wiring.run(inventory),
        *security.run(inventory, probes),
    ]
    if any(result.status in (CheckStatus.FAIL, CheckStatus.BLOCKED) for result in results):
        return results
    if scenarios is not None:
        workflow_results = workflows.run(scenarios, inventory, ao, aap)
        results.extend(workflow_results)
        # Contract drift must stop all live launches, including EE checks.
        if any(result.failure_class == FailureClass.CONTRACT_DRIFT for result in workflow_results):
            return results
    results.extend(execution_environments.run(inventory, aap, command_runner))
    return results


def _route_url(
    command_runner: CommandRunner,
    namespace: str,
    *,
    name: str | None = None,
    selector: str | None = None,
    host_pattern: str | None = None,
    path: str = "",
) -> str | None:
    args = ["kubectl", "get", "route"]
    if name:
        args.append(name)
    args.extend(["-n", namespace])
    if selector:
        args.extend(["-l", selector])
    jsonpath = "jsonpath={.spec.host}" if name else "jsonpath={.items[0].spec.host}"
    if host_pattern:
        jsonpath = 'jsonpath={range .items[*]}{.spec.host}{"\\n"}{end}'
    args.extend(["-o", jsonpath])
    result = command_runner.run(args, timeout=getattr(command_runner, "timeout_seconds", 60))
    host = result.stdout.strip()
    if host_pattern and result.returncode == 0:
        host = next((candidate for candidate in host.splitlines() if re.search(host_pattern, candidate)), "")
    return f"https://{host}{path}" if result.returncode == 0 and host else None


def create_live_dependencies(config: RunConfig, command_runner: CommandRunner):
    """Create authenticated, injectable live boundaries without printing credentials.

    Tokens are intentionally supplied only through dedicated opt-in environment
    variables.  Their absence is a prerequisite failure rather than a fallback
    to Kubernetes secrets or an unauthenticated probe.
    """
    tokens = {
        "AAP_ACCEPTANCE_AAP_TOKEN": os.environ.get("AAP_ACCEPTANCE_AAP_TOKEN"),
        "AAP_ACCEPTANCE_AO_TOKEN": os.environ.get("AAP_ACCEPTANCE_AO_TOKEN"),
        "AAP_ACCEPTANCE_MCP_TOKEN": os.environ.get("AAP_ACCEPTANCE_MCP_TOKEN"),
    }
    missing = [name for name, value in tokens.items() if not value]
    if missing:
        return None, "live acceptance credentials are unavailable"
    aap_url = _route_url(command_runner, config.aap_namespace, name="aap")
    ao_url = _route_url(command_runner, config.namespace, name="automation-orchestrator")
    mcp_url = _route_url(
        command_runner,
        config.aap_namespace,
        host_pattern=r"(?:^|[.-])(?:aap-)?mcp(?:[.-]|$)",
        path="/mcp",
    )
    if not aap_url or not ao_url or not mcp_url:
        return None, "required AAP, AO, or MCP route is unavailable"
    ca_file = os.environ.get("AAP_ACCEPTANCE_CA_FILE") or None
    aap = AapClient(aap_url, tokens["AAP_ACCEPTANCE_AAP_TOKEN"], ca_file=ca_file)
    ao = AoClient(ao_url, tokens["AAP_ACCEPTANCE_AO_TOKEN"], ca_file=ca_file)
    mcp_client = McpToolsClient(
        command_runner, mcp_url, tokens["AAP_ACCEPTANCE_MCP_TOKEN"],
        ca_file=ca_file, timeout_seconds=config.timeout_seconds,
    )
    probes = ProbeSet(
        command_runner,
        ca_file=ca_file,
        timeout_seconds=config.timeout_seconds,
        ee_namespace=config.aap_namespace,
        ao_namespace=config.namespace,
        aap_url=aap_url,
        ao_url=ao_url,
        mcp_url=mcp_url,
        aap_client=aap,
        ao_client=ao,
        mcp_client=mcp_client,
    )
    return aap, ao, probes


def _prerequisite_failure(check_id: str, summary: str, *, details: dict[str, object] | None = None) -> CheckResult:
    now = datetime.now(UTC).isoformat()
    return CheckResult(
        check_id=check_id,
        component="runner",
        status=CheckStatus.FAIL,
        failure_class=FailureClass.PREREQUISITE,
        summary=summary,
        started_at=now,
        finished_at=now,
        duration_seconds=0.0,
        details=details or {},
    )


def _scenario_failure(error: Exception, scenario_file: Path) -> CheckResult:
    now = datetime.now(UTC).isoformat()
    return CheckResult(
        check_id="workflow.manifest",
        component="workflow",
        status=CheckStatus.FAIL,
        failure_class=FailureClass.CONTRACT_DRIFT,
        summary="scenario manifest is invalid; no workflow or job was launched",
        started_at=now,
        finished_at=now,
        duration_seconds=0.0,
        details={
            "scenario_id": None,
            "workflow_id": None,
            "job_template_ids": [],
            "job_ids": [],
            "scenario_file": str(scenario_file),
            "error": redact_text(str(error)),
        },
    )


def _run(config: RunConfig) -> dict[str, object]:
    """Create the run-level result container for the scaffold."""
    results: list[CheckResult] = []
    mutated = False
    diagnostic_context: dict[str, object] = {"clients": {}, "command_runner": None}
    if config.dry_run:
        results.append(
            CheckResult(
                check_id="runner.dry-run",
                component="runner",
                status=CheckStatus.SKIP,
                failure_class=None,
                summary="dry run requested; no live checks executed",
                started_at="",
                finished_at="",
                duration_seconds=0.0,
                details={},
            )
        )
    else:
        command_runner = CommandRunner()
        diagnostic_context["command_runner"] = command_runner
        # Keep the declared runner boundary while making timeout and namespace
        # observable to Task 5 checks and their injected test doubles.
        command_runner.timeout_seconds = config.timeout_seconds
        command_runner.aap_namespace = config.aap_namespace
        command_runner.ee_selector = "app.kubernetes.io/name=aap-controller-task"
        inspection = TargetInspector(command_runner, config)
        preflight = validate_target(config, inspection)
        results.extend(preflight)
        blocked = any(result.status == CheckStatus.BLOCKED for result in preflight)
        missing = {
            result.component
            for result in preflight
            if result.check_id.startswith("target.") and result.details.get("ready") is False
        }
        if not blocked and (config.mode == "provision" or (config.mode == "auto" and missing)):
            preparation = prepare_target(config, command_runner, missing)
            results.extend(preparation)
            mutated = bool(preparation)
            if all(result.status == CheckStatus.PASS for result in preparation):
                preflight = validate_target(config, inspection)
                results.extend(preflight)
        preflight_ok = bool(preflight) and all(result.status == CheckStatus.PASS for result in preflight)
        if preflight_ok:
            try:
                dependencies = create_live_dependencies(config, command_runner)
            except Exception as error:
                results.append(_prerequisite_failure(
                    "runner.live-dependencies",
                    "live acceptance dependencies could not be initialized",
                    details={"error": redact_text(str(error))},
                ))
                dependencies = None
            if dependencies is not None:
                if dependencies[0] is None:
                    results.append(_prerequisite_failure("runner.live-dependencies", dependencies[1]))
                else:
                    aap, ao, probes = dependencies
                    diagnostic_context["clients"] = {"aap": aap, "ao": ao, "probes": probes}
                    try:
                        loaded_scenarios = scenario_manifest.load(config.scenario_file)
                    except Exception as error:
                        results.append(_scenario_failure(error, config.scenario_file))
                    else:
                        try:
                            results.extend(run_managed_checks(
                                aap, ao, probes, scenarios=loaded_scenarios, command_runner=command_runner,
                            ))
                        except Exception as error:
                            results.append(_prerequisite_failure(
                                "runner.managed-checks",
                                "managed live checks could not be initialized or observed",
                                details={"error": redact_text(str(error))},
                            ))
    return {
        "config": _config_dict(config),
        "results": [result.to_dict() for result in results],
        "mutated": mutated,
        "_check_results": results,
        "_diagnostic_context": diagnostic_context,
    }


def _check_results(run_result: dict[str, object]) -> list[CheckResult]:
    """Use the private objects when available, with the old serialized seam."""
    raw_results = run_result.get("_check_results")
    if isinstance(raw_results, list) and all(isinstance(result, CheckResult) for result in raw_results):
        return raw_results
    check_results: list[CheckResult] = []
    for raw in run_result.get("results", []):
        if not isinstance(raw, dict):
            continue
        try:
            status = CheckStatus(raw["status"])
            failure = raw.get("failure_class")
            failure_class = FailureClass(failure) if failure is not None else None
        except (KeyError, TypeError, ValueError):
            continue
        details = raw.get("details", {})
        check_results.append(CheckResult(
            check_id=str(raw.get("check_id", "unknown")),
            component=str(raw.get("component", "unknown")),
            status=status,
            failure_class=failure_class,
            summary=str(raw.get("summary", "")),
            started_at=str(raw.get("started_at", "")),
            finished_at=str(raw.get("finished_at", "")),
            duration_seconds=float(raw.get("duration_seconds", 0.0)),
            details=details if isinstance(details, dict) else {},
        ))
    return check_results


def _exit_code(results: list[CheckResult]) -> int:
    """Classify outcomes without letting diagnostic collection affect the result."""
    if not results:
        return 2
    if any(
        result.status == CheckStatus.BLOCKED
        or result.failure_class == FailureClass.PREREQUISITE
        or result.status == CheckStatus.SKIP
        or result.check_id == "workflow.manifest"
        for result in results
    ):
        return 2
    return 0 if all(result.status == CheckStatus.PASS for result in results) else 1


def main(argv: list[str]) -> int:
    config = parse_args(argv)
    run_result = _run(config)
    results = _check_results(run_result)
    diagnostic_context = run_result.get("_diagnostic_context", {})
    try:
        artifacts.write_results(config.artifact_dir / "results.json", results)
        artifacts.write_summary(config.artifact_dir / "summary.txt", results)
    except Exception:
        print("acceptance result artifacts could not be written", file=sys.stderr)

    exit_code = _exit_code(results)
    command_runner = diagnostic_context.get("command_runner")
    if exit_code and command_runner is not None:
        try:
            artifacts.ArtifactCollector().collect_failure(
                config,
                results,
                diagnostic_context.get("clients", {}),
                command_runner,
            )
        except Exception:
            # Failure diagnostics are best-effort and must not conceal the
            # original failure or expose details from their own exception.
            print("acceptance failure diagnostics could not be collected", file=sys.stderr)

    public_result = {key: value for key, value in run_result.items() if not key.startswith("_")}
    print(artifacts.serialize_json(public_result), end="")
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
