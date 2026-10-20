"""Focused tests for the AO live acceptance runner scaffold."""

import json
from contextlib import redirect_stdout
import io
from pathlib import Path
import sys
import unittest
from unittest import mock


ACCEPTANCE_DIR = Path(__file__).parent / "ao-acceptance"
sys.path.insert(0, str(ACCEPTANCE_DIR))

import model  # noqa: E402
import runner  # noqa: E402


class ParseArgsTests(unittest.TestCase):
    def test_uses_documented_defaults(self):
        config = runner.parse_args([])

        self.assertEqual(config.mode, "auto")
        self.assertEqual(config.namespace, "automation-orchestrator")
        self.assertIsNone(config.context)
        self.assertEqual(config.artifact_dir, Path("artifacts/ao-acceptance"))
        self.assertEqual(
            config.scenario_file,
            Path("test/ao-acceptance/scenarios/critical-path.json"),
        )
        self.assertEqual(config.timeout_seconds, 300)
        self.assertFalse(config.dry_run)

    def test_parses_all_supported_options(self):
        config = runner.parse_args([
            "--mode",
            "validate",
            "--namespace",
            "ao-test",
            "--context",
            "microshift",
            "--artifact-dir",
            "/tmp/ao-results",
            "--scenario-file",
            "scenarios/smoke.json",
            "--timeout",
            "42",
            "--dry-run",
        ])

        self.assertEqual(config.mode, "validate")
        self.assertEqual(config.namespace, "ao-test")
        self.assertEqual(config.context, "microshift")
        self.assertEqual(config.artifact_dir, Path("/tmp/ao-results"))
        self.assertEqual(config.scenario_file, Path("scenarios/smoke.json"))
        self.assertEqual(config.timeout_seconds, 42)
        self.assertTrue(config.dry_run)

    def test_accepts_each_supported_mode(self):
        for mode in ("auto", "provision", "validate"):
            with self.subTest(mode=mode):
                self.assertEqual(runner.parse_args(["--mode", mode]).mode, mode)

    def test_rejects_invalid_mode(self):
        with self.assertRaises(SystemExit):
            runner.parse_args(["--mode", "destroy"])


class CheckResultSerializationTests(unittest.TestCase):
    def test_serializes_enums_and_preserves_timestamps(self):
        result = model.CheckResult(
            check_id="ao.route",
            component="ao",
            status=model.CheckStatus.PASS,
            failure_class=model.FailureClass.WIRING,
            summary="route is ready",
            started_at="2026-10-20T12:00:00+00:00",
            finished_at="2026-10-20T12:00:01+00:00",
            duration_seconds=1.0,
            details={"http_status": 200},
        )

        encoded = json.dumps(result.to_dict())
        decoded = json.loads(encoded)

        self.assertEqual(decoded["status"], "PASS")
        self.assertEqual(decoded["failure_class"], "wiring")
        self.assertEqual(decoded["started_at"], "2026-10-20T12:00:00+00:00")
        self.assertEqual(decoded["finished_at"], "2026-10-20T12:00:01+00:00")
        self.assertEqual(decoded["details"], {"http_status": 200})


class ManagedCheckWiringTests(unittest.TestCase):
    def test_runs_security_and_execution_environment_checks_with_injected_boundaries(self):
        inventory = object()
        command_runner = type("RunnerStub", (), {})()
        security_result = model.CheckResult(
            "security.tokens", "token", model.CheckStatus.PASS,
            None, "observed", "", "", 0.0, {},
        )
        ee_result = model.CheckResult(
            "ee.1.representative-job", "ee:one", model.CheckStatus.PASS,
            None, "observed", "", "", 0.0, {},
        )
        with (
            mock.patch.object(runner, "build_inventory", return_value=inventory),
            mock.patch.object(runner.readiness, "run", return_value=[]),
            mock.patch.object(runner.wiring, "run", return_value=[]),
            mock.patch.object(runner.security, "run", return_value=[security_result]) as security_run,
            mock.patch.object(runner.execution_environments, "run", return_value=[ee_result]) as ee_run,
        ):
            results = runner.run_managed_checks("aap", "ao", "probes", command_runner=command_runner)

        self.assertEqual(results, [security_result, ee_result])
        security_run.assert_called_once_with(inventory, "probes")
        ee_run.assert_called_once_with(inventory, "aap", command_runner)


