"""Focused mode and target-preflight tests for AO live acceptance."""

from pathlib import Path
import os
import sys
import unittest
from unittest import mock


ACCEPTANCE_DIR = Path(__file__).parent / "ao-acceptance"
sys.path.insert(0, str(ACCEPTANCE_DIR))

import environment  # noqa: E402
import model  # noqa: E402
import runner  # noqa: E402


class FakeCommandRunner:
    """Controlled command boundary that records the runner's real requests."""

    def __init__(
        self,
        *,
        context="microshift",
        credentials=True,
        readiness=None,
        status_output="product-demos       enabled\n",
    ):
        self.context = context
        self.credentials = credentials
        self.readiness = {
            "aap_demo": True,
            "ao": True,
            "mcp": True,
            **(readiness or {}),
        }
        self.status_output = status_output
        self.calls: list[list[str]] = []

    def run(self, args, *, check=False, timeout=60):
        self.calls.append(args)
        if args == ["kubectl", "config", "current-context"]:
            return environment.CommandResult(0, f"{self.context}\n", "")
        if args == ["kubectl", "auth", "can-i", "get", "namespaces"]:
            return environment.CommandResult(0, "yes\n" if self.credentials else "no\n", "")
        if args == ["aap-demo", "status"]:
            return environment.CommandResult(0, self.status_output, "")
        if args[:2] == ["aap-demo", "deploy"] or args[:3] == ["aap-demo", "enable", "ao"]:
            return environment.CommandResult(0, "", "")
        if args[:3] == ["aap-demo", "enable", "product-demos"]:
            return environment.CommandResult(0, "", "")
        if "aap-controller-web" in args:
            ready = self.readiness["aap_demo"]
        elif "automation-orchestrator" in args:
            ready = self.readiness["ao"]
        elif "aap-mcp-server" in args:
            ready = self.readiness["mcp"]
        else:
            ready = True
        return environment.CommandResult(0 if ready else 1, "{}\n", "missing")


def config(mode, *, context="microshift"):
    return model.RunConfig(
        mode=mode,
        namespace="automation-orchestrator",
        artifact_dir=Path("artifacts/ao-acceptance"),
        context=context,
        scenario_file=Path("scenario.json"),
        timeout_seconds=30,
        dry_run=False,
    )


class RunnerModeTests(unittest.TestCase):
    def setUp(self):
        self.original_command_runner = runner.CommandRunner

    def tearDown(self):
        runner.CommandRunner = self.original_command_runner

    def test_validate_never_invokes_mutating_aap_demo_commands(self):
        commands = FakeCommandRunner()
        runner.CommandRunner = lambda: commands

        result = runner._run(config("validate"))

        self.assertFalse(result["mutated"])
        self.assertFalse(any(call[:2] == ["aap-demo", "deploy"] or call[:2] == ["aap-demo", "enable"] for call in commands.calls))

    def test_auto_reuses_a_healthy_target_without_mutation(self):
        commands = FakeCommandRunner()
        runner.CommandRunner = lambda: commands

        result = runner._run(config("auto"))

        self.assertFalse(result["mutated"])
        self.assertFalse(any(call[:2] == ["aap-demo", "deploy"] or call[:2] == ["aap-demo", "enable"] for call in commands.calls))

    def test_auto_missing_live_credentials_blocks_before_mutation(self):
        commands = FakeCommandRunner(readiness={
            "aap_demo": False,
            "ao": False,
            "mcp": False,
        })
        runner.CommandRunner = lambda: commands

        with mock.patch.dict(os.environ, {}, clear=True):
            result = runner._run(config("auto"))

        self.assertFalse(result["mutated"])
        live = next(item for item in result["results"] if item["check_id"] == "runner.live-dependencies")
        self.assertEqual(live["failure_class"], model.FailureClass.PREREQUISITE.value)
        self.assertFalse(any(
            call[:2] == ["aap-demo", "deploy"] or call[:2] == ["aap-demo", "enable"]
            for call in commands.calls
        ))

    def test_provision_invokes_required_commands_in_order(self):
        commands = FakeCommandRunner()
        runner.CommandRunner = lambda: commands

        with mock.patch.dict(os.environ, {
            "AAP_ACCEPTANCE_AAP_TOKEN": "aap-token",
            "AAP_ACCEPTANCE_AO_TOKEN": "ao-token",
            "AAP_ACCEPTANCE_MCP_TOKEN": "mcp-token",
        }, clear=True):
            result = runner._run(config("provision"))

        self.assertTrue(result["mutated"])
        self.assertEqual(
            [call for call in commands.calls if call[0] == "aap-demo" and call[1] != "status"],
            [
                ["aap-demo", "deploy"],
                ["aap-demo", "enable", "ao"],
                ["aap-demo", "enable", "product-demos"],
            ],
        )

    def test_context_mismatch_blocks_before_any_mutation(self):
        commands = FakeCommandRunner(context="other-context")
        runner.CommandRunner = lambda: commands

        result = runner._run(config("auto", context="microshift"))

        self.assertFalse(result["mutated"])
        self.assertEqual(result["results"][0]["status"], "BLOCKED")
        self.assertFalse(any(call[:2] == ["aap-demo", "deploy"] or call[:2] == ["aap-demo", "enable"] for call in commands.calls))

    def test_missing_context_blocks_before_cluster_or_mutating_commands(self):
        commands = FakeCommandRunner()
        runner.CommandRunner = lambda: commands

        result = runner._run(config("auto", context=None))

        self.assertFalse(result["mutated"])
        self.assertEqual(result["results"][0]["status"], "BLOCKED")
        self.assertEqual(commands.calls, [])


class TargetReadinessTests(unittest.TestCase):
    def test_product_demos_disabled_is_not_ready_when_another_addon_is_enabled(self):
        commands = FakeCommandRunner(
            status_output="\x1b[32mproduct-demos       disabled\x1b[0m\nportal              enabled\n"
        )
        inspector = environment.TargetInspector(commands, config("validate"))

        addons = inspector.required_addons_ready()

        self.assertTrue(addons["mcp"])
        self.assertFalse(addons["product_demos"])

    def test_validate_reports_an_isolated_missing_aap_prerequisite(self):
        commands = FakeCommandRunner(readiness={"aap_demo": False})
        results = environment.validate_target(config("validate"), environment.TargetInspector(commands, config("validate")))

        missing = {result.component for result in results if result.details.get("ready") is False}

        self.assertEqual(missing, {"aap_demo"})

    def test_validate_reports_an_isolated_missing_ao_prerequisite(self):
        commands = FakeCommandRunner(readiness={"ao": False})
        results = environment.validate_target(config("validate"), environment.TargetInspector(commands, config("validate")))

        missing = {result.component for result in results if result.details.get("ready") is False}

        self.assertEqual(missing, {"ao"})

    def test_validate_reports_an_isolated_missing_mcp_prerequisite(self):
        commands = FakeCommandRunner(readiness={"mcp": False})
        results = environment.validate_target(config("validate"), environment.TargetInspector(commands, config("validate")))

        missing = {result.component for result in results if result.details.get("ready") is False}

        self.assertEqual(missing, {"mcp"})


if __name__ == "__main__":
    unittest.main()
