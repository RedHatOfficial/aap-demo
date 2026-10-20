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
        "launch": True,
        "read_only": True,
        "success_marker_fields": ["stdout", "result"],
        "blocked_reason": None,
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

    def test_load_rejects_a_launchable_scenario_that_is_not_declared_read_only(self):
        payload = scenario().__dict__.copy()
        payload.update({"launch": True, "read_only": False, "success_marker_fields": ["stdout"]})

        with self.assertRaisesRegex(ValueError, "read_only"):
            scenarios.load(self.write_manifest({"scenarios": [payload]}))

    def test_load_requires_declared_execution_evidence_fields_for_markers(self):
        payload = scenario().__dict__.copy()
        payload["success_marker_fields"] = []

        with self.assertRaisesRegex(ValueError, "success_marker_fields"):
            scenarios.load(self.write_manifest({"scenarios": [payload]}))

    def test_load_rejects_static_metadata_as_success_marker_evidence(self):
        payload = scenario().__dict__.copy()
        payload["success_marker_fields"] = ["workflow_name"]

        with self.assertRaisesRegex(ValueError, "execution evidence"):
            scenarios.load(self.write_manifest({"scenarios": [payload]}))

    def test_default_scenarios_are_explicitly_blocked_and_never_invent_resources(self):
        manifest = ACCEPTANCE_DIR / "scenarios" / "critical-path.json"

        loaded = scenarios.load(manifest)

        self.assertEqual(len(loaded), 4)
        self.assertTrue(all(not item.launch and not item.read_only for item in loaded))
        self.assertTrue(all(item.blocked_reason for item in loaded))
        self.assertNotIn("Product Demos Read-Only Diagnostic", manifest.read_text(encoding="utf-8"))
        self.assertEqual(
            [item.workflow_name for item in loaded],
            [
                "Cert Demo 101 - Manual Reactive Renewal",
                "disk-demo-101",
                None,
                "ServiceNow Incident - AI Triage and Response",
            ],
        )


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
            "aap_jobs": [{"id": 42, "job_template_id": 7, "job_template_name": "Renew Certificate"}],
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

    def test_contract_only_unsafe_scenario_is_blocked_without_a_launch(self):
        ao = FakeAoClient([])

        checks = workflows.run(
            [scenario(launch=False, read_only=False, blocked_reason="no read-only representative")],
            managed_inventory(), ao, FakeAapClient(),
        )

        self.assertEqual(checks[0].status, CheckStatus.BLOCKED)
        self.assertEqual(checks[0].failure_class, FailureClass.PREREQUISITE)
        self.assertEqual(checks[0].summary, "no read-only representative")
        self.assertEqual(ao.launched, [])

    def test_configured_blocked_scenarios_report_reasons_before_graph_validation(self):
        loaded = scenarios.load(ACCEPTANCE_DIR / "scenarios" / "critical-path.json")
        template_names = [
            name
            for item in loaded
            for name in item.job_template_names
        ]
        inventory = ManagedResourceInventory(
            ao_workflows=[
                {
                    "id": f"workflow-{index}",
                    "name": item.workflow_name,
                    "aap_job_template_nodes": [
                        {"job_template_name": item.job_template_names[0]}
                    ],
                }
                for index, item in enumerate(loaded)
                if item.workflow_name
            ],
            job_templates=[
                {"id": index, "name": name}
                for index, name in enumerate(template_names, start=1)
            ],
        )
        ao = FakeAoClient([])

        checks = workflows.run(loaded, inventory, ao, FakeAapClient())

        self.assertEqual(len(checks), len(loaded))
        self.assertEqual(
            {
                check.details["scenario_id"]: (check.status, check.failure_class, check.summary)
                for check in checks
            },
            {
                item.scenario_id: (
                    CheckStatus.BLOCKED,
                    FailureClass.PREREQUISITE,
                    item.blocked_reason,
                )
                for item in loaded
            },
        )
        self.assertEqual(ao.launched, [])

    def test_unexpected_workflow_template_link_is_contract_drift_without_a_launch(self):
        inventory = managed_inventory()
        inventory.ao_workflows[0]["aap_job_template_nodes"].append({
            "job_template_id": 99, "job_template_name": "Unexpected job",
        })
        ao = FakeAoClient([])

        checks = workflows.run([scenario()], inventory, ao, FakeAapClient())

        self.assertEqual(checks[0].failure_class, FailureClass.CONTRACT_DRIFT)
        self.assertEqual(ao.launched, [])

    def test_ao_terminal_failure_includes_scenario_and_linked_resource_ids(self):
        ao = FakeAoClient([{"status": "failed", "aap_jobs": [{"id": 42, "job_template_id": 7, "job_template_name": "Renew Certificate"}]}])

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
        ao = FakeAoClient([{"status": "successful", "aap_jobs": [{"id": 42, "job_template_id": 7, "job_template_name": "Renew Certificate"}]}])
        aap = FakeAapClient([{"status": "failed"}])

        checks = workflows.run([scenario(success_markers=[])], managed_inventory(), ao, aap)

        failed = checks[0]
        self.assertEqual(failed.failure_class, FailureClass.EXECUTION)
        self.assertEqual(failed.details["scenario_id"], "aap-certificate-smoke")
        self.assertEqual(failed.details["job_ids"], [42])

    def test_completion_marker_is_found_in_aap_job_events(self):
        ao = FakeAoClient([{"status": "successful", "aap_jobs": [{"id": 42, "job_template_id": 7, "job_template_name": "Renew Certificate"}]}])
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

    def test_unapproved_linked_job_template_is_contract_drift_before_job_polling(self):
        ao = FakeAoClient([{
            "status": "successful",
            "aap_jobs": [{"id": 42, "job_template_id": 999, "job_template_name": "Unapproved job"}],
        }])
        aap = FakeAapClient([{"status": "successful", "stdout": "completed"}])

        checks = workflows.run([scenario()], managed_inventory(), ao, aap)

        failed = checks[0]
        self.assertEqual(failed.failure_class, FailureClass.CONTRACT_DRIFT)
        self.assertEqual(failed.details["job_ids"], [42])
        self.assertEqual(aap.polled, [])

    def test_absent_declared_link_is_contract_drift_before_job_polling(self):
        ao = FakeAoClient([{"status": "successful", "aap_jobs": []}])
        aap = FakeAapClient([{"status": "successful", "stdout": "completed"}])

        checks = workflows.run([scenario()], managed_inventory(), ao, aap)

        failed = checks[0]
        self.assertEqual(failed.failure_class, FailureClass.CONTRACT_DRIFT)
        self.assertEqual(failed.details["job_ids"], [])
        self.assertEqual(aap.polled, [])

    def test_all_runtime_linked_job_fields_are_enforced_before_aap_polling(self):
        inventory = ManagedResourceInventory(
            ao_workflows=[{
                "id": "workflow-1",
                "name": "Certificate Renewal",
                "aap_job_template_nodes": [],
            }],
            job_templates=[],
        )
        ao = FakeAoClient([{
            "status": "successful",
            "job_ids": [42],
            "aap_job_ids": [43],
            "jobs": [{"id": 44}],
            "aap_jobs": [{"id": 45}],
        }])
        aap = FakeAapClient()

        checks = workflows.run(
            [scenario(job_template_names=[], success_markers=[])], inventory, ao, aap,
        )

        failed = checks[0]
        self.assertEqual(failed.failure_class, FailureClass.CONTRACT_DRIFT)
        self.assertEqual(failed.details["job_ids"], [42, 43, 44, 45])
        self.assertEqual(aap.polled, [])

    def test_bare_runtime_job_ids_fail_against_the_declared_template_allowlist(self):
        ao = FakeAoClient([{
            "status": "successful",
            "job_ids": [42],
            "aap_job_ids": [43],
        }])
        aap = FakeAapClient()

        checks = workflows.run([scenario(success_markers=[])], managed_inventory(), ao, aap)

        failed = checks[0]
        self.assertEqual(failed.failure_class, FailureClass.CONTRACT_DRIFT)
        self.assertEqual(failed.details["job_ids"], [42, 43])
        self.assertEqual(aap.polled, [])

    def test_scenario_deadline_is_shared_by_ao_and_linked_aap_jobs(self):
        ao = FakeAoClient([{
            "status": "successful",
            "aap_jobs": [{"id": 42, "job_template_id": 7, "job_template_name": "Renew Certificate"}],
        }])
        aap = FakeAapClient([{"status": "successful", "stdout": "completed"}])
        with mock.patch.object(workflows.time, "monotonic", side_effect=[0.0, 0.0, 2.0]):
            checks = workflows.run([scenario(timeout_seconds=1)], managed_inventory(), ao, aap)

        self.assertEqual(checks[0].failure_class, FailureClass.TIMEOUT)
        self.assertEqual(aap.polled, [])

    def test_success_marker_does_not_match_workflow_metadata(self):
        self.assertFalse(workflows._contains_markers([{"workflow_name": "completed"}], ["completed"]))

    def test_nonterminal_workflow_times_out_with_linked_resource_ids(self):
        ao = FakeAoClient([{"status": "running", "aap_jobs": [{"id": 42, "job_template_id": 7, "job_template_name": "Renew Certificate"}]}])
        with mock.patch.object(workflows.time, "monotonic", side_effect=[0.0, 0.0, 2.0]):
            checks = workflows.run([scenario(timeout_seconds=1)], managed_inventory(), ao, FakeAapClient())

        failed = checks[0]
        self.assertEqual(failed.failure_class, FailureClass.TIMEOUT)
        self.assertEqual(failed.details["scenario_id"], "aap-certificate-smoke")
        self.assertEqual(failed.details["workflow_id"], "workflow-1")
        self.assertEqual(failed.details["job_template_ids"], [7])
        self.assertEqual(failed.details["job_ids"], [42])

    def test_missing_completion_marker_is_an_execution_failure(self):
        ao = FakeAoClient([{"status": "successful", "aap_jobs": [{"id": 42, "job_template_id": 7, "job_template_name": "Renew Certificate"}]}])
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
