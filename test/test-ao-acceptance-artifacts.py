"""Focused safety and integration tests for AO acceptance artifacts."""

import contextlib
from dataclasses import dataclass
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ACCEPTANCE_DIR = Path(__file__).parent / "ao-acceptance"
sys.path.insert(0, str(ACCEPTANCE_DIR))

import artifacts  # noqa: E402
from environment import CommandResult  # noqa: E402
from model import CheckResult, CheckStatus, FailureClass, RunConfig  # noqa: E402
import runner  # noqa: E402


SECRETS = (
    "correct-horse-battery-staple",
    "bearer-live-token",
    "api-key-value",
    "exception-password",
    "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "github_pat_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "sk-proj-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "opaque-pod-log-value",
    "synthetic-unlabeled-api-secret",
    "synthetic-unlabeled-event-secret",
)


class UnsafeDiagnostic:
    def __repr__(self):
        return "UnsafeDiagnostic(password=correct-horse-battery-staple)"


def check(
    status=CheckStatus.FAIL,
    failure_class=FailureClass.EXECUTION,
    summary="workflow failed: password=correct-horse-battery-staple",
):
    return CheckResult(
        check_id="workflow.demo",
        component="workflow:demo",
        status=status,
        failure_class=failure_class,
        summary=summary,
        started_at="2026-10-20T12:00:00+00:00",
        finished_at="2026-10-20T12:00:01+00:00",
        duration_seconds=1.0,
        details={
            "workflow_id": "workflow-42",
            "job_ids": [7],
            "api_key": "api-key-value",
            "exception": RuntimeError("password=exception-password"),
            "unknown": UnsafeDiagnostic(),
        },
    )


