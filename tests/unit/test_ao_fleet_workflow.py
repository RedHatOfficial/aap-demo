"""Fleet AO adaptation retains a real disk check and removes simulated inputs."""

import importlib.util
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "addons/ao/scripts/fleet-workflow.py"
SPEC = importlib.util.spec_from_file_location("fleet_workflow", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_disk_workflow_uses_fleet_template_without_simulated_disk_usage():
    source = {
        "name": "Disk demo",
        "triggers": [{"id": "start", "type": "manual_trigger"}],
        "nodes": [
            {
                "id": "check",
                "type": "aap_job_template",
                "parameters": {
                    "job_template_name": "Disk Utilization Check",
                    "extra_vars": {"test_disk_use_percent": 50},
                },
            },
            {"id": "notify", "type": "aap_job_template", "parameters": {}},
        ],
        "edges": [{"from": "start", "to": "check"}, {"from": "check", "to": "notify"}],
    }
    result = MODULE.adapt_disk_workflow(source, "aap-cred", "aap-integration")
    assert result["name"] == "Fleet | Disk Utilization Check"
    assert result["edges"] == [{"from": "start", "to": "check"}]
    assert len(result["nodes"]) == 1
    parameters = result["nodes"][0]["parameters"]
    assert parameters["job_template_name"] == "Fleet | Disk Utilization Check"
    assert parameters["credential_id"] == "aap-cred"
    assert parameters["integration_id"] == "aap-integration"
    assert "test_disk_use_percent" not in parameters.get("extra_vars", {})
    assert "extra_vars" not in parameters
    assert source["nodes"][0]["parameters"]["extra_vars"]["test_disk_use_percent"] == 50


def test_sync_creates_separately_owned_workflow():
    source = {
        "triggers": [{"id": "start", "type": "manual_trigger"}],
        "nodes": [
            {
                "id": "check",
                "type": "aap_job_template",
                "parameters": {"job_template_name": "Disk Utilization Check"},
            }
        ],
    }
    calls = []

    def request(method, path, payload=None):
        calls.append((method, path, payload))
        if path == "/projects?limit=100":
            return {"resources": [{"id": "project", "is_default": True}]}
        if path == "/workflows?limit=100":
            return {
                "resources": [{"id": "source", "labels": {"source_file": "disk-demo-101.json"}}]
            }
        if path == "/workflows/source":
            return {"version": {"workflow_definition": source}}
        if path == "/workflows" and method == "POST":
            return {"id": "created"}
        raise AssertionError(path)

    assert MODULE.sync_disk_workflow(request, "credential", "integration") == "created"
    created = calls[-1][2]
    assert created["labels"]["aap-demo-fleet"] == "true"
    assert created["labels"]["source_file"] == "fleet-disk-demo-101.json"
    assert created["project_id"] == "project"


def test_service_variant_runs_product_demo_template_after_real_disk_check():
    source = {
        "triggers": [{"id": "start", "type": "manual_trigger"}],
        "nodes": [
            {
                "id": "check",
                "type": "aap_job_template",
                "parameters": {"job_template_name": "Disk Utilization Check"},
            }
        ],
    }
    result = MODULE.adapt_disk_workflow(source, "credential", "integration", include_service=True)
    assert result["name"] == "Fleet | Disk and Service Demo"
    assert result["edges"] == [
        {"from": "start", "to": "check"},
        {"from": "check", "to": "fleet_service"},
    ]
    service = result["nodes"][1]
    assert service["parameters"]["job_template_name"] == "Fleet | Start Demo Service"
    assert service["parameters"]["organization_name"] == "Ansible Product Demos (APD)"


def test_service_variant_is_synchronized_under_its_own_source_label():
    source = {
        "triggers": [{"id": "start", "type": "manual_trigger"}],
        "nodes": [
            {
                "id": "check",
                "type": "aap_job_template",
                "parameters": {"job_template_name": "Disk Utilization Check"},
            }
        ],
    }
    calls = []

    def request(method, path, payload=None):
        calls.append((method, path, payload))
        if path == "/projects?limit=100":
            return {"resources": [{"id": "project", "is_default": True}]}
        if path == "/workflows?limit=100":
            return {
                "resources": [{"id": "source", "labels": {"source_file": "disk-demo-101.json"}}]
            }
        if path == "/workflows/source":
            return {"version": {"workflow_definition": source}}
        return {"id": "created"}

    MODULE.sync_disk_workflow(request, "credential", "integration", include_service=True)
    assert calls[-1][2]["labels"]["source_file"] == "fleet-disk-service-demo.json"


def test_readiness_report_names_each_unadapted_workflow_and_its_dependencies():
    report = MODULE.unavailable_workflow_reasons()
    assert len(report) == 9
    assert "ServiceNow" in report["snow-disk-autoremediate.json"]
    assert "AWS" in report["multi-os-cloud-patching.json"]
    assert "Mattermost" in report["disk-demo-tier-switch.json"]


def test_stale_workflow_report_identifies_existing_unavailable_fleet_copies():
    def request(method, path, payload=None):
        return {
            "resources": [
                {"name": "Fleet | disk-demo-101", "labels": {"aap-demo-fleet": "true"}},
                {"name": "Fleet | Disk and Service Demo", "labels": {"aap-demo-fleet": "true"}},
                {"name": "unrelated", "labels": {}},
            ]
        }

    assert MODULE.stale_service_workflows(request) == [
        "Fleet | Disk and Service Demo",
        "Fleet | disk-demo-101",
    ]
    assert MODULE.stale_service_workflows(request, disk_ready=True) == [
        "Fleet | Disk and Service Demo"
    ]


def test_disk_demo_101_preserves_switch_and_marks_unsupported_expansion():
    source = {
        "triggers": [{"id": "start", "type": "manual_trigger"}],
        "nodes": [
            {
                "id": "check",
                "type": "aap_job_template",
                "parameters": {
                    "job_template_name": "Disk Utilization Check",
                    "extra_vars": {"test_disk_use_percent": 50},
                },
            },
            {"id": "switch", "type": "switch", "parameters": {"cases": [{"port": "case_0"}]}},
            {
                "id": "ok",
                "type": "aap_job_template",
                "parameters": {"job_template_name": "Linux - Remediate - Continue"},
            },
            {
                "id": "warn",
                "type": "aap_job_template",
                "parameters": {"job_template_name": "Linux - Remediate - Disk Cleanup"},
            },
            {
                "id": "critical",
                "type": "aap_job_template",
                "parameters": {"job_template_name": "Linux - Remediate - Disk Expand"},
            },
            {
                "id": "fallback",
                "type": "aap_job_template",
                "parameters": {"job_template_name": "Disk Utilization - Fallback"},
            },
            {
                "id": "notify",
                "type": "aap_job_template",
                "parameters": {"job_template_name": "Notify Chatroom"},
            },
        ],
        "edges": [
            {"from": "start", "to": "check"},
            {"from": "check", "to": "switch"},
            *[
                {"from": "switch", "to": name, "from_port": port}
                for name, port in [
                    ("ok", "case_0"),
                    ("warn", "case_1"),
                    ("critical", "case_2"),
                    ("fallback", "default"),
                ]
            ],
            {"from": "ok", "to": "notify"},
        ],
    }
    result = MODULE.adapt_disk_demo_101(source, "cred", "integration")
    nodes = {node["id"]: node for node in result["nodes"]}
    assert result["name"] == "Fleet | disk-demo-101"
    assert nodes["switch"]["parameters"] == source["nodes"][1]["parameters"]
    assert nodes["warn"]["parameters"]["job_template_name"] == "Fleet | Disk Cleanup Preview"
    assert nodes["warn"]["name"] == "Preview disk cleanup (estimates only)"
    assert nodes["ok"]["parameters"]["job_template_name"] == "Fleet | Linux - Remediate - Continue"
    assert nodes["critical"]["type"] == "aap_job_template"
    assert (
        nodes["critical"]["parameters"]["job_template_name"]
        == "Fleet | Manual Intervention Required"
    )
    assert nodes["critical"]["parameters"]["organization_name"] == "Ansible Product Demos (APD)"
    assert (
        nodes["fallback"]["parameters"]["job_template_name"]
        == "Fleet | Manual Intervention Required"
    )
    assert "notify" not in nodes
    assert len(result["edges"]) == 6
    assert "test_disk_use_percent" not in nodes["check"]["parameters"].get("extra_vars", {})
    assert source["nodes"][0]["parameters"]["extra_vars"]["test_disk_use_percent"] == 50


def test_disk_demo_101_rejects_missing_required_route():
    with pytest.raises(ValueError, match="missing"):
        MODULE.adapt_disk_demo_101(
            {"triggers": [], "nodes": [], "edges": []}, "cred", "integration"
        )


def test_disk_demo_101_rejects_unexpected_extra_route():
    source = {
        "triggers": [{"id": "start", "type": "manual_trigger"}],
        "nodes": [
            {
                "id": "check",
                "type": "aap_job_template",
                "parameters": {"job_template_name": "Disk Utilization Check"},
            },
            {"id": "switch", "type": "switch", "parameters": {}},
            *[
                {
                    "id": name,
                    "type": "aap_job_template",
                    "parameters": {"job_template_name": template},
                }
                for name, template in [
                    ("ok", "Linux - Remediate - Continue"),
                    ("warn", "Linux - Remediate - Disk Cleanup"),
                    ("critical", "Linux - Remediate - Disk Expand"),
                    ("fallback", "Disk Utilization - Fallback"),
                ]
            ],
        ],
        "edges": [
            {"from": "start", "to": "check"},
            {"from": "check", "to": "switch"},
            *[
                {"from": "switch", "to": "ok", "from_port": port}
                for port in ["case_0", "case_1", "case_2", "default"]
            ],
        ],
    }
    with pytest.raises(ValueError, match="routing"):
        MODULE.adapt_disk_demo_101(source, "cred", "integration")


def test_sync_disk_demo_101_creates_distinct_owned_copy(monkeypatch):
    calls = []

    def request(method, path, payload=None):
        calls.append((method, path, payload))
        if path == "/projects?limit=100":
            return {"resources": [{"id": "project", "is_default": True}]}
        if path == "/workflows?limit=100":
            return {
                "resources": [{"id": "source", "labels": {"source_file": "disk-demo-101.json"}}]
            }
        if path == "/workflows/source":
            return {"version": {"workflow_definition": {"source": True}}}
        return {"id": "created"}

    monkeypatch.setattr(
        MODULE,
        "adapt_disk_demo_101",
        lambda source, cred, integration: {
            "name": "Fleet | disk-demo-101",
            "description": "Fleet disk routing",
        },
    )
    MODULE.sync_disk_workflow(request, "cred", "integration", demo_101=True)
    assert calls[-1][2]["labels"]["source_file"] == "fleet-disk-demo-101-routed.json"


def test_ao_requests_verify_certificates_and_hostname(monkeypatch):
    import ssl
    import sys

    monkeypatch.setenv("AO_ACCESS_TOKEN", "test-token")
    monkeypatch.setattr(
        sys,
        "argv",
        [
            str(SCRIPT),
            "--route",
            "ao.example.test",
            "--credential-id",
            "c",
            "--integration-id",
            "i",
        ],
    )

    def check_request(request, credential_id, integration_id, **kwargs):
        request("GET", "/projects")
        return "id"

    def open_request(req, *, context, timeout):
        assert context.verify_mode == ssl.CERT_REQUIRED
        assert context.check_hostname
        raise RuntimeError("verified TLS context")

    monkeypatch.setattr(MODULE, "sync_disk_workflow", check_request)
    monkeypatch.setattr(MODULE.urllib.request, "urlopen", open_request)
    with pytest.raises(RuntimeError, match="verified TLS context"):
        MODULE.main()
