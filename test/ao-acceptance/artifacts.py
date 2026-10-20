"""Bounded, redacted diagnostics for failed AO acceptance runs."""

from dataclasses import asdict, is_dataclass
from datetime import UTC, datetime
import json
from pathlib import Path
import re
from typing import Callable
from urllib.parse import urlparse

try:
    from .environment import CommandRunner
    from .model import CheckResult, RunConfig
    from .redaction import redact, redact_text
except ImportError:  # Direct execution via run.sh or python runner.py.
    from environment import CommandRunner
    from model import CheckResult, RunConfig
    from redaction import redact, redact_text


_MAX_TEXT = 65536
_MAX_PODS = 5
_POD_NAME = re.compile(r"^pod/[a-z0-9]([-a-z0-9]*[a-z0-9])?$")


def _result_dict(result: CheckResult | dict[str, object]) -> dict[str, object]:
    if isinstance(result, CheckResult):
        return result.to_dict()
    return dict(result)


def _safe_json(value: object) -> str:
    """Serialize only a recursively-redacted diagnostic value."""
    return json.dumps(redact(value), indent=2, sort_keys=True, default=lambda _: "[diagnostic omitted: unsafe value]") + "\n"


def _write_text(path: Path, text: str) -> None:
    """Apply final free-form redaction at the only diagnostic write boundary."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(redact_text(text), encoding="utf-8")


def _write_json(path: Path, value: object) -> None:
    _write_text(path, _safe_json(value))


def write_results(path: Path, results: list[CheckResult]) -> None:
    """Write sanitized machine-readable check results."""
    _write_json(path, [_result_dict(result) for result in results])


def write_summary(path: Path, results: list[CheckResult]) -> None:
    """Write a concise, readable and sanitized run summary."""
    serialized = [_result_dict(result) for result in results]
    lines = ["AO/AAP-Demo live acceptance summary", f"Checks: {len(serialized)}"]
    for result in serialized:
        failure_class = result.get("failure_class") or "-"
        lines.append(
            "{status} {check_id} ({component}; {failure_class}): {summary}".format(
                status=result.get("status", "UNKNOWN"),
                check_id=result.get("check_id", "unknown"),
                component=result.get("component", "unknown"),
                failure_class=failure_class,
                summary=result.get("summary", ""),
            )
        )
    _write_text(path, "\n".join(lines) + "\n")


def _config_metadata(config: RunConfig) -> dict[str, object]:
    metadata = asdict(config)
    metadata["artifact_dir"] = str(config.artifact_dir)
    metadata["scenario_file"] = str(config.scenario_file)
    return metadata


def _bounded_text(value: object) -> str:
    return redact_text(str(value))[:_MAX_TEXT]


class ArtifactCollector:
    """Collect only bounded observations necessary to investigate a failure."""

    def __init__(self, now: Callable[[], object] | None = None):
        self._now = now or (lambda: datetime.now(UTC))

    def collect_failure(
        self,
        run_config: RunConfig,
        results: list[CheckResult],
        clients: dict,
        command_runner: CommandRunner,
    ) -> Path:
        bundle = self._bundle_path(run_config.artifact_dir)
        bundle.mkdir(parents=True, exist_ok=False)

        write_results(bundle / "results.json", results)
        write_summary(bundle / "summary.txt", results)
        self._collect_metadata(bundle, run_config, command_runner)
        self._collect_api(bundle, results, clients)
        self._collect_probes(bundle, clients.get("probes"))
        self._collect_kubernetes(bundle, run_config, command_runner)
        return bundle

    def _bundle_path(self, root: Path) -> Path:
        value = self._now()
        timestamp = value if isinstance(value, str) else value.strftime("%Y%m%dT%H%M%SZ")
        candidate = root / f"failure-{timestamp}"
        suffix = 1
        while candidate.exists():
            candidate = root / f"failure-{timestamp}-{suffix}"
            suffix += 1
        return candidate

    def _collect_metadata(self, bundle: Path, config: RunConfig, runner: CommandRunner) -> None:
        commit = self._command(runner, ["git", "rev-parse", "HEAD"], config.timeout_seconds)
        metadata = {"config": _config_metadata(config), "repository_commit": commit}
        _write_json(bundle / "metadata.json", metadata)
        try:
            scenario = config.scenario_file.read_text(encoding="utf-8")[:_MAX_TEXT]
        except OSError as error:
            scenario = f"[diagnostic omitted: scenario metadata unavailable: {redact_text(str(error))}]"
        _write_text(bundle / "scenario.json", scenario)

    def _collect_api(self, bundle: Path, results: list[CheckResult], clients: dict) -> None:
        aap = clients.get("aap")
        ao = clients.get("ao")
        observations: dict[str, object] = {}
        if aap is not None:
            observations["aap_status"] = self._observe(lambda: aap.get("/api/v2/ping/"))
            for job_id in self._ids(results, "job_ids"):
                if str(job_id).isdigit():
                    observations[f"aap_job_{job_id}"] = self._observe(lambda job_id=job_id: aap.job_status(int(job_id)))
                    observations[f"aap_job_events_{job_id}"] = self._observe(
                        lambda job_id=job_id: aap.get(f"/api/v2/jobs/{int(job_id)}/job_events/?order_by=counter&page_size=25")
                    )
        if ao is not None:
            observations["ao_status"] = self._observe(lambda: ao.get("/api/v1/health"))
            for execution_id in self._ids(results, "execution_id", "workflow_execution_id"):
                observations[f"ao_execution_{execution_id}"] = self._observe(
                    lambda execution_id=execution_id: ao.workflow_status(str(execution_id))
                )
        if not observations:
            observations["diagnostic"] = "[diagnostic omitted: authenticated clients unavailable]"
        _write_json(bundle / "api.json", observations)

    def _collect_probes(self, bundle: Path, probes: object) -> None:
        if probes is None:
            _write_json(bundle / "probes.json", {"diagnostic": "[diagnostic omitted: probe client unavailable]"})
            return
        observations: dict[str, object] = {}
        for name in ("aap", "ao", "mcp"):
            url = getattr(probes, f"{name}_url", None)
            if not isinstance(url, str) or not url:
                continue
            host = urlparse(url).hostname
            if host:
                observations[f"{name}_dns"] = self._observe(lambda host=host: probes.host_dns(host))
            observations[f"{name}_https"] = self._observe(lambda url=url: probes.host_https(url))
            if name == "aap" and hasattr(probes, "ee_https"):
                observations["aap_ee_https"] = self._observe(
                    lambda url=url: probes.ee_https(
                        getattr(probes, "ee_namespace", "aap-operator"),
                        getattr(probes, "ee_selector", "app.kubernetes.io/name=aap-controller-task"),
                        url,
                    )
                )
        _write_json(bundle / "probes.json", observations or {"diagnostic": "[diagnostic omitted: no probe URLs available]"})

    def _collect_kubernetes(self, bundle: Path, config: RunConfig, runner: CommandRunner) -> None:
        commands = {
            "ao-resource.yaml": ["kubectl", "get", "automationorchestrator", "automation-orchestrator", "-n", config.namespace, "-o", "yaml"],
            "aap-resource.yaml": ["kubectl", "get", "automationcontroller", "aap", "-n", config.aap_namespace, "-o", "yaml"],
            "ao-description.txt": ["kubectl", "describe", "automationorchestrator", "automation-orchestrator", "-n", config.namespace],
            "ao-events.txt": ["kubectl", "get", "events", "-n", config.namespace, "--sort-by=.lastTimestamp"],
            "aap-events.txt": ["kubectl", "get", "events", "-n", config.aap_namespace, "--sort-by=.lastTimestamp"],
            "ao-pods.txt": ["kubectl", "get", "pods", "-n", config.namespace, "-l", "app.kubernetes.io/component=backend", "-o", "name"],
        }
        pod_listing = None
        for filename, args in commands.items():
            outcome = self._command(runner, args, config.timeout_seconds)
            _write_json(bundle / filename, outcome)
            if filename == "ao-pods.txt":
                pod_listing = outcome
        if isinstance(pod_listing, dict):
            stdout = str(pod_listing.get("stdout", ""))
            for index, pod in enumerate(stdout.splitlines()[:_MAX_PODS]):
                if _POD_NAME.fullmatch(pod.strip()):
                    _write_json(
                        bundle / f"ao-pod-{index}.log",
                        self._command(runner, ["kubectl", "logs", "-n", config.namespace, pod.strip(), "--tail=100"], config.timeout_seconds),
                    )

    @staticmethod
    def _ids(results: list[CheckResult], *keys: str) -> list[object]:
        values: list[object] = []
        for result in results:
            for key in keys:
                value = result.details.get(key)
                if isinstance(value, list):
                    values.extend(value)
                elif value not in (None, ""):
                    values.append(value)
        return list(dict.fromkeys(values))

    @staticmethod
    def _observe(callback: Callable[[], object]) -> object:
        try:
            result = callback()
        except Exception as error:
            return f"[diagnostic omitted: observation failed: {redact_text(str(error))}]"
        if is_dataclass(result):
            return asdict(result)
        return result

    @staticmethod
    def _command(runner: CommandRunner, args: list[str], timeout: int) -> dict[str, object]:
        try:
            result = runner.run(args, timeout=timeout)
        except Exception as error:
            return {"args": args, "diagnostic": f"[diagnostic omitted: command failed: {redact_text(str(error))}]"}
        return {
            "args": args,
            "returncode": getattr(result, "returncode", "[diagnostic omitted: invalid command result]"),
            "stdout": _bounded_text(getattr(result, "stdout", "")),
            "stderr": _bounded_text(getattr(result, "stderr", "")),
        }
