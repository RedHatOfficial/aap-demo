"""Tests for the AAP demo provisioning fast paths."""

from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
from types import SimpleNamespace


SCRIPT = Path(__file__).parents[1] / "addons/ao/scripts/provision-aap-demos.py"
SPEC = importlib.util.spec_from_file_location("provision_aap_demos", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_reuses_successfully_synced_project():
    api = object.__new__(MODULE.AAP)
    calls = []

    def request(path, method="GET", payload=None):
        calls.append((path, method))
        if path == "/projects/42/":
            return {"status": "successful"}
        if path == "/projects/42/playbooks/":
            return {"results": [{"name": "already-published.yml"}]}
        raise AssertionError(f"unexpected API call: {path} {method}")

    api.request = request
    api.wait_for_project_sync(42)

    assert calls == [
        ("/projects/42/", "GET"),
        ("/projects/42/playbooks/", "GET"),
    ]


def test_missing_license_message_includes_aap_address():
    output = io.StringIO()
    with redirect_stdout(output):
        MODULE.report_missing_license("aap.example.test")

    assert output.getvalue().splitlines() == [
        "WARNING: AAP does not have a registered subscription.",
        "  Please log into AAP at https://aap.example.test and register a subscription.",
    ]
    assert MODULE.EXIT_LICENSE_REQUIRED == 2


def test_control_job_extra_vars_include_agent_binding():
    args = SimpleNamespace(
        ao_api_url="https://ao.example.test/api/v1",
        ao_api_host="ao.example.test",
        ao_token="ao-token",
        ao_demo_ref="demo-ref",
        ao_credential_id="aap-credential",
        ao_integration_id="aap-integration",
        ao_agent_credential_id="llm-credential",
        ao_agent_integration_id="llm-integration",
        ao_agent_model_id="gpt-6-luna-model-id",
        ao_mcp_credential_id="mcp-credential",
        ao_mcp_integration_id="mcp-integration",
    )

    extra_vars = MODULE.control_job_extra_vars(args)

    assert extra_vars["ao_agent_credential_id"] == "llm-credential"
    assert extra_vars["ao_agent_integration_id"] == "llm-integration"
    assert extra_vars["ao_agent_model_id"] == "gpt-6-luna-model-id"
    assert extra_vars["ao_mcp_credential_id"] == "mcp-credential"
    assert extra_vars["ao_mcp_integration_id"] == "mcp-integration"

def test_only_remote_host_templates_target_fleet():
    assert "Disk Utilization Check" in MODULE.FLEET_TARGET_TEMPLATES
    assert "Renew Certificate" in MODULE.FLEET_TARGET_TEMPLATES
    assert "SNOW - Auto Remediation" in MODULE.FLEET_TARGET_TEMPLATES
    assert "Incidents | High CPU - Process Cleanup" in MODULE.FLEET_TARGET_TEMPLATES
    assert "Notify Mattermost" not in MODULE.FLEET_TARGET_TEMPLATES
    assert "Notify Chatroom" not in MODULE.FLEET_TARGET_TEMPLATES
    assert "CVE - Fetch and Commit" not in MODULE.FLEET_TARGET_TEMPLATES
    assert "Incidents | Update Ticket" not in MODULE.FLEET_TARGET_TEMPLATES

def test_machine_credential_binding_is_idempotent_and_replaces_other_machine_credentials():
    class API:
        def __init__(self):
            self.posts = []

        def request(self, path, method="GET", payload=None):
            if method == "GET":
                return {
                    "results": [
                        {
                            "id": 4,
                            "summary_fields": {"credential_type": {"kind": "ssh"}},
                        },
                        {
                            "id": 9,
                            "summary_fields": {"credential_type": {"kind": "vault"}},
                        },
                    ]
                }
            self.posts.append((path, payload))
            return {}

    api = API()
    MODULE.ensure_template_machine_credential(api, 42, {"id": 3})
    assert api.posts == [
        ("/job_templates/42/credentials/", {"id": 4, "disassociate": True}),
        ("/job_templates/42/credentials/", {"id": 3}),
    ]

    api.posts.clear()
    api.request = lambda path, method="GET", payload=None: (
        {"results": [{"id": 3, "summary_fields": {"credential_type": {"kind": "ssh"}}}]}
        if method == "GET"
        else api.posts.append((path, payload)) or {}
    )
    MODULE.ensure_template_machine_credential(api, 42, {"id": 3})
    assert api.posts == []


if __name__ == "__main__":
    test_reuses_successfully_synced_project()
    test_missing_license_message_includes_aap_address()
    test_control_job_extra_vars_include_agent_binding()
    test_only_remote_host_templates_target_fleet()
    test_machine_credential_binding_is_idempotent_and_replaces_other_machine_credentials()
    print("AAP provisioning tests passed")