class FakeAap:
    def get(self, path):
        if "job_events" in path:
            return {
                "count": 1,
                "results": [{
                    "id": 99,
                    "event": "runner_on_ok",
                    "stdout": "synthetic-unlabeled-event-secret",
                }],
            }
        return {
            "path": path,
            "message": "synthetic-unlabeled-api-secret",
            "token": "bearer-live-token",
            "nested": {"password": "correct-horse-battery-staple"},
            "opaque": "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "github_token": "github_pat_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "openai_project_key": "sk-proj-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "X-API-Key": "api-key-value",
            "x-access-token": "bearer-live-token",
            "raw_headers": "X-API-Key: api-key-value; x-access-token=bearer-live-token; github_pat_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; sk-proj-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        }

    def job_status(self, job_id):
        return {
            "id": job_id,
            "status": "failed",
            "authorization": "Bearer bearer-live-token",
            "result": "synthetic-unlabeled-api-secret",
        }


class FakeAo:
    def get(self, path):
        raise RuntimeError("api_key=api-key-value password=exception-password")

    def workflow_status(self, execution_id):
        return {"id": execution_id, "secret": "correct-horse-battery-staple"}


class FakeProbe:
    aap_url = "https://aap.example.test"
    ao_url = "https://ao.example.test"
    mcp_url = "https://mcp.example.test"
    ee_namespace = "aap-operator"
    ee_selector = "app=task"

    def host_dns(self, host):
        return {"host": host, "password": "correct-horse-battery-staple"}

    def host_https(self, url):
        return {"url": url, "api_key": "api-key-value"}

    def ee_https(self, namespace, selector, url):
        return {"namespace": namespace, "selector": selector, "bearer": "bearer-live-token"}


class FakeCommandRunner:
    def __init__(self):
        self.calls = []

    def run(self, args, *, check=False, timeout=60):
        del check, timeout
        self.calls.append(args)
        if args[:3] == ["git", "rev-parse", "HEAD"]:
            return CommandResult(0, "0123456789abcdef\n", "")
        if args[:3] == ["kubectl", "get", "pods"]:
            return CommandResult(0, "pod/ao-backend-0\n", "")
        if args[:2] == ["kubectl", "logs"]:
            return CommandResult(0, "opaque-pod-log-value X-API-Key: api-key-value", "")
        return CommandResult(
            0,
            "api_key=api-key-value Bearer bearer-live-token password=correct-horse-battery-staple ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "password=exception-password",
        )


class ArtifactSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.config = RunConfig(
            mode="validate",
            namespace="automation-orchestrator",
            artifact_dir=Path(self.tempdir.name) / "artifacts",
            context="microshift",
            scenario_file=Path("scenario.json"),
            timeout_seconds=12,
            dry_run=False,
        )

    def tearDown(self):
        self.tempdir.cleanup()

    def test_result_and_summary_writers_redact_details_and_omit_unknown_values(self):
        # Break caught: serializing result details directly writes a secret.
        results_path = Path(self.tempdir.name) / "results.json"
        summary_path = Path(self.tempdir.name) / "summary.txt"

        artifacts.write_results(results_path, [check()])
        artifacts.write_summary(summary_path, [check()])

        text = results_path.read_text() + summary_path.read_text()
        self.assertIn("[REDACTED]", text)
        self.assertIn("omitted unsafe value", text)
        for secret in SECRETS:
            self.assertNotIn(secret, text)

    def test_collector_redacts_api_command_probe_and_exception_diagnostics(self):
        # Break caught: persisting an untrusted command/log stream or raw API fields.
        collector = artifacts.ArtifactCollector(now=lambda: "20261020T120000Z")
        bundle = collector.collect_failure(
            self.config,
            [check()],
            {"aap": FakeAap(), "ao": FakeAo(), "probes": FakeProbe()},
            FakeCommandRunner(),
        )

        self.assertTrue(bundle.is_dir())
        text = "\n".join(path.read_text() for path in bundle.iterdir() if path.is_file())
        self.assertIn("[REDACTED]", text)
        self.assertIn("diagnostic omitted", text)
        self.assertIn("0123456789abcdef", text)
        api_payload = json.loads((bundle / "api.json").read_text())
        self.assertEqual(api_payload["aap_job_7"]["id"], 7)
        self.assertEqual(api_payload["aap_job_7"]["status"], "failed")
        for secret in SECRETS:
            self.assertNotIn(secret, text)

    def test_collector_omits_oversized_api_payload_before_write(self):
        # Break caught: removing the per-observation diagnostic payload bound.
        class OversizedAap(FakeAap):
            def get(self, path):
                return {"payload": "x" * 65537}

        bundle = artifacts.ArtifactCollector(now=lambda: "20261020T120000Z").collect_failure(
            self.config,
            [check()],
            {"aap": OversizedAap(), "ao": FakeAo(), "probes": FakeProbe()},
            FakeCommandRunner(),
        )

        api_text = (bundle / "api.json").read_text()
        self.assertNotIn("x" * 128, api_text)
        self.assertLess(len(api_text.encode("utf-8")), 1024)

    def test_final_artifacts_are_bounded_after_redaction_expands_text(self):
        # Break caught: capping input before token redaction permits oversized files.
        expanding_text = "token=x," * 5000
        results_path = Path(self.tempdir.name) / "results.json"
        summary_path = Path(self.tempdir.name) / "summary.txt"
        artifacts.write_results(results_path, [check(summary=expanding_text)])
        artifacts.write_summary(summary_path, [check(summary=expanding_text)])

        class ExpandingAap:
            def get(self, path):
                return {"message": expanding_text}

        api_result = check()
        api_result.details["job_ids"] = []
        bundle = artifacts.ArtifactCollector(now=lambda: "20261020T120000Z").collect_failure(
            self.config,
            [api_result],
            {"aap": ExpandingAap()},
            FakeCommandRunner(),
        )

        for path in (results_path, summary_path, bundle / "api.json"):
            with self.subTest(path=path.name):
                serialized = path.read_text()
                self.assertLessEqual(len(serialized.encode("utf-8")), artifacts.MAX_PAYLOAD_BYTES)
                if path.name == "api.json":
                    self.assertNotIn(expanding_text, serialized)
                else:
                    self.assertIn("final output exceeds", serialized)

    def test_collector_selects_valid_pods_in_memory_and_writes_safe_log_artifact(self):
        # Break caught: omitting pod-list stdout before selection prevents log collection.
        command_runner = FakeCommandRunner()
        bundle = artifacts.ArtifactCollector(now=lambda: "20261020T120000Z").collect_failure(
            self.config,
            [check()],
            {},
            command_runner,
        )

        self.assertIn(
            ["kubectl", "logs", "-n", self.config.namespace, "pod/ao-backend-0", "--tail=100"],
            command_runner.calls,
        )
        log_text = (bundle / "ao-pod-0.log").read_text()
        self.assertIn("diagnostic omitted", log_text)
        self.assertNotIn("opaque-pod-log-value", log_text)
        self.assertNotIn("api-key-value", log_text)


class RunnerArtifactIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.config = RunConfig(
            mode="validate",
            namespace="automation-orchestrator",
            artifact_dir=Path(self.tempdir.name),
            context="microshift",
            scenario_file=Path("scenario.json"),
            timeout_seconds=12,
            dry_run=False,
        )

    def tearDown(self):
        self.tempdir.cleanup()

    def _run_result(self, result):
        return {
            "config": {"mode": "validate"},
            "results": [result.to_dict()],
            "mutated": False,
            "_check_results": [result],
            "_diagnostic_context": {"clients": {}, "command_runner": FakeCommandRunner()},
        }

    def test_main_writes_base_results_and_collects_failure_diagnostics(self):
        failed = check()
        with (
            mock.patch.object(runner, "parse_args", return_value=self.config),
            mock.patch.object(runner, "_run", return_value=self._run_result(failed)),
            mock.patch.object(runner.artifacts.ArtifactCollector, "collect_failure", return_value=Path("bundle")) as collect,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            exit_code = runner.main([])

        self.assertEqual(exit_code, 1)
        self.assertTrue((self.config.artifact_dir / "results.json").is_file())
        self.assertTrue((self.config.artifact_dir / "summary.txt").is_file())
        collect.assert_called_once()

    def test_main_bounds_printed_json_after_redaction_expands_text(self):
        # Break caught: printed JSON bypasses the final artifact serialization boundary.
        failed = check(summary="token=x," * 5000)
        stdout = io.StringIO()
        with (
            mock.patch.object(runner, "parse_args", return_value=self.config),
            mock.patch.object(runner, "_run", return_value=self._run_result(failed)),
            mock.patch.object(runner.artifacts.ArtifactCollector, "collect_failure", return_value=Path("bundle")),
            contextlib.redirect_stdout(stdout),
        ):
            self.assertEqual(runner.main([]), 1)

        serialized = stdout.getvalue()
        self.assertLessEqual(len(serialized.encode("utf-8")), artifacts.MAX_PAYLOAD_BYTES)
        self.assertIn("final output exceeds", serialized)

    def test_main_returns_two_for_blocked_or_prerequisite_results(self):
        for result in (
            check(CheckStatus.BLOCKED, FailureClass.PREREQUISITE),
            check(CheckStatus.FAIL, FailureClass.PREREQUISITE),
            check(CheckStatus.SKIP, None),
            runner._scenario_failure(ValueError("invalid scenario"), Path("scenario.json")),
        ):
            with self.subTest(status=result.status, failure_class=result.failure_class):
                with (
                    mock.patch.object(runner, "parse_args", return_value=self.config),
                    mock.patch.object(runner, "_run", return_value=self._run_result(result)),
                    mock.patch.object(runner.artifacts.ArtifactCollector, "collect_failure", return_value=Path("bundle")),
                    contextlib.redirect_stdout(io.StringIO()),
                ):
                    self.assertEqual(runner.main([]), 2)

    def test_main_returns_two_when_no_check_executed(self):
        run_result = self._run_result(check(CheckStatus.PASS, None))
        run_result["results"] = []
        run_result["_check_results"] = []
        with (
            mock.patch.object(runner, "parse_args", return_value=self.config),
            mock.patch.object(runner, "_run", return_value=run_result),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(runner.main([]), 2)

    def test_main_does_not_collect_cluster_diagnostics_for_unapproved_context(self):
        blocked = CheckResult(
            check_id="target.context",
            component="target",
            status=CheckStatus.BLOCKED,
            failure_class=FailureClass.PREREQUISITE,
            summary="selected context does not match",
            started_at="",
            finished_at="",
            duration_seconds=0.0,
            details={"expected": "approved", "actual": "unapproved"},
        )
        run_result = self._run_result(blocked)
        run_result["_diagnostic_context"]["target_approved"] = False
        with (
            mock.patch.object(runner, "parse_args", return_value=self.config),
            mock.patch.object(runner, "_run", return_value=run_result),
            mock.patch.object(runner.artifacts.ArtifactCollector, "collect_failure") as collect,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(runner.main([]), 2)

        collect.assert_not_called()

    def test_diagnostic_collection_error_keeps_original_check_exit_code(self):
        failed = check()
        with (
            mock.patch.object(runner, "parse_args", return_value=self.config),
            mock.patch.object(runner, "_run", return_value=self._run_result(failed)),
            mock.patch.object(runner.artifacts.ArtifactCollector, "collect_failure", side_effect=RuntimeError("token=bearer-live-token")),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()) as stderr,
        ):
            exit_code = runner.main([])

        self.assertEqual(exit_code, 1)
        self.assertNotIn("bearer-live-token", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
