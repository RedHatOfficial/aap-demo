"""Tests for the AAP demo provisioning fast paths."""

import importlib.util
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace

import pytest

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
        ao_demo_repository="https://example.test/fork.git/",
    )

    extra_vars = MODULE.control_job_extra_vars(args)

    assert extra_vars["ao_agent_credential_id"] == "llm-credential"
    assert extra_vars["ao_agent_integration_id"] == "llm-integration"
    assert extra_vars["ao_agent_model_id"] == "gpt-6-luna-model-id"
    assert extra_vars["ao_demo_repository"] == "https://example.test/fork"


def test_shared_demo_project_uses_configured_source_repository():
    payload = MODULE.demo_project_payload(1, "https://example.test/demo-fork.git", "demo-ref")
    assert payload["scm_url"] == "https://example.test/demo-fork.git"
    assert payload["organization"] == 1
    assert payload["scm_branch"] == "demo-ref"


def test_fleet_binding_requires_matching_host_inventory_and_machine_credential():
    class API:
        def request(self, path, method="GET", payload=None):
            if path.startswith("/inventories/"):
                return {"results": [{"id": 11, "name": "aap-demo-fleet"}]}
            if path.startswith("/credentials/"):
                return {"results": [{"id": 22, "name": "aap-demo-fleet-ssh", "kind": "ssh"}]}
            if path.startswith("/hosts/"):
                return {"results": [{"id": 33, "name": "fleet-ubi9"}]}
            raise AssertionError(path)

    assert MODULE.resolve_fleet_binding(API(), 1, "fleet-ubi9") == (11, 22)


def test_fleet_binding_rejects_host_missing_from_fleet_inventory():
    class API:
        def request(self, path, method="GET", payload=None):
            if path.startswith("/inventories/"):
                return {"results": [{"id": 11, "name": "aap-demo-fleet"}]}
            if path.startswith("/credentials/"):
                return {"results": [{"id": 22, "name": "aap-demo-fleet-ssh", "kind": "ssh"}]}
            return {"results": []}

    with pytest.raises(RuntimeError, match="fleet-ubi9.*inventory"):
        MODULE.resolve_fleet_binding(API(), 1, "fleet-ubi9")


def test_fleet_binding_rejects_non_machine_credential():
    class API:
        def request(self, path, method="GET", payload=None):
            if path.startswith("/inventories/"):
                return {"results": [{"id": 11, "name": "aap-demo-fleet"}]}
            if path.startswith("/credentials/"):
                return {"results": [{"id": 22, "name": "aap-demo-fleet-ssh", "kind": "vault"}]}
            raise AssertionError(path)

    with pytest.raises(RuntimeError, match="not a machine credential"):
        MODULE.resolve_fleet_binding(API(), 1, "fleet-ubi9")


def test_fleet_templates_are_owned_and_bind_selected_credential():
    class API:
        def __init__(self):
            self.calls = []

        def find(self, endpoint, name):
            return None

        def request(self, path, method="GET", payload=None):
            self.calls.append((path, method, payload))
            return {"id": 44} if path == "/job_templates/" else {}

    api = API()
    MODULE.provision_fleet_templates(api, 1, 42, 11, 22, "fleet-ubi9")
    created = [p for path, method, p in api.calls if path == "/job_templates/" and method == "POST"]
    assert created
    assert all(p["name"].startswith("Fleet | ") for p in created)
    assert all(p["inventory"] == 11 and p["limit"] == "fleet-ubi9" for p in created)
    assert all(p["project"] == 42 for p in created)
    preview = next(p for p in created if p["name"] == "Fleet | Disk Cleanup Preview")
    assert preview["job_type"] == "check"
    assert preview["playbook"] == "disk-utilization/playbooks/remediate_disk_cleanup.yml"
    assert len(
        [
            call
            for call in api.calls
            if call == ("/job_templates/44/credentials/", "POST", {"id": 22})
        ]
    ) == len(created)


