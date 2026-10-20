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


MAX_PAYLOAD_BYTES = 65536
_FINAL_OUTPUT_MARKER = f"[diagnostic truncated: final output exceeds {MAX_PAYLOAD_BYTES} bytes]"
_MAX_PODS = 5
_POD_NAME = re.compile(r"^pod/[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
_GIT_COMMIT = re.compile(r"^[0-9a-f]{7,64}$")


def _result_dict(result: CheckResult | dict[str, object]) -> dict[str, object]:
    if isinstance(result, CheckResult):
        return result.to_dict()
    return dict(result)


def serialize_json(value: object) -> str:
    """Return final redacted JSON that cannot exceed the artifact byte budget."""
    serialized = json.dumps(
        redact(_bounded_payload(value)),
        indent=2,
        sort_keys=True,
        default=lambda _: "[diagnostic omitted: unsafe value]",
    ) + "\n"
    if len(serialized.encode("utf-8")) > MAX_PAYLOAD_BYTES:
        return json.dumps({"diagnostic": _FINAL_OUTPUT_MARKER}, indent=2, sort_keys=True) + "\n"
    return serialized


def _bounded_final_text(text: str) -> str:
    """Truncate final text on a UTF-8 boundary and retain an explicit marker."""
    encoded = text.encode("utf-8")
    if len(encoded) <= MAX_PAYLOAD_BYTES:
        return text
    marker = f"\n{_FINAL_OUTPUT_MARKER}\n"
    prefix = encoded[:MAX_PAYLOAD_BYTES - len(marker.encode("utf-8"))].decode("utf-8", errors="ignore")
    return prefix + marker


def _write_text(path: Path, text: str) -> None:
    """Apply final free-form redaction at the only diagnostic write boundary."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(_bounded_final_text(redact_text(text)), encoding="utf-8")


def _write_json(path: Path, value: object) -> None:
    _write_text(path, serialize_json(value))


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


def _bounded_payload(value: object) -> object:
    """Fail closed when a single structured diagnostic exceeds its byte budget."""
    try:
        encoded = json.dumps(value, default=lambda _: "[diagnostic omitted: unsafe value]").encode("utf-8")
    except (TypeError, ValueError, OverflowError):
        return "[diagnostic omitted: payload cannot be safely serialized]"
    if len(encoded) > MAX_PAYLOAD_BYTES:
        return f"[diagnostic truncated: payload exceeds {MAX_PAYLOAD_BYTES} bytes]"
    return value


def _omitted_text(value: object) -> str:
    """Never persist an unstructured command, log, or scenario text stream."""
    return f"[diagnostic omitted: untrusted free-form text ({len(str(value))} characters)]"


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
        commit = self._repository_commit(runner, config.timeout_seconds)
        metadata = {"config": _config_metadata(config), "repository_commit": commit}
        _write_json(bundle / "metadata.json", metadata)
        try:
            scenario = _omitted_text(config.scenario_file.read_text(encoding="utf-8"))
        except OSError as error:
            scenario = f"[diagnostic omitted: scenario metadata unavailable: {redact_text(str(error))}]"
        _write_json(bundle / "scenario.json", {"path": str(config.scenario_file), "content": scenario})

    @staticmethod
    def _repository_commit(runner: CommandRunner, timeout: int) -> str:
        try:
            result = runner.run(["git", "rev-parse", "HEAD"], timeout=timeout)
        except Exception:
            return "[diagnostic omitted: repository commit unavailable]"
        value = str(getattr(result, "stdout", "")).strip()
        if getattr(result, "returncode", 1) == 0 and _GIT_COMMIT.fullmatch(value):
            return value
        return "[diagnostic omitted: repository commit unavailable]"

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
        }
        for filename, args in commands.items():
            outcome = self._command(runner, args, config.timeout_seconds)
            _write_json(bundle / filename, outcome)
        pod_args = ["kubectl", "get", "pods", "-n", config.namespace, "-l", "app.kubernetes.io/component=backend", "-o", "name"]
        pod_listing, pod_names = self._pod_listing(runner, pod_args, config.timeout_seconds)
        _write_json(bundle / "ao-pods.txt", pod_listing)
        for index, pod in enumerate(pod_names):
            _write_json(
                bundle / f"ao-pod-{index}.log",
                self._command(runner, ["kubectl", "logs", "-n", config.namespace, pod, "--tail=100"], config.timeout_seconds),
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
            result = asdict(result)
        return _bounded_payload(result)

    @staticmethod
    def _command(runner: CommandRunner, args: list[str], timeout: int) -> dict[str, object]:
        try:
            result = runner.run(args, timeout=timeout)
        except Exception as error:
            return {"args": args, "diagnostic": f"[diagnostic omitted: command failed: {redact_text(str(error))}]"}
        return ArtifactCollector._command_outcome(args, result)

    @staticmethod
    def _pod_listing(runner: CommandRunner, args: list[str], timeout: int) -> tuple[dict[str, object], list[str]]:
        """Select validated pod names in memory while persisting no listing output."""
        try:
            result = runner.run(args, timeout=timeout)
        except Exception as error:
            return (
                {"args": args, "diagnostic": f"[diagnostic omitted: command failed: {redact_text(str(error))}]"},
                [],
            )
        stdout = getattr(result, "stdout", "")
        pod_lines = stdout.splitlines() if isinstance(stdout, str) else []
        pod_names = [
            candidate.strip()
            for candidate in pod_lines
            if _POD_NAME.fullmatch(candidate.strip())
        ][:_MAX_PODS]
        return ArtifactCollector._command_outcome(args, result), pod_names

    @staticmethod
    def _command_outcome(args: list[str], result: object) -> dict[str, object]:
        """Persist command metadata while omitting untrusted output streams."""
        return {
            "args": args,
            "returncode": getattr(result, "returncode", "[diagnostic omitted: invalid command result]"),
            "stdout": _omitted_text(getattr(result, "stdout", "")),
            "stderr": _omitted_text(getattr(result, "stderr", "")),
        }
