"""Contract tests for AO critical-path scenario execution."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ACCEPTANCE_DIR = Path(__file__).parent / "ao-acceptance"
sys.path.insert(0, str(ACCEPTANCE_DIR))

import scenarios  # noqa: E402
from checks import workflows  # noqa: E402
from inventory import ManagedResourceInventory  # noqa: E402
from model import CheckResult, CheckStatus, FailureClass, RunConfig  # noqa: E402
import runner  # noqa: E402


def scenario(**overrides):
    values = {
        "scenario_id": "aap-certificate-smoke",
        "component": "workflow:certificate",
        "workflow_name": "Certificate Renewal",
        "job_template_names": ["Renew Certificate"],
        "timeout_seconds": 30,
        "poll_seconds": 1,
        "expected_workflow_states": ["successful"],
        "expected_job_states": ["successful"],
        "success_markers": ["completed"],
    }
    values.update(overrides)
    return scenarios.Scenario(**values)


def managed_inventory():
    return ManagedResourceInventory(
        ao_workflows=[{
            "id": "workflow-1",
            "name": "Certificate Renewal",
            "aap_job_template_nodes": [{"job_template_id": 7, "job_template_name": "Renew Certificate"}],
        }],
        job_templates=[{"id": 7, "name": "Renew Certificate"}],
    )


class FakeAoClient:
    def __init__(self, statuses):
        self.statuses = list(statuses)
        self.launched = []
        self.polled = []

    def launch_workflow(self, workflow_id):
        self.launched.append(workflow_id)
        return "execution-1"

    def workflow_status(self, execution_id):
        self.polled.append(execution_id)
        return self.statuses.pop(0)


class FakeAapClient:
    def __init__(self, statuses=(), events=()):
        self.statuses = list(statuses)
        self.events = list(events)
        self.polled = []
        self.event_paths = []

    def job_status(self, job_id):
        self.polled.append(job_id)
        return self.statuses.pop(0)

    def list_all(self, path):
        self.event_paths.append(path)
        return self.events


class ScenarioManifestTests(unittest.TestCase):
    def write_manifest(self, payload):
        handle = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False)
        self.addCleanup(lambda: Path(handle.name).unlink(missing_ok=True))
        json.dump(payload, handle)
        handle.close()
        return Path(handle.name)

    def test_load_rejects_a_manifest_missing_a_required_field(self):
        payload = scenario().__dict__.copy()
        payload.pop("component")

        with self.assertRaisesRegex(ValueError, "component"):
            scenarios.load(self.write_manifest({"scenarios": [payload]}))

    def test_load_rejects_duplicate_scenario_ids_before_execution(self):
        payload = scenario().__dict__.copy()

        with self.assertRaisesRegex(ValueError, "duplicate"):
            scenarios.load(self.write_manifest({"scenarios": [payload, payload]}))


class WorkflowExecutionTests(unittest.TestCase):
    def test_unknown_workflow_is_contract_drift_without_a_launch(self):
        ao = FakeAoClient([])
        aap = FakeAapClient()

        checks = workflows.run([scenario(workflow_name="Missing workflow")], managed_inventory(), ao, aap)

        failed = checks[0]
        self.assertEqual(failed.status, CheckStatus.FAIL)
        self.assertEqual(failed.failure_class, FailureClass.CONTRACT_DRIFT)
        self.assertEqual(failed.details["scenario_id"], "aap-certificate-smoke")
        self.assertEqual(failed.details["workflow_id"], None)
        self.assertEqual(failed.details["job_template_ids"], [7])
        self.assertEqual(failed.details["job_ids"], [])
        self.assertEqual(ao.launched, [])

    def test_successful_ao_workflow_and_linked_aap_job_pass_once(self):
        ao = FakeAoClient([{
            "status": "successful",
            "message": "workflow completed",
            "aap_jobs": [{"id": 42}],
        }])
        aap = FakeAapClient([{"status": "successful", "stdout": "completed certificate renewal"}])

        checks = workflows.run([scenario()], managed_inventory(), ao, aap)

        passed = checks[0]
        self.assertEqual(passed.status, CheckStatus.PASS)
        self.assertEqual(passed.details["scenario_id"], "aap-certificate-smoke")
        self.assertEqual(passed.details["workflow_id"], "workflow-1")
        self.assertEqual(passed.details["job_template_ids"], [7])
        self.assertEqual(passed.details["job_ids"], [42])
        self.assertEqual(ao.launched, ["workflow-1"])
        self.assertEqual(aap.polled, [42])

    def test_ao_terminal_failure_includes_scenario_and_linked_resource_ids(self):
        ao = FakeAoClient([{"status": "failed", "aap_jobs": [{"id": 42}]}])

        checks = workflows.run([scenario()], managed_inventory(), ao, FakeAapClient())

        failed = checks[0]
        self.assertEqual(failed.failure_class, FailureClass.EXECUTION)
        self.assertEqual(failed.details["scenario_id"], "aap-certificate-smoke")
        self.assertEqual(failed.details["workflow_id"], "workflow-1")
        self.assertEqual(failed.details["job_template_ids"], [7])
        self.assertEqual(failed.details["job_ids"], [42])


class RunnerScenarioTests(unittest.TestCase):
    def test_failed_managed_validation_prevents_workflow_and_ee_launches(self):
        failed_validation = CheckResult(
            "security.tokens", "token", CheckStatus.FAIL, FailureClass.PREREQUISITE,
            "tokens unavailable", "", "", 0.0, {},
        )
        with (
            mock.patch.object(runner, "build_inventory", return_value=managed_inventory()),
            mock.patch.object(runner.readiness, "run", return_value=[]),
            mock.patch.object(runner.wiring, "run", return_value=[]),
            mock.patch.object(runner.security, "run", return_value=[failed_validation]),
            mock.patch.object(runner.workflows, "run") as workflow_run,
            mock.patch.object(runner.execution_environments, "run") as ee_run,
        ):
            results = runner.run_managed_checks("aap", "ao", "probes", scenarios=[scenario()])

        self.assertEqual(results, [failed_validation])
        workflow_run.assert_not_called()
        ee_run.assert_not_called()

    def test_invalid_manifest_is_contract_drift_before_any_live_launch(self):
        config = RunConfig(
            mode="validate",
            namespace="automation-orchestrator",
            artifact_dir=Path("artifacts/ao-acceptance"),
            context="test",
            scenario_file=Path("missing-scenarios.json"),
            timeout_seconds=30,
            dry_run=False,
        )
        preflight = CheckResult(
            "target.context", "target", CheckStatus.PASS, None,
            "ready", "", "", 0.0, {"ready": True},
        )
        with (
            mock.patch.object(runner, "CommandRunner", return_value=type("RunnerStub", (), {})()),
            mock.patch.object(runner, "TargetInspector"),
            mock.patch.object(runner, "validate_target", return_value=[preflight]),
            mock.patch.object(runner, "create_live_dependencies", return_value=("aap", "ao", "probes")),
            mock.patch.object(runner, "run_managed_checks") as managed_checks,
        ):
            result = runner._run(config)

        failure = next(item for item in result["results"] if item["check_id"] == "workflow.manifest")
        self.assertEqual(failure["failure_class"], FailureClass.CONTRACT_DRIFT.value)
        self.assertEqual(failure["details"]["scenario_id"], None)
        self.assertEqual(failure["details"]["job_ids"], [])
        managed_checks.assert_not_called()

    def test_linked_aap_job_failure_is_an_execution_failure(self):
        ao = FakeAoClient([{"status": "successful", "aap_jobs": [{"id": 42}]}])
        aap = FakeAapClient([{"status": "failed"}])

        checks = workflows.run([scenario(success_markers=[])], managed_inventory(), ao, aap)

        failed = checks[0]
        self.assertEqual(failed.failure_class, FailureClass.EXECUTION)
        self.assertEqual(failed.details["scenario_id"], "aap-certificate-smoke")
        self.assertEqual(failed.details["job_ids"], [42])

    def test_completion_marker_is_found_in_aap_job_events(self):
        ao = FakeAoClient([{"status": "successful", "aap_jobs": [{"id": 42}]}])
        aap = FakeAapClient(
            [{"status": "successful"}],
            [{"event": "runner_on_ok", "stdout": "completion marker from job events"}],
        )

        checks = workflows.run(
            [scenario(success_markers=["completion marker from job events"])],
            managed_inventory(), ao, aap,
        )

        self.assertEqual(checks[0].status, CheckStatus.PASS)
        self.assertEqual(aap.event_paths, ["/api/v2/jobs/42/job_events/"])

    def test_nonterminal_workflow_times_out_with_linked_resource_ids(self):
        ao = FakeAoClient([{"status": "running", "aap_jobs": [{"id": 42}]}])
        with mock.patch.object(workflows.time, "monotonic", side_effect=[0.0, 2.0]):
            checks = workflows.run([scenario(timeout_seconds=1)], managed_inventory(), ao, FakeAapClient())

        failed = checks[0]
        self.assertEqual(failed.failure_class, FailureClass.TIMEOUT)
        self.assertEqual(failed.details["scenario_id"], "aap-certificate-smoke")
        self.assertEqual(failed.details["workflow_id"], "workflow-1")
        self.assertEqual(failed.details["job_template_ids"], [7])
        self.assertEqual(failed.details["job_ids"], [42])

    def test_missing_completion_marker_is_an_execution_failure(self):
        ao = FakeAoClient([{"status": "successful", "aap_jobs": [{"id": 42}]}])
        aap = FakeAapClient([{"status": "successful", "stdout": "certificate renewed"}])

        checks = workflows.run([scenario()], managed_inventory(), ao, aap)

        failed = checks[0]
        self.assertEqual(failed.failure_class, FailureClass.EXECUTION)
        self.assertEqual(failed.details["scenario_id"], "aap-certificate-smoke")
        self.assertEqual(failed.details["workflow_id"], "workflow-1")
        self.assertEqual(failed.details["job_template_ids"], [7])
        self.assertEqual(failed.details["job_ids"], [42])


if __name__ == "__main__":
    unittest.main()
