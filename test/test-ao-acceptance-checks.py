"""Contract tests for managed AAP-Demo inventory and wiring checks."""

from pathlib import Path
import sys
import unittest


ACCEPTANCE_DIR = Path(__file__).parent / "ao-acceptance"
sys.path.insert(0, str(ACCEPTANCE_DIR))

import inventory  # noqa: E402
from checks import readiness, wiring  # noqa: E402
from model import CheckStatus, FailureClass  # noqa: E402


MANAGED_MARKERS = {
    "organizations": "aap-demo",
    "projects": "orchestrator",
    "inventories": "aap-demo",
    "credentials": "aap-demo",
    "job_templates": "orchestrator demo",
    "execution_environments": "aap-demo",
    "ao_integrations": "aap-demo",
    "ao_workflows": "aap-demo",
}


class FakeAapClient:
    def __init__(self, resources):
        self.resources = resources
        self.calls = []

    def list_all(self, path):
        self.calls.append(path)
        return self.resources.get(path, [])


class FakeAoClient(FakeAapClient):
    pass


class FakeProbes:
    def __init__(self, **ready):
        self.ready = {"aap": True, "ao": True, "mcp": True, **ready}

    def aap_ready(self):
        return self.ready["aap"]

    def ao_ready(self):
        return self.ready["ao"]

    def mcp_ready(self):
        return self.ready["mcp"]


def managed_resources():
    return {
        "/api/v2/organizations/": [
            {"id": 1, "name": "Demo", "description": "AAP-Demo managed organization"},
            {"id": 2, "name": "Unrelated", "description": "other"},
        ],
        "/api/v2/projects/": [
            {
                "id": 10,
                "name": "AAP Orchestrator Demos",
                "description": "AAP-Demo orchestrator content",
                "organization": 1,
                "scm_type": "git",
                "scm_url": "https://github.com/ansible-tmm/aap-orchestrator-demos.git",
                "scm_branch": "abcc1a1482a",
                "scm_revision": "abcc1a1482a0000000000000000000000000000000",
                "scm_update_on_launch": False,
            },
            {"id": 11, "name": "Unrelated", "description": "other", "organization": 2},
        ],
        "/api/v2/inventories/": [
            {"id": 20, "name": "AAP-Demo Inventory", "organization": 1},
            {"id": 21, "name": "Other", "organization": 2},
        ],
        "/api/v2/credentials/": [
            {
                "id": 30,
                "name": "aap-demo AAP Token",
                "description": "AAP-Demo credential",
                "organization": 1,
                "summary_fields": {"credential_type": {"name": "Red Hat Ansible Automation Platform"}},
            },
            {"id": 31, "name": "Other", "description": "other", "organization": 2},
        ],
        "/api/v2/job_templates/": [
            {
                "id": 40,
                "name": "Renew Certificate",
                "description": "AAP Orchestrator demo playbook",
                "organization": 1,
                "project": 10,
                "inventory": 20,
                "execution_environment": 50,
                "playbook": "cert-lifecycle/playbooks/renew_certificate.yml",
                "summary_fields": {"user_capabilities": {"start": True}},
            },
            {"id": 41, "name": "Other", "description": "other", "project": 11},
        ],
        "/api/v2/job_templates/40/credentials/": [],
        "/api/v2/execution_environments/": [
            {"id": 50, "name": "AAP-Demo EE", "description": "AAP-Demo managed image"},
            {"id": 51, "name": "Other", "description": "other"},
        ],
        "/api/v1/integrations": [
            {
                "id": "aap",
                "name": "aap-demo AAP",
                "description": "Auto-wired by aap-demo",
                "base_url": "https://aap.example.test",
                "enabled": True,
                "management_credential_id": "ao-aap-credential",
                "integration_type": "ansible_automation_platform",
            },
            {
                "id": "mcp",
                "name": "aap-demo MCP Server",
                "description": "Auto-wired by aap-demo",
                "base_url": "https://mcp.example.test/mcp",
                "enabled": True,
                "management_credential_id": "ao-mcp-credential",
                "integration_type": "mcp_server",
            },
            {"id": "other", "name": "Other", "description": "other"},
        ],
        "/api/v1/credentials": [
            {
                "id": "ao-aap-credential",
                "name": "aap-demo AAP Token",
                "description": "Auto-wired by aap-demo",
                "credential_type_id": "aap-type",
            },
            {
                "id": "ao-mcp-credential",
                "name": "aap-demo MCP Token",
                "description": "Auto-wired by aap-demo",
                "credential_type_id": "bearer-type",
            },
        ],
        "/api/v1/workflows": [
            {
                "id": "workflow-1",
                "name": "AAP-Demo certificate workflow",
                "labels": {"aap-demo": "true"},
                "workflow_definition": {
                    "nodes": [
                        {
                            "type": "aap_job_template",
                            "parameters": {
                                "job_template_id": 40,
                                "integration_id": "aap",
                                "credential_id": "ao-aap-credential",
                            },
                        }
                    ]
                },
            },
            {"id": "other", "name": "Other", "labels": {}},
        ],
    }


