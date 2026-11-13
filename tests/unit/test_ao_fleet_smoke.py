"""AO Fleet smoke checks require both a successful execution and a real state change."""

import importlib.util
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/ao-fleet-smoke.py"
SPEC = importlib.util.spec_from_file_location("ao_fleet_smoke", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_smoke_launches_workflow_and_verifies_service_transition():
    requests = []
    states = iter(["inactive", "active"])

    def request(method, path, body=None):
        requests.append((method, path, body))
        if path.endswith("/activities"):
            return {
                "resources": [
                    {
                        "input_data": {"job_template_name": "Fleet | Start Demo Service"},
                        "output_data": {"job_status": "successful"},
                    }
                ]
            }
        return {"id": "execution-1"} if method == "POST" else {"status": "completed"}

    MODULE.run_smoke(request, lambda: next(states), "workflow-1", "trigger-1", "active")
    assert requests == [
        ("POST", "/executions", {"workflow_id": "workflow-1", "trigger_node_id": "trigger-1"}),
        ("GET", "/executions/execution-1", None),
        ("GET", "/executions/execution-1/activities", None),
    ]


def test_smoke_rejects_success_when_service_did_not_change():
    def request(method, path, body=None):
        if path.endswith("/activities"):
            return {
                "resources": [
                    {
                        "input_data": {"job_template_name": "Fleet | Start Demo Service"},
                        "output_data": {"job_status": "successful"},
                    }
                ]
            }
        return {"id": "execution-1"} if method == "POST" else {"status": "completed"}

    with pytest.raises(RuntimeError, match="did not change"):
        states = iter(["inactive", "inactive"])
        MODULE.run_smoke(request, lambda: next(states), "workflow-1", "trigger-1", "active")


def test_smoke_does_not_launch_when_service_already_has_expected_state():
    def request(method, path, body=None):
        raise AssertionError("workflow should not be launched")

    with pytest.raises(RuntimeError, match="already"):
        MODULE.run_smoke(request, lambda: "active", "workflow-1", "trigger-1", "active")


def test_smoke_rejects_workflow_completed_with_errors():
    def request(method, path, body=None):
        return {"id": "execution-1"} if method == "POST" else {"status": "completed_with_errors"}

    with pytest.raises(RuntimeError, match="completed_with_errors"):
        MODULE.run_smoke(request, lambda: "inactive", "workflow-1", "trigger-1", "active")


def test_smoke_requires_service_job_to_have_run_successfully():
    def request(method, path, body=None):
        if path.endswith("/activities"):
            return {"resources": []}
        return {"id": "execution-1"} if method == "POST" else {"status": "completed"}

    with pytest.raises(RuntimeError, match="service job"):
        MODULE.run_smoke(request, lambda: "inactive", "workflow-1", "trigger-1", "active")
