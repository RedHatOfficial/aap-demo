"""Focused mode and target-preflight tests for AO live acceptance."""

from pathlib import Path
import sys
import unittest


ACCEPTANCE_DIR = Path(__file__).parent / "ao-acceptance"
sys.path.insert(0, str(ACCEPTANCE_DIR))

import environment  # noqa: E402
import model  # noqa: E402
import runner  # noqa: E402


class FakeCommandRunner:
    """Controlled command boundary that records the runner's real requests."""

    def __init__(self, *, context="microshift", credentials=True, ready=True):
        self.context = context
        self.credentials = credentials
        self.ready = ready
        self.calls: list[list[str]] = []

    def run(self, args, *, check=False, timeout=60):
        self.calls.append(args)
        if args == ["kubectl", "config", "current-context"]:
            return environment.CommandResult(0, f"{self.context}\n", "")
        if args == ["kubectl", "auth", "can-i", "get", "namespaces"]:
            return environment.CommandResult(0, "yes\n" if self.credentials else "no\n", "")
        if args == ["aap-demo", "status"]:
            return environment.CommandResult(0, "product-demos       enabled\n", "")
        if args[:2] == ["aap-demo", "deploy"] or args[:3] == ["aap-demo", "enable", "ao"]:
            return environment.CommandResult(0, "", "")
        if args[:3] == ["aap-demo", "enable", "product-demos"]:
            return environment.CommandResult(0, "", "")
        return environment.CommandResult(0 if self.ready else 1, "{}\n", "missing")


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
        commands = FakeCommandRunner(ready=True)
        runner.CommandRunner = lambda: commands

        result = runner._run(config("validate"))

        self.assertFalse(result["mutated"])
        self.assertFalse(any(call[:2] == ["aap-demo", "deploy"] or call[:2] == ["aap-demo", "enable"] for call in commands.calls))

    def test_auto_reuses_a_healthy_target_without_mutation(self):
        commands = FakeCommandRunner(ready=True)
        runner.CommandRunner = lambda: commands

        result = runner._run(config("auto"))

        self.assertFalse(result["mutated"])
        self.assertFalse(any(call[:2] == ["aap-demo", "deploy"] or call[:2] == ["aap-demo", "enable"] for call in commands.calls))

    def test_provision_invokes_required_commands_in_order(self):
        commands = FakeCommandRunner(ready=True)
        runner.CommandRunner = lambda: commands

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
        commands = FakeCommandRunner(context="other-context", ready=False)
        runner.CommandRunner = lambda: commands

        result = runner._run(config("auto", context="microshift"))

        self.assertFalse(result["mutated"])
        self.assertEqual(result["results"][0]["status"], "BLOCKED")
        self.assertFalse(any(call[:2] == ["aap-demo", "deploy"] or call[:2] == ["aap-demo", "enable"] for call in commands.calls))


if __name__ == "__main__":
    unittest.main()