class InventoryTests(unittest.TestCase):
    def test_build_inventory_filters_managed_resources_and_resolves_links(self):
        resources = managed_resources()

        result = inventory.build_inventory(FakeAapClient(resources), FakeAoClient(resources), MANAGED_MARKERS)

        self.assertEqual([item["id"] for item in result.organizations], [1])
        self.assertEqual([item["id"] for item in result.projects], [10])
        self.assertEqual(result.projects[0]["organization_id"], 1)
        self.assertEqual(result.job_templates[0]["project_id"], 10)
        self.assertEqual(result.job_templates[0]["project_name"], "AAP Orchestrator Demos")
        self.assertEqual(result.job_templates[0]["credential_ids"], [])
        self.assertEqual(result.job_templates[0]["execution_environment_name"], "AAP-Demo EE")
        self.assertEqual([item["id"] for item in result.ao_integrations], ["aap", "mcp"])
        self.assertEqual(
            [item["id"] for item in result.ao_credentials],
            ["ao-aap-credential", "ao-mcp-credential"],
        )
        self.assertEqual(result.ao_workflows[0]["aap_job_template_nodes"][0]["job_template_id"], 40)
        self.assertEqual(result.ao_workflows[0]["aap_job_template_nodes"][0]["job_template_name"], "Renew Certificate")

    def test_build_inventory_normalizes_string_form_link_ids(self):
        resources = managed_resources()
        resources["/api/v2/job_templates/"][0]["project"] = "10"
        resources["/api/v1/workflows"][0]["workflow_definition"]["nodes"][0]["parameters"]["job_template_id"] = "40"

        result = inventory.build_inventory(FakeAapClient(resources), FakeAoClient(resources), MANAGED_MARKERS)

        self.assertEqual(result.job_templates[0]["project_id"], 10)
        self.assertEqual(result.job_templates[0]["project_name"], "AAP Orchestrator Demos")
        self.assertEqual(result.ao_workflows[0]["aap_job_template_nodes"][0]["job_template_id"], 40)
        self.assertEqual(result.ao_workflows[0]["aap_job_template_nodes"][0]["job_template_name"], "Renew Certificate")

    def test_build_inventory_recognizes_stable_addon_names_with_generic_markers(self):
        generic_markers = {key: "aap-demo" for key in MANAGED_MARKERS}

        result = inventory.build_inventory(FakeAapClient(managed_resources()), FakeAoClient(managed_resources()), generic_markers)

        self.assertEqual([item["name"] for item in result.projects], ["AAP Orchestrator Demos"])
        self.assertEqual([item["name"] for item in result.job_templates], ["Renew Certificate"])

    def test_build_inventory_includes_default_apd_and_openshift_product_demo_resources(self):
        resources = managed_resources()
        resources["/api/v2/organizations/"][0] = {"id": 1, "name": "Default", "description": ""}
        resources["/api/v2/organizations/"].append(
            {"id": 3, "name": "Ansible Product Demos (APD)", "description": ""}
        )
        resources["/api/v2/job_templates/"].append({
            "id": 42,
            "name": "APD | Install OpenShift Demos",
            "description": "",
            "organization": 3,
            "project": 10,
            "inventory": 20,
            "execution_environment": "52",
            "summary_fields": {"user_capabilities": {"start": True}},
        })
        resources["/api/v2/job_templates/42/credentials/"] = [{"id": 30}]
        resources["/api/v2/execution_environments/"].append(
            {"id": 52, "name": "OPENSHIFT", "description": ""}
        )

        result = inventory.build_inventory(FakeAapClient(resources), FakeAoClient(resources), MANAGED_MARKERS)

        self.assertEqual([item["name"] for item in result.organizations], ["Default", "Ansible Product Demos (APD)"])
        self.assertEqual([item["name"] for item in result.job_templates], ["Renew Certificate", "APD | Install OpenShift Demos"])
        self.assertEqual([item["name"] for item in result.execution_environments], ["AAP-Demo EE", "OPENSHIFT"])


