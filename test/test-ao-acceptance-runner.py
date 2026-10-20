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
