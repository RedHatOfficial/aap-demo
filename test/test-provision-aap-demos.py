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
            return {"status": "successful", "scm_revision": "a" * 40}
        if path == "/projects/42/playbooks/":
            return {"results": [{"name": "already-published.yml"}]}
        raise AssertionError(f"unexpected API call: {path} {method}")

    api.request = request
    api.wait_for_project_sync(42, "a" * 40)

    assert calls == [
        ("/projects/42/", "GET"),
        ("/projects/42/playbooks/", "GET"),
    ]


def test_resyncs_a_successful_project_when_its_revision_is_stale():
    api = object.__new__(MODULE.AAP)
    calls = []
    project_reads = iter([
        {"status": "successful", "scm_revision": "b" * 40},
        {"status": "successful", "scm_revision": "a" * 40},
    ])

    def request(path, method="GET", payload=None):
        del payload
        calls.append((path, method))
        if path == "/projects/42/":
            return next(project_reads)
        if path == "/projects/42/update/" and method == "POST":
            return {"id": 99}
        if path == "/projects/42/playbooks/":
            return {"results": [{"name": "pinned.yml"}]}
        raise AssertionError(f"unexpected API call: {path} {method}")

    api.request = request
    api.wait_for_project_sync(42, "a" * 40)

    assert ("/projects/42/update/", "POST") in calls


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
        ao_acceptance_template_id="101",
        product_demos_acceptance_template_id="202",
    )

    extra_vars = MODULE.control_job_extra_vars(args)

    assert extra_vars["ao_agent_credential_id"] == "llm-credential"
    assert extra_vars["ao_agent_integration_id"] == "llm-integration"
    assert extra_vars["ao_agent_model_id"] == "gpt-6-luna-model-id"
    assert extra_vars["ao_mcp_credential_id"] == "mcp-credential"
    assert extra_vars["ao_mcp_integration_id"] == "mcp-integration"
    assert extra_vars["ao_acceptance_template_id"] == "101"
    assert extra_vars["product_demos_acceptance_template_id"] == "202"


def test_project_contracts_use_immutable_refs_and_safe_representative():
    upstream = MODULE.upstream_project_payload(7, "abcc1a1482a")
    control = MODULE.control_project_payload(
        7, "https://github.com/RedHatOfficial/aap-demo.git", "a" * 40
    )
    representative = MODULE.acceptance_template_payload(7, 8, 9)

    assert upstream["scm_url"] == MODULE.PROJECT_URL
    assert upstream["scm_branch"] == "abcc1a1482a"
    assert upstream["scm_update_on_launch"] is False
    assert control["scm_branch"] == "a" * 40
    assert control["scm_update_on_launch"] is False
    assert representative == {
        "name": MODULE.ACCEPTANCE_TEMPLATE_NAME,
        "description": "AAP-Demo acceptance read-only AO-backed diagnostic",
        "job_type": "run",
        "organization": 7,
        "project": 8,
        "playbook": MODULE.ACCEPTANCE_PLAYBOOK,
        "execution_environment": 9,
        "ask_variables_on_launch": True,
    }


if __name__ == "__main__":
    test_reuses_successfully_synced_project()
    test_resyncs_a_successful_project_when_its_revision_is_stale()
    test_missing_license_message_includes_aap_address()
    test_control_job_extra_vars_include_agent_binding()
    test_project_contracts_use_immutable_refs_and_safe_representative()
    print("AAP provisioning tests passed")