class ReadinessTests(unittest.TestCase):
    def test_readiness_reports_each_live_service_with_a_prerequisite_failure(self):
        result = inventory.build_inventory(FakeAapClient(managed_resources()), FakeAoClient(managed_resources()), MANAGED_MARKERS)

        checks = readiness.run(result, FakeProbes(ao=False))

        failed = next(check for check in checks if check.component == "ao")
        self.assertEqual(failed.status, CheckStatus.FAIL)
        self.assertEqual(failed.failure_class, FailureClass.PREREQUISITE)
        self.assertEqual(
            {check.component for check in checks},
            {"aap", "ao", "mcp", "product_demos"},
        )

    def test_product_demos_readiness_requires_the_safe_exact_representative(self):
        managed = inventory.ManagedResourceInventory(
            projects=[{"id": 10, "name": "APD Bootstrap Project"}],
            execution_environments=[{
                "id": 20,
                "name": "Product Demos EE",
                "image": "quay.io/ansible-product-demos/apd-ee-27:latest",
                "available": True,
            }],
            job_templates=[{
                "id": 30,
                "name": "AAP-Demo Acceptance | Product Demos Read-Only Diagnostic",
                "project_id": 10,
                "execution_environment_id": 20,
                "playbook": "acceptance-read-only.yml",
                "can_start": True,
                "ask_variables_on_launch": True,
            }],
        )

        checks = readiness.run(managed, FakeProbes())

        product_demos = next(
            check for check in checks if check.component == "product_demos"
        )
        self.assertEqual(product_demos.status, CheckStatus.PASS)
        self.assertGreater(product_demos.duration_seconds, 0.0)


