"""Command-line scaffold for AO/AAP-Demo live acceptance checks."""

import argparse
from dataclasses import asdict
import json
from pathlib import Path
import sys

try:
    from .model import CheckResult, CheckStatus, RunConfig
    from .environment import CommandRunner, TargetInspector, prepare_target, validate_target
    from .inventory import build_inventory
    from .checks import execution_environments, readiness, security, wiring
except ImportError:  # Direct execution via run.sh or python runner.py.
    from model import CheckResult, CheckStatus, RunConfig
    from environment import CommandRunner, TargetInspector, prepare_target, validate_target
    from inventory import build_inventory
    from checks import execution_environments, readiness, security, wiring


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
        inspection = TargetInspector(command_runner, config)
        results.extend(validate_target(config, inspection))
        blocked = any(result.status == CheckStatus.BLOCKED for result in results)
        missing = {
            result.component
            for result in results
            if result.check_id.startswith("target.") and result.details.get("ready") is False
        }
        if not blocked and (config.mode == "provision" or (config.mode == "auto" and missing)):
            preparation = prepare_target(config, command_runner, missing)
            results.extend(preparation)
            mutated = bool(preparation)
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