def test_fleet_templates_do_not_reassociate_existing_credential():
    class API:
        def __init__(self):
            self.calls = []

        def find(self, endpoint, name):
            return None

        def request(self, path, method="GET", payload=None):
            self.calls.append((path, method, payload))
            if path == "/job_templates/":
                return {"id": 44}
            if path == "/job_templates/44/credentials/" and method == "GET":
                return {"results": [{"id": 22}]}
            raise AssertionError("already-associated credential must not be added again")

    api = API()
    MODULE.provision_fleet_templates(api, 1, 42, 11, 22, "fleet-ubi9")


def test_main_validates_fleet_before_creating_project(monkeypatch, tmp_path):
    class API:
        def __init__(self, route, token):
            pass

        def request(self, path, method="GET", payload=None):
            if path.startswith("/organizations/"):
                return {"results": [{"id": 1}]}
            if path.startswith("/inventories/"):
                return {"results": []}
            raise AssertionError(f"unexpected mutation before Fleet preflight: {path}")

    monkeypatch.setattr(MODULE, "AAP", API)
    status_file = tmp_path / "status"
    status_file.write_text("ready\n", encoding="utf-8")
    monkeypatch.setattr(
        "sys.argv",
        [
            "provision",
            "--route",
            "example.test",
            "--token",
            "x",
            "--fleet-host",
            "node",
            "--fleet-service-status-file",
            str(status_file),
        ],
    )
    with pytest.raises(RuntimeError, match="inventories"):
        MODULE.main()
    assert status_file.read_text(encoding="utf-8") == "unavailable\n"


def test_fleet_template_will_not_overwrite_unowned_name():
    class API:
        def find(self, endpoint, name):
            return {"id": 33, "description": "A user-created template"}

        def request(self, path, method="GET", payload=None):
            raise AssertionError("unowned template must not be changed")

    with pytest.raises(RuntimeError, match="refusing to overwrite"):
        MODULE.provision_fleet_templates(API(), 1, 42, 11, 22, "fleet-ubi9")


def test_fleet_template_will_not_modify_owned_template_in_another_org():
    class API:
        def find(self, endpoint, name):
            return {"id": 33, "description": MODULE.FLEET_TEMPLATE_MARKER, "organization": 2}

        def request(self, path, method="GET", payload=None):
            raise AssertionError("another organization's template must not be changed")

    with pytest.raises(RuntimeError, match="refusing to overwrite"):
        MODULE.provision_fleet_templates(API(), 1, 42, 11, 22, "fleet-ubi9")


def test_fleet_template_preserves_unexpected_changes_to_owned_template():
    class API:
        def find(self, endpoint, name):
            return {
                "id": 33,
                "name": name,
                "description": MODULE.FLEET_TEMPLATE_MARKER,
                "organization": 1,
                "project": 42,
                "inventory": 11,
                "limit": "someone-else",
            }

        def request(self, path, method="GET", payload=None):
            raise AssertionError("user-modified template must not be changed")

    with pytest.raises(RuntimeError, match="changed"):
        MODULE.provision_fleet_templates(API(), 1, 42, 11, 22, "fleet-ubi9")


def test_service_demo_template_uses_product_demo_project_and_fleet_credential():
    class API:
        def __init__(self):
            self.calls = []

        def find(self, endpoint, name):
            return None

        def request(self, path, method="GET", payload=None):
            self.calls.append((path, method, payload))
            if path == "/job_templates/":
                return {"id": 44}
            return {"results": []}

    api = API()
    MODULE.provision_service_template(api, 1, 52, 11, 22, "fleet-ubi9")
    payload = next(
        p for path, method, p in api.calls if path == "/job_templates/" and method == "POST"
    )
    assert payload["project"] == 52
    assert payload["playbook"] == "linux/fleet_ao_smoke.yml"
    assert json.loads(payload["extra_vars"]) == {"_hosts": "fleet-ubi9"}
    assert payload["inventory"] == 11
    assert payload["limit"] == "fleet-ubi9"
    assert ("/job_templates/44/credentials/", "POST", {"id": 22}) in api.calls


