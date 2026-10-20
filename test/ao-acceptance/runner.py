"""Command-line scaffold for AO/AAP-Demo live acceptance checks."""

import argparse
from dataclasses import asdict
from datetime import UTC, datetime
import json
import os
from pathlib import Path
import sys

try:
    from .model import CheckResult, CheckStatus, FailureClass, RunConfig
    from .environment import CommandRunner, TargetInspector, prepare_target, validate_target
    from .inventory import build_inventory
    from .checks import execution_environments, readiness, security, wiring
    from .clients import AapClient, AoClient
    from .probes import McpToolsClient, ProbeSet
    from .redaction import redact_text
except ImportError:  # Direct execution via run.sh or python runner.py.
    from model import CheckResult, CheckStatus, FailureClass, RunConfig
    from environment import CommandRunner, TargetInspector, prepare_target, validate_target
    from inventory import build_inventory
    from checks import execution_environments, readiness, security, wiring
    from clients import AapClient, AoClient
    from probes import McpToolsClient, ProbeSet
    from redaction import redact_text


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


def run_managed_checks(aap, ao, probes, managed_markers: dict[str, str] | None = None, command_runner: CommandRunner | None = None) -> list[CheckResult]:
    """Build a redacted managed-resource inventory and run read-only checks.

    Client construction remains outside this helper so the runner does not read
    or print credentials.  The eventual live configuration layer supplies the
    authenticated clients explicitly.
    """
    inventory = build_inventory(aap, ao, managed_markers or DEFAULT_MANAGED_MARKERS)
    command_runner = command_runner or getattr(probes, "runner", None) or CommandRunner()
    return [
        *readiness.run(inventory, probes),
        *wiring.run(inventory),
        *security.run(inventory, probes),
        *execution_environments.run(inventory, aap, command_runner),
    ]


def _route_url(command_runner: CommandRunner, namespace: str, *, name: str | None = None, selector: str | None = None, path: str = "") -> str | None:
    args = ["kubectl", "get", "route"]
    if name:
        args.append(name)
    args.extend(["-n", namespace])
    if selector:
        args.extend(["-l", selector])
    args.extend(["-o", "jsonpath={.items[0].spec.host}" if not name else "jsonpath={.spec.host}"])
    result = command_runner.run(args, timeout=getattr(command_runner, "timeout_seconds", 60))
    host = result.stdout.strip()
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
        selector="app.kubernetes.io/name=aap-mcp-server",
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


def _run(config: RunConfig) -> dict[str, object]:
    """Create the run-level result container for the scaffold."""
    results: list[CheckResult] = []
    mutated = False
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
            dependencies = create_live_dependencies(config, command_runner)
            if dependencies[0] is None:
                results.append(_prerequisite_failure("runner.live-dependencies", dependencies[1]))
            else:
                aap, ao, probes = dependencies
                try:
                    results.extend(run_managed_checks(aap, ao, probes, command_runner=command_runner))
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
    }


def main(argv: list[str]) -> int:
    config = parse_args(argv)
    run_result = _run(config)
    print(json.dumps(run_result, indent=2, sort_keys=True))
    results = run_result["results"]
    return 1 if any(
        result["status"] in (CheckStatus.FAIL.value, CheckStatus.BLOCKED.value)
        for result in results
    ) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
