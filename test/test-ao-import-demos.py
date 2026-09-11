#!/usr/bin/env python3
"""Focused normalization tests for the AO demo importer."""

import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).parents[1] / "addons" / "ao" / "scripts" / "import-demos.py"
SPEC = importlib.util.spec_from_file_location("import_demos", SCRIPT)
assert SPEC and SPEC.loader
IMPORT_DEMOS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMPORT_DEMOS)


class NormalizeWebhookTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