def test_service_template_migrates_only_unmodified_managed_script():
    old_script = (
        "systemctl is-active --quiet aap-demo-fleet-smoke.service || "
        "systemd-run --collect --unit=aap-demo-fleet-smoke /usr/bin/sleep 300"
    )
    old = {
        "id": 44,
        "name": "Fleet | Start Demo Service",
        "description": MODULE.FLEET_TEMPLATE_MARKER,
        "organization": 1,
        "job_type": "run",
        "project": 52,
        "playbook": "linux/run_script.yml",
        "inventory": 11,
        "limit": "fleet-ubi9",
        "ask_variables_on_launch": False,
        "extra_vars": json.dumps({"_hosts": "fleet-ubi9", "shell_script": old_script}),
    }

    class API:
        def __init__(self):
            self.calls = []

        def find(self, endpoint, name):
            return old

        def request(self, path, method="GET", payload=None):
            self.calls.append((path, method, payload))
            return {"results": [{"id": 22}]}

    api = API()
    MODULE.provision_service_template(api, 1, 52, 11, 22, "fleet-ubi9")
    assert any(
        method == "PATCH" and payload["playbook"] == "linux/fleet_ao_smoke.yml"
        for path, method, payload in api.calls
    )
    old["limit"] = "other-host"
    with pytest.raises(RuntimeError, match="changed"):
        MODULE.provision_service_template(API(), 1, 52, 11, 22, "fleet-ubi9")


def test_missing_service_playbook_does_not_mark_workflow_ready(monkeypatch):
    monkeypatch.setattr(MODULE, "product_demos_project", lambda api: (2, 33))
    monkeypatch.setattr(MODULE, "provision_manual_intervention_template", lambda *args: None)
    api = SimpleNamespace(
        wait_for_project_sync=lambda project_id: None, request=lambda path: ["linux/run_script.yml"]
    )
    assert MODULE.provision_optional_fleet_templates(api, 11, 22, "fleet-ubi9") == (False, True)


def test_manual_intervention_template_succeeds_with_explicit_message():
    class API:
        def __init__(self):
            self.payload = None

        def find(self, endpoint, name):
            return None

        def request(self, path, method="GET", payload=None):
            if path == "/job_templates/":
                self.payload = payload
                return {"id": 44}
            return {"results": []}

    api = API()
    MODULE.provision_manual_intervention_template(api, 2, 52, 11, 22, "fleet-ubi9")
    assert api.payload["name"] == "Fleet | Manual Intervention Required"
    assert "manual intervention" in api.payload["extra_vars"].lower()
    assert "exit 1" not in api.payload["extra_vars"]


def test_manual_intervention_template_migrates_its_previous_failing_script():
    old_script = (
        "printf '%s\\n' 'Fleet PVC expansion is not supported or disk usage could not be "
        "classified; manual intervention is required.' >&2; exit 1"
    )
    old_payload = {
        "id": 44,
        "name": "Fleet | Manual Intervention Required",
        "description": MODULE.FLEET_TEMPLATE_MARKER,
        "organization": 2,
        "job_type": "run",
        "project": 52,
        "playbook": "linux/run_script.yml",
        "inventory": 11,
        "limit": "fleet-ubi9",
        "ask_variables_on_launch": False,
        "extra_vars": json.dumps({"_hosts": "fleet-ubi9", "shell_script": old_script}),
    }

    class API:
        def __init__(self):
            self.calls = []

        def find(self, endpoint, name):
            return old_payload

        def request(self, path, method="GET", payload=None):
            self.calls.append((path, method, payload))
            if path == "/job_templates/44/credentials/":
                return {"results": [{"id": 22}]}
            return {}

    api = API()
    MODULE.provision_manual_intervention_template(api, 2, 52, 11, 22, "fleet-ubi9")
    update = next(
        call for call in api.calls if call[0] == "/job_templates/44/" and call[1] == "PATCH"
    )
    assert "exit 1" not in update[2]["extra_vars"]


