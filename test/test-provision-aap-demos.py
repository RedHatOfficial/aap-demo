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
    )

    extra_vars = MODULE.control_job_extra_vars(args)

    assert extra_vars["ao_agent_credential_id"] == "llm-credential"
    assert extra_vars["ao_agent_integration_id"] == "llm-integration"
    assert extra_vars["ao_agent_model_id"] == "gpt-6-luna-model-id"


if __name__ == "__main__":
    test_reuses_successfully_synced_project()
    test_missing_license_message_includes_aap_address()
    test_control_job_extra_vars_include_agent_binding()
    print("AAP provisioning tests passed")