class LiveRunnerTests(unittest.TestCase):
    def setUp(self):
        self.config = model.RunConfig(
            mode="validate",
            namespace="automation-orchestrator",
            artifact_dir=Path("artifacts/ao-acceptance"),
            context=None,
            scenario_file=Path("test/ao-acceptance/scenarios/critical-path.json"),
            timeout_seconds=47,
            dry_run=False,
        )

    def test_runs_managed_checks_after_successful_preflight_with_configured_timeout(self):
        preflight = model.CheckResult(
            "target.context", "target", model.CheckStatus.PASS, None,
            "ready", "", "", 0.0, {"ready": True},
        )
        managed = model.CheckResult(
            "security.tokens", "token", model.CheckStatus.PASS, None,
            "observed", "", "", 0.0, {},
        )
        command_runner = type("RunnerStub", (), {})()
        dependencies = ("aap", "ao", "probes")
        with (
            mock.patch.object(runner, "CommandRunner", return_value=command_runner),
            mock.patch.object(runner, "TargetInspector"),
            mock.patch.object(runner, "validate_target", return_value=[preflight]),
            mock.patch.object(runner, "create_live_dependencies", return_value=dependencies) as create,
            mock.patch.object(runner, "run_managed_checks", return_value=[managed]) as managed_checks,
        ):
            result = runner._run(self.config)

        self.assertEqual(result["results"][-1]["check_id"], "security.tokens")
        self.assertEqual(command_runner.timeout_seconds, 47)
        create.assert_called_once_with(self.config, command_runner)
        managed_checks.assert_called_once_with("aap", "ao", "probes", command_runner=command_runner)

    def test_missing_live_dependencies_is_a_prerequisite_failure(self):
        preflight = model.CheckResult(
            "target.context", "target", model.CheckStatus.PASS, None,
            "ready", "", "", 0.0, {"ready": True},
        )
        with (
            mock.patch.object(runner, "CommandRunner", return_value=type("RunnerStub", (), {})()),
            mock.patch.object(runner, "TargetInspector"),
            mock.patch.object(runner, "validate_target", return_value=[preflight]),
            mock.patch.object(runner, "create_live_dependencies", return_value=(None, "live credentials unavailable")),
        ):
            result = runner._run(self.config)

        live = next(item for item in result["results"] if item["check_id"] == "runner.live-dependencies")
        self.assertEqual(live["status"], model.CheckStatus.FAIL.value)
        self.assertEqual(live["failure_class"], model.FailureClass.PREREQUISITE.value)


class RunnerExitTests(unittest.TestCase):
    def test_dry_run_returns_success(self):
        self.assertEqual(runner.main(["--dry-run"]), 0)

    def test_fail_result_returns_failure_exit_code(self):
        result = model.CheckResult(
            "check.fail", "ao", model.CheckStatus.FAIL,
            model.FailureClass.EXECUTION, "failed", "", "", 0.0, {},
        )
        with mock.patch.object(runner, "_run", return_value={
            "config": {}, "results": [result.to_dict()],
        }), redirect_stdout(io.StringIO()):
            self.assertEqual(runner.main([]), 1)

    def test_blocked_result_returns_failure_exit_code(self):
        result = model.CheckResult(
            "check.blocked", "ao", model.CheckStatus.BLOCKED,
            model.FailureClass.PREREQUISITE, "blocked", "", "", 0.0, {},
        )
        with mock.patch.object(runner, "_run", return_value={
            "config": {}, "results": [result.to_dict()],
        }), redirect_stdout(io.StringIO()):
            self.assertEqual(runner.main([]), 1)


if __name__ == "__main__":
    unittest.main()