def test_product_demo_project_is_scoped_to_the_apd_organization():
    class API:
        def request(self, path, method="GET", payload=None):
            if path.startswith("/organizations/"):
                return {"results": [{"id": 2, "name": "Ansible Product Demos (APD)"}]}
            if path.startswith("/projects/"):
                assert "organization=2" in path
                return {"results": [{"id": 33, "name": "Ansible Product Demos", "organization": 2}]}
            raise AssertionError(path)

    assert MODULE.product_demos_project(API()) == (2, 33)


def test_fleet_project_uses_pinned_demo_ref_and_separate_name():
    class API:
        def __init__(self):
            self.created = None

        def find(self, endpoint, name):
            return None

        def request(self, path, method="GET", payload=None):
            assert path == "/projects/" and method == "POST"
            self.created = payload
            return {"id": 77}

        def wait_for_project_sync(self, project_id):
            assert project_id == 77

    api = API()
    assert MODULE.ensure_fleet_project(api, 1, "abcc1a1482a") == 77
    assert api.created["name"] != MODULE.PROJECT_NAME
    assert api.created["scm_branch"] == "abcc1a1482a"
    assert api.created["scm_url"] == MODULE.PROJECT_URL


def test_fleet_project_respects_configured_demo_repository():
    class API:
        def __init__(self):
            self.created = None

        def find(self, endpoint, name):
            return None

        def request(self, path, method="GET", payload=None):
            self.created = payload
            return {"id": 77}

        def wait_for_project_sync(self, project_id):
            pass

    api = API()
    MODULE.ensure_fleet_project(api, 1, "fork-ref", repository="https://example.test/fork")
    assert api.created["scm_url"] == "https://example.test/fork"
    assert api.created["scm_branch"] == "fork-ref"


def test_manual_template_is_attempted_when_service_template_fails(monkeypatch):
    called = []
    monkeypatch.setattr(MODULE, "product_demos_project", lambda api: (2, 33))
    monkeypatch.setattr(
        MODULE,
        "provision_service_template",
        lambda *a: (_ for _ in ()).throw(RuntimeError("service conflict")),
    )
    monkeypatch.setattr(
        MODULE, "provision_manual_intervention_template", lambda *a: called.append("manual")
    )
    api = SimpleNamespace(
        wait_for_project_sync=lambda project_id: None,
        request=lambda path: ["linux/fleet_ao_smoke.yml"],
    )
    assert MODULE.provision_optional_fleet_templates(api, 11, 22, "fleet-ubi9") == (False, True)
    assert called == ["manual"]


def test_fleet_template_migration_changes_only_legacy_project():
    payload = {
        "name": "Fleet | Disk Utilization Check",
        "description": MODULE.FLEET_TEMPLATE_MARKER,
        "organization": 1,
        "job_type": "run",
        "project": 77,
        "playbook": "disk-utilization/playbooks/check_disk.yml",
        "inventory": 11,
        "limit": "fleet-ubi9",
        "ask_variables_on_launch": True,
    }
    previous = {**payload, "id": 44, "project": 42, "custom_field": "preserve"}

    class API:
        def __init__(self):
            self.calls = []

        def request(self, path, method="GET", payload=None):
            self.calls.append((path, method, payload))
            return {"results": [{"id": 22}]}

    api = API()
    MODULE.ensure_owned_template(api, payload, 22, previous, legacy_project_id=42)
    assert api.calls[0] == ("/job_templates/44/", "PATCH", {"project": 77})
    assert previous["custom_field"] == "preserve"


def test_fleet_template_migration_refuses_other_changes():
    payload = {"name": "Fleet | example", "project": 77, "limit": "fleet-ubi9"}
    previous = {"id": 44, "name": "Fleet | example", "project": 42, "limit": "another"}

    class API:
        def request(self, path, method="GET", payload=None):
            raise AssertionError("modified template must not be changed")

    with pytest.raises(RuntimeError, match="has changed"):
        MODULE.ensure_owned_template(API(), payload, 22, previous, legacy_project_id=42)


if __name__ == "__main__":
    test_reuses_successfully_synced_project()
    test_missing_license_message_includes_aap_address()
    test_control_job_extra_vars_include_agent_binding()
    print("AAP provisioning tests passed")
