"""Focused normalization tests for the AO demo importer."""

import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "addons" / "ao" / "scripts" / "import-demos.py"
SPEC = importlib.util.spec_from_file_location("import_demos", SCRIPT)
assert SPEC and SPEC.loader
IMPORT_DEMOS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMPORT_DEMOS)


class NormalizeWebhookTests(unittest.TestCase):
    def test_binds_agentic_node_to_provider_integration_and_model(self):
        workflow = {
            "nodes": [{
                "type": "agentic",
                "parameters": {
                    "model": "stale-model",
                    "integration_id": "stale-integration",
                },
            }]
        }

        normalized = IMPORT_DEMOS.normalize(
            workflow,
            "aap-credential",
            agent_credential_id="llm-credential",
            agent_integration_id="llm-integration",
            agent_model_id="llm-model",
        )

        parameters = normalized["nodes"][0]["parameters"]
        self.assertEqual(parameters["credential_id"], "llm-credential")
        self.assertEqual(parameters["integration_id"], "llm-integration")
        self.assertEqual(parameters["llm_model_id"], "llm-model")
        self.assertNotIn("model", parameters)

    def test_authorizes_legacy_webhook_with_local_service_account(self):
        workflow = {
            "triggers": [{
                "id": "trigger_webhook",
                "type": "webhook_trigger",
                "parameters": {"webhook_path": "splunk-cert-alert"},
            }]
        }

        normalized = IMPORT_DEMOS.normalize(
            workflow,
            "aap-credential",
            webhook_service_account_id="service-account-id",
        )

        self.assertEqual(
            normalized["triggers"][0]["parameters"]["authorized_service_account_ids"],
            ["service-account-id"],
        )

    def test_preserves_existing_service_account_allow_list(self):
        workflow = {
            "triggers": [{
                "type": "webhook_trigger",
                "parameters": {
                    "webhook_path": "alert",
                    "authorized_service_account_ids": ["upstream-account-id"],
                },
            }]
        }

        normalized = IMPORT_DEMOS.normalize(
            workflow,
            "aap-credential",
            webhook_service_account_id="local-account-id",
        )

        self.assertEqual(
            normalized["triggers"][0]["parameters"]["authorized_service_account_ids"],
            ["upstream-account-id"],
        )

    def test_drops_stale_mcp_connection_when_local_binding_is_missing(self):
        workflow = {
            "nodes": [{
                "type": "agentic",
                "parameters": {
                    "integration_connections": [{
                        "integration_id": "old-integration",
                        "credential_id": "old-credential",
                    }],
                },
            }]
        }

        normalized = IMPORT_DEMOS.normalize(workflow, "aap-credential")

        self.assertNotIn(
            "integration_connections",
            normalized["nodes"][0]["parameters"],
        )


class ExistingWorkflowProjectTests(unittest.TestCase):
    def test_rejects_existing_workflow_from_different_project(self):
        with self.assertRaisesRegex(ValueError, "different AO project"):
            IMPORT_DEMOS.validate_existing_workflow_project(
                {"id": "workflow-id", "project_id": "old-project"},
                "target-project",
            )

    def test_accepts_existing_workflow_in_target_project(self):
        IMPORT_DEMOS.validate_existing_workflow_project(
            {"id": "workflow-id", "project_id": "target-project"},
            "target-project",
        )


class DownloadArchiveTests(unittest.TestCase):
    @mock.patch.object(IMPORT_DEMOS.subprocess, "run")
    @mock.patch.dict(
        IMPORT_DEMOS.os.environ,
        {
            "CURL_CA_BUNDLE": "/tmp/crc-ingress-ca.crt",
            "SSL_CERT_FILE": "/tmp/crc-ingress-ca.crt",
            "REQUESTS_CA_BUNDLE": "/tmp/corporate-ca-bundle.crt",
        },
    )
    def test_uses_native_tls_without_standalone_ingress_ca(self, run):
        destination = Path("/tmp/aap-demo-test-archive.tar.gz")

        IMPORT_DEMOS.download_archive("https://github.example/archive.tar.gz", destination)

        command = run.call_args.args[0]
        self.assertEqual(command[0], "curl")
        self.assertIn("--fail", command)
        self.assertIn("--location", command)
        self.assertNotIn("--insecure", command)
        self.assertEqual(command[-2:], [str(destination), "https://github.example/archive.tar.gz"])
        call = run.call_args
        self.assertEqual(call.kwargs["check"], True)
        self.assertEqual(call.kwargs["capture_output"], True)
        self.assertEqual(call.kwargs["text"], True)
        self.assertNotIn("CURL_CA_BUNDLE", call.kwargs["env"])
        self.assertNotIn("SSL_CERT_FILE", call.kwargs["env"])
        self.assertEqual(
            call.kwargs["env"]["REQUESTS_CA_BUNDLE"],
            "/tmp/corporate-ca-bundle.crt",
        )

    @mock.patch.object(IMPORT_DEMOS.subprocess, "run")
    def test_reports_curl_tls_failure(self, run):
        run.side_effect = subprocess.CalledProcessError(
            60,
            ["curl"],
            stderr="SSL certificate problem: unable to get local issuer certificate",
        )

        with self.assertRaisesRegex(RuntimeError, "unable to get local issuer certificate"):
            IMPORT_DEMOS.download_archive(
                "https://github.example/archive.tar.gz",
                Path("/tmp/aap-demo-test-archive.tar.gz"),
            )


if __name__ == "__main__":
    unittest.main()