class WiringTests(unittest.TestCase):
    def setUp(self):
        self.resources = managed_resources()

    def build(self):
        return inventory.build_inventory(FakeAapClient(self.resources), FakeAoClient(self.resources), MANAGED_MARKERS)

    def test_wiring_accepts_expected_project_and_workflow_relationships(self):
        checks = wiring.run(self.build())

        self.assertTrue(all(check.status == CheckStatus.PASS for check in checks))
        self.assertTrue(all(check.duration_seconds > 0.0 for check in checks))
        self.assertTrue(any(check.check_id == "wiring.project.10" for check in checks))
        self.assertTrue(any(check.check_id == "wiring.workflow.workflow-1" for check in checks))

    def test_wiring_classifies_missing_integration_as_wiring_failure(self):
        self.resources["/api/v1/integrations"] = self.resources["/api/v1/integrations"][:1]

        checks = wiring.run(self.build())

        failed = next(check for check in checks if check.check_id == "wiring.integration.aap-demo-mcp-server")
        self.assertEqual(failed.status, CheckStatus.FAIL)
        self.assertEqual(failed.failure_class, FailureClass.WIRING)

    def test_wiring_classifies_missing_credential_as_wiring_failure(self):
        self.resources["/api/v2/credentials/"] = []

        checks = wiring.run(self.build())

        failed = next(check for check in checks if check.check_id == "wiring.credentials")
        self.assertEqual(failed.status, CheckStatus.FAIL)
        self.assertEqual(failed.failure_class, FailureClass.WIRING)

    def test_wiring_classifies_missing_workflow_binding_as_wiring_failure(self):
        parameters = self.resources["/api/v1/workflows"][0]["workflow_definition"]["nodes"][0]["parameters"]
        parameters.pop("credential_id")

        checks = wiring.run(self.build())

        failed = next(check for check in checks if check.check_id == "wiring.workflow.workflow-1")
        self.assertEqual(failed.status, CheckStatus.FAIL)
        self.assertEqual(failed.failure_class, FailureClass.WIRING)

    def test_wiring_allows_an_intentionally_credentialless_job_template(self):
        self.resources["/api/v2/job_templates/40/credentials/"] = []

        checks = wiring.run(self.build())

        check = next(check for check in checks if check.check_id == "wiring.job-template.40.credentials")
        self.assertEqual(check.status, CheckStatus.PASS)

    def test_wiring_classifies_dangling_job_template_credential_as_wiring_failure(self):
        self.resources["/api/v2/job_templates/40/credentials/"] = [{"id": 999}]

        checks = wiring.run(self.build())

        failed = next(check for check in checks if check.check_id == "wiring.job-template.40.credentials")
        self.assertEqual(failed.status, CheckStatus.FAIL)
        self.assertEqual(failed.failure_class, FailureClass.WIRING)

    def test_wiring_classifies_wrong_job_template_credential_type_as_wiring_failure(self):
        self.resources["/api/v2/job_templates/40/credentials/"] = [{"id": 30}]
        credential_type = self.resources["/api/v2/credentials/"][0]["summary_fields"]["credential_type"]
        credential_type["name"] = "Machine"

        checks = wiring.run(self.build())

        failed = next(check for check in checks if check.check_id == "wiring.job-template.40.credentials")
        self.assertEqual(failed.status, CheckStatus.FAIL)
        self.assertEqual(failed.failure_class, FailureClass.WIRING)

    def test_wiring_rejects_a_mutable_project_branch(self):
        self.resources["/api/v2/projects/"][0]["scm_branch"] = "main"

        checks = wiring.run(self.build())

        failed = next(check for check in checks if check.check_id == "wiring.project.10")
        self.assertEqual(failed.status, CheckStatus.FAIL)

    def test_read_only_representative_requires_the_bounded_probe_input_contract(self):
        managed = inventory.ManagedResourceInventory(
            projects=[{"id": 10, "name": "APD Bootstrap Project"}],
            execution_environments=[{"id": 20, "name": "Product Demos EE"}],
            job_templates=[{
                "id": 30,
                "name": "AAP-Demo Acceptance | Product Demos Read-Only Diagnostic",
                "project_id": 10,
                "project_name": "APD Bootstrap Project",
                "execution_environment_id": 20,
                "playbook": "acceptance-read-only.yml",
                "can_start": True,
                "ask_variables_on_launch": False,
                "credential_ids": [],
            }],
        )

        checks = wiring.run(managed)

        representative = next(
            check for check in checks
            if check.check_id == "wiring.job-template.30"
        )
        self.assertEqual(representative.status, CheckStatus.FAIL)

    def test_wiring_requires_the_effective_ao_integration_credential(self):
        self.resources["/api/v1/integrations"][0]["management_credential_id"] = "ao-mcp-credential"

        checks = wiring.run(self.build())

        failed = next(
            check for check in checks
            if check.check_id == "wiring.integration.aap-demo-aap"
        )
        self.assertEqual(failed.status, CheckStatus.FAIL)


if __name__ == "__main__":
    unittest.main()
