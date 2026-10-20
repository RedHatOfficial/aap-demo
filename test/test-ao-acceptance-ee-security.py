"""Contract tests for AO/AAP-Demo security probes and managed EEs."""

from pathlib import Path
import sys
import unittest


ACCEPTANCE_DIR = Path(__file__).parent / "ao-acceptance"
sys.path.insert(0, str(ACCEPTANCE_DIR))

from environment import CommandResult  # noqa: E402
from inventory import ManagedResourceInventory  # noqa: E402
from model import CheckStatus, FailureClass  # noqa: E402
import probes  # noqa: E402
from redaction import REDACTED, redact  # noqa: E402
from checks import execution_environments, security  # noqa: E402


class FakeRunner:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []
        self.timeouts = []

    def run(self, args, *, check=False, timeout=60):
        del check
        self.calls.append(args)
        self.timeouts.append(timeout)
        key = tuple(args)
        if key in self.responses:
            return self.responses[key]
        if args[:3] == ["kubectl", "get", "pods"]:
            return CommandResult(0, "aap-controller-task-0", "")
        return CommandResult(1, "", "unexpected command")


class ProbeSetTests(unittest.TestCase):
    def test_default_ee_selector_matches_the_running_aap_controller_task_pod(self):
        probe_set = probes.ProbeSet(FakeRunner({}))

        self.assertEqual(probe_set.ee_selector, "app.kubernetes.io/name=aap-controller-task")

    def test_host_probes_verify_dns_and_tls_without_an_insecure_fallback(self):
        host = "aap.example.test"
        curl_args = probes.https_command(f"https://{host}/api/gateway/v1/ping/")
        runner = FakeRunner({
            ("getent", "hosts", host): CommandResult(0, f"192.0.2.10 {host}\n", ""),
            tuple(curl_args): CommandResult(
                0,
                "200\n" + host + "\nsubject=CN=aap.example.test\nissuer=CN=Demo ingress CA\n",
                "",
            ),
        })
        probe_set = probes.ProbeSet(runner)

        dns = probe_set.host_dns(host)
        https = probe_set.host_https(f"https://{host}/api/gateway/v1/ping/")

        self.assertTrue(dns.ok)
        self.assertTrue(https.ok)
        self.assertEqual(https.status, 200)
        self.assertEqual(https.hostname, host)
        self.assertEqual(https.certificate_subject, "CN=aap.example.test")
        self.assertEqual(https.certificate_issuer, "CN=Demo ingress CA")
        self.assertNotIn("-k", curl_args)
        self.assertNotIn("--insecure", curl_args)

    def test_dns_and_pod_certificate_failures_are_redacted_and_distinct(self):
        host = "mcp.example.test"
        pod = "acceptance-ee-job-abc"
        selector = "job-name=acceptance-ee-job"
        curl_args = probes.https_command(f"https://{host}/mcp")
        runner = FakeRunner({
            ("getent", "hosts", host): CommandResult(2, "", "token=do-not-leak DNS failure"),
            (
                "kubectl", "get", "pods", "-n", "aap-operator", "-l", selector,
                "--field-selector=status.phase=Running",
                "-o", "jsonpath={.items[0].metadata.name}",
            ): CommandResult(0, pod, ""),
            tuple(["kubectl", "exec", "-n", "aap-operator", pod, "--", *curl_args]): CommandResult(
                60, "subject=CN=mcp.example.test\n-----BEGIN CERTIFICATE-----\nnot-diagnostic-data", "SSL certificate problem: api-key=do-not-leak password=still-secret token=also-secret X-API-Key: header-secret x-access-token=second-header-secret"
            ),
        })
        probe_set = probes.ProbeSet(runner)

        dns = probe_set.host_dns(host)
        pod_https = probe_set.ee_https("aap-operator", selector, f"https://{host}/mcp")

        self.assertFalse(dns.ok)
        self.assertFalse(pod_https.ok)
        self.assertNotIn("do-not-leak", dns.error)
        self.assertNotIn("do-not-leak", pod_https.error)
        self.assertNotIn("still-secret", pod_https.error)
        self.assertNotIn("also-secret", pod_https.error)
        self.assertNotIn("header-secret", pod_https.error)
        self.assertNotIn("second-header-secret", pod_https.error)
        self.assertNotIn("BEGIN CERTIFICATE", pod_https.error)
        self.assertEqual(pod_https.hostname, host)
        self.assertIn("certificate", pod_https.error.lower())

    def test_recursively_redacts_prefixed_secret_headers(self):
        diagnostics = redact({
            "headers": {
                "X-API-Key": "api-key-value",
                "x-access-token": "access-token-value",
                "Proxy-Authorization": "Bearer proxy-token-value",
            },
        })

        self.assertEqual(diagnostics["headers"]["X-API-Key"], REDACTED)
        self.assertEqual(diagnostics["headers"]["x-access-token"], REDACTED)
        self.assertEqual(diagnostics["headers"]["Proxy-Authorization"], REDACTED)

    def test_mcp_tools_are_observed_through_an_injected_mcp_client(self):
        class McpClient:
            def __init__(self):
                self.calls = 0

            def list_tools(self):
                self.calls += 1
                return ["controller_jobs_list"]

        client = McpClient()
        probe_set = probes.ProbeSet(FakeRunner({}), mcp_client=client)

        tools = probe_set.mcp_tools({"enabled_tools": ["configured-but-not-observed"]})

        self.assertEqual(tools, ["controller_jobs_list"])
        self.assertEqual(client.calls, 1)

    def test_identity_and_aap_token_observations_do_not_trust_constructor_metadata(self):
        class AapClient:
            def get(self, path):
                self.path = path
                return {"username": "not-admin"}

        probe_set = probes.ProbeSet(
            FakeRunner({}),
            aap_client=AapClient(),
            metadata={"users": {"admin": True}, "tokens": {"aap": True}},
        )

        self.assertFalse(probe_set.identity_observations()["admin"])
        self.assertFalse(probe_set.token_usable({"name": "aap-demo AAP"}))

    def test_identity_observations_reject_the_default_service_account_and_require_the_ao_identity(self):
        expected = "automation-orchestrator"

        class AapClient:
            def get(self, path):
                self.path = path
                return {"username": "admin"}

        class ServiceAccountRunner(FakeRunner):
            def __init__(self, service_account):
                super().__init__({})
                self.service_account = service_account

            def run(self, args, *, check=False, timeout=60):
                if args[:4] == ["kubectl", "get", "deployment", "automation-orchestrator-backend"]:
                    return CommandResult(0, self.service_account, "")
                if args[:3] == ["kubectl", "get", "serviceaccount"]:
                    return CommandResult(0, f"serviceaccount/{self.service_account}", "")
                return super().run(args, check=check, timeout=timeout)

        default_probe = probes.ProbeSet(ServiceAccountRunner("default"), aap_client=AapClient())
        self.assertFalse(default_probe.identity_observations()["automation-orchestrator"])

        named_probe = probes.ProbeSet(ServiceAccountRunner(expected), aap_client=AapClient())
        self.assertTrue(named_probe.identity_observations()["automation-orchestrator"])


class SecurityProbeDouble:
    def __init__(self, *, tls_ok=True, dns_ok=True, pod_ok=True, metadata=None, observations=None):
        self.tls_ok = tls_ok
        self.dns_ok = dns_ok
        self.pod_ok = pod_ok
        self.metadata = metadata or {
            "users": {"admin": True, "automation-orchestrator": True},
            "tokens": {"aap": True, "mcp": True},
            "mcp_tools": ["controller_jobs_list"],
            "private_network_routes": {},
        }
        self.observations = observations or {
            "users": {"admin": True, "automation-orchestrator": True},
            "tokens": {"aap-demo AAP": True, "aap-demo MCP Server": True},
            "mcp_tools": ["controller_jobs_list"],
            "private_network_routes": {},
        }
        self.calls = []
        self.ao_namespace = "automation-orchestrator"
        self.ao_selector = "app.kubernetes.io/component=backend"
        self.ao_selectors = (
            "app.kubernetes.io/component=backend",
            "app.kubernetes.io/component=worker",
        )

    def host_dns(self, host):
        self.calls.append(("dns", host))
        return probes.ProbeResult(self.dns_ok, None, host, None, None, "dns failed" if not self.dns_ok else "")

    def host_https(self, url):
        self.calls.append(("https", url))
        return probes.ProbeResult(self.tls_ok, 200 if self.tls_ok else None, url.split("/")[2], "CN=route", "CN=CA", "tls failed" if not self.tls_ok else "")

    def ee_https(self, namespace, selector, url):
        self.calls.append(("pod", namespace, selector, url))
        return probes.ProbeResult(self.pod_ok, 200 if self.pod_ok else None, url.split("/")[2], "CN=route", "CN=CA", "pod tls failed" if not self.pod_ok else "")

    def ao_https(self, namespace, selector, url):
        self.calls.append(("ao", namespace, selector, url))
        return probes.ProbeResult(self.pod_ok, 200 if self.pod_ok else None, url.split("/")[2], "CN=route", "CN=CA", "AO pod TLS failed" if not self.pod_ok else "")

    def security_metadata(self):
        return self.metadata

    def identity_observations(self):
        self.calls.append(("identity",))
        return self.observations["users"]

    def token_usable(self, integration):
        name = integration["name"]
        self.calls.append(("token", name))
        return self.observations["tokens"].get(name)

    def mcp_tools(self, integration):
        self.calls.append(("mcp-tools", integration["name"]))
        return self.observations["mcp_tools"]

    def private_network_ready(self, hostname):
        self.calls.append(("private-network", hostname))
        return self.observations["private_network_routes"].get(hostname, True)


def security_inventory():
    return ManagedResourceInventory(
        credentials=[
            {"id": 1, "name": "AAP Credential", "credential_type_name": "Red Hat Ansible Automation Platform"},
            {"id": 2, "name": "OpenShift Credential", "credential_type_name": "OpenShift or Kubernetes API Bearer Token"},
        ],
        execution_environments=[{"id": 10, "name": "Product Demos EE", "image": "quay.io/ansible-product-demos/apd-ee-27:latest"}],
        ao_integrations=[
            {"id": "aap", "name": "aap-demo AAP", "endpoint": "https://aap.example.test", "enabled": True, "credential_id": "aap-token"},
            {"id": "mcp", "name": "aap-demo MCP Server", "endpoint": "https://mcp.example.test/mcp", "enabled": True, "credential_id": "mcp-token", "enabled_tools": ["controller_jobs_list"]},
        ],
    )


class SecurityCheckTests(unittest.TestCase):
    def test_security_checks_require_trusted_routes_identities_tokens_and_mcp_tools(self):
        probe_set = SecurityProbeDouble()
        checks = security.run(security_inventory(), probe_set)

        self.assertTrue(all(check.status == CheckStatus.PASS for check in checks))
        self.assertTrue(any(check.check_id == "security.mcp.tools" for check in checks))
        self.assertTrue(any(check.check_id == "security.private-network.aap-demo-aap" for check in checks))
        self.assertIn(("identity",), probe_set.calls)
        self.assertIn(("token", "aap-demo AAP"), probe_set.calls)
        self.assertIn(("mcp-tools", "aap-demo MCP Server"), probe_set.calls)
        self.assertIn(("private-network", "aap.example.test"), probe_set.calls)
        self.assertIn(("ao", "automation-orchestrator", "app.kubernetes.io/component=backend", "https://aap.example.test"), probe_set.calls)
        self.assertIn(("ao", "automation-orchestrator", "app.kubernetes.io/component=worker", "https://aap.example.test"), probe_set.calls)

    def test_security_checks_report_tls_and_missing_token_metadata_as_wiring_failures(self):
        metadata = {
            "users": {"admin": True, "automation-orchestrator": False},
            "tokens": {"aap": True, "mcp": False},
            "mcp_tools": [],
            "private_network_routes": {"aap.example.test": False, "mcp.example.test": False},
        }
        checks = security.run(security_inventory(), SecurityProbeDouble(tls_ok=False, metadata=metadata, observations={
            "users": {"admin": True, "automation-orchestrator": False},
            "tokens": {"aap-demo AAP": True, "aap-demo MCP Server": False},
            "mcp_tools": [],
            "private_network_routes": {"aap.example.test": False, "mcp.example.test": False},
        }))

        tls = next(check for check in checks if check.check_id == "security.route.aap-demo-aap.tls")
        token = next(check for check in checks if check.check_id == "security.tokens")
        self.assertEqual(tls.status, CheckStatus.FAIL)
        self.assertEqual(tls.failure_class, FailureClass.PREREQUISITE)
        self.assertEqual(token.status, CheckStatus.FAIL)
        self.assertEqual(token.failure_class, FailureClass.PREREQUISITE)

    def test_security_rejects_constructor_metadata_when_observations_are_false(self):
        metadata = {
            "users": {"admin": True, "automation-orchestrator": True},
            "tokens": {"aap": True, "mcp": True},
            "mcp_tools": ["controller_jobs_list"],
            "private_network_routes": {"aap.example.test": True, "mcp.example.test": True},
        }
        probe_set = SecurityProbeDouble(metadata=metadata, observations={
            "users": {"admin": False, "automation-orchestrator": False},
            "tokens": {"aap-demo AAP": False, "aap-demo MCP Server": False},
            "mcp_tools": [],
            "private_network_routes": {"aap.example.test": False, "mcp.example.test": False},
        })

        checks = security.run(security_inventory(), probe_set)

        identities = next(check for check in checks if check.check_id == "security.identities")
        token = next(check for check in checks if check.check_id == "security.tokens")
        self.assertEqual(identities.status, CheckStatus.FAIL)
        self.assertEqual(token.status, CheckStatus.FAIL)
        self.assertEqual(token.failure_class, FailureClass.PREREQUISITE)


class FakeAapClient:
    def __init__(self, statuses=None):
        self.statuses = list(statuses or [{"status": "successful"}])
        self.launched = []

    def launch_job_template(self, template_id):
        self.launched.append(template_id)
        return template_id + 100

    def job_status(self, job_id):
        del job_id
        return self.statuses.pop(0) if self.statuses else {"status": "successful"}


def ee_inventory(*, second_startable=True):
    return ManagedResourceInventory(
        execution_environments=[
            {"id": 10, "name": "Product Demos EE", "image": "quay.io/ansible-product-demos/apd-ee-27:latest", "available": True},
            {"id": 11, "name": "OPENSHIFT", "image": "registry.redhat.io/ansible-automation-platform-26/ee-supported-rhel8:latest", "available": True},
        ],
        job_templates=[
            {"id": 40, "name": "AAP-Demo Acceptance | Product Demos Read-Only Diagnostic", "execution_environment_id": 10, "can_start": True},
            {"id": 41, "name": "AAP-Demo Acceptance | OpenShift Read-Only Diagnostic", "execution_environment_id": 11, "can_start": second_startable},
        ],
    )


class ExecutionEnvironmentTests(unittest.TestCase):
    def test_enumerates_each_referenced_managed_execution_environment(self):
        supported = execution_environments.enumerate_supported(ee_inventory())

        self.assertEqual([item["id"] for item in supported], [10, 11])
        self.assertEqual(supported[0]["name"], "Product Demos EE")
        self.assertEqual(supported[0]["image"], "quay.io/ansible-product-demos/apd-ee-27:latest")

    def test_runs_one_deterministic_job_per_ee_and_classifies_uncovered_ee_as_contract_drift(self):
        aap = FakeAapClient()
        checks = execution_environments.run(ee_inventory(second_startable=False), aap, FakeRunner({}))

        covered = next(check for check in checks if check.check_id == "ee.10.representative-job")
        uncovered = next(check for check in checks if check.check_id == "ee.11.representative-job")
        self.assertEqual(covered.status, CheckStatus.PASS)
        self.assertEqual(uncovered.status, CheckStatus.FAIL)
        self.assertEqual(uncovered.failure_class, FailureClass.CONTRACT_DRIFT)
        self.assertNotEqual(uncovered.status, CheckStatus.SKIP)
        self.assertEqual(aap.launched, [40])

    def test_classifies_a_representative_job_failure_as_execution(self):
        aap = FakeAapClient([{"status": "failed"}])
        checks = execution_environments.run(ee_inventory(), aap, FakeRunner({}))

        failed = next(check for check in checks if check.check_id == "ee.10.representative-job")
        self.assertEqual(failed.status, CheckStatus.FAIL)
        self.assertEqual(failed.failure_class, FailureClass.EXECUTION)

    def test_rejects_a_product_demos_ee_with_an_unexpected_image(self):
        inventory = ee_inventory()
        inventory.execution_environments[0]["image"] = "quay.io/ansible-product-demos/unexpected:latest"

        checks = execution_environments.run(inventory, FakeAapClient(), FakeRunner({}))

        definition = next(check for check in checks if check.check_id == "ee.10.definition")
        self.assertEqual(definition.status, CheckStatus.FAIL)
        self.assertEqual(definition.failure_class, FailureClass.CONTRACT_DRIFT)

    def test_requires_explicit_ee_availability_evidence(self):
        inventory = ee_inventory()
        inventory.execution_environments[0].pop("available")

        checks = execution_environments.run(inventory, FakeAapClient(), FakeRunner({}))

        definition = next(check for check in checks if check.check_id == "ee.10.definition")
        self.assertEqual(definition.status, CheckStatus.FAIL)
        self.assertEqual(definition.failure_class, FailureClass.CONTRACT_DRIFT)

    def test_never_selects_an_arbitrary_startable_product_demos_installer(self):
        inventory = ee_inventory()
        inventory.job_templates.insert(0, {
            "id": 1,
            "name": "APD | Install Base Resources",
            "execution_environment_id": 10,
            "can_start": True,
        })
        aap = FakeAapClient()

        execution_environments.run(inventory, aap, FakeRunner({}))

        self.assertEqual(aap.launched, [40, 41])

    def test_returns_contract_drift_when_only_an_installer_is_startable(self):
        inventory = ee_inventory()
        inventory.job_templates = [{
            "id": 1,
            "name": "APD | Install Base Resources",
            "execution_environment_id": 10,
            "can_start": True,
        }]
        aap = FakeAapClient()

        checks = execution_environments.run(inventory, aap, FakeRunner({}))

        uncovered = next(check for check in checks if check.check_id == "ee.10.representative-job")
        self.assertEqual(uncovered.failure_class, FailureClass.CONTRACT_DRIFT)
        self.assertEqual(aap.launched, [])

    def test_fails_representative_job_when_a_running_task_pod_cannot_be_observed(self):
        class NoPodRunner(FakeRunner):
            def run(self, args, *, check=False, timeout=60):
                if args[:3] == ["kubectl", "get", "pods"]:
                    self.calls.append(args)
                    return CommandResult(1, "", "no running task pod")
                return super().run(args, check=check, timeout=timeout)

        aap = FakeAapClient()
        checks = execution_environments.run(ee_inventory(), aap, NoPodRunner({}))

        failed = next(check for check in checks if check.check_id == "ee.10.representative-job")
        self.assertEqual(failed.status, CheckStatus.FAIL)
        self.assertEqual(failed.failure_class, FailureClass.PREREQUISITE)

    def test_uses_runner_timeout_and_running_aap_task_selector_for_job_observation(self):
        runner = FakeRunner({})
        runner.timeout_seconds = 19

        execution_environments.run(ee_inventory(), FakeAapClient(), runner)

        pod_command = next(call for call in runner.calls if call[:3] == ["kubectl", "get", "pods"])
        self.assertIn("app.kubernetes.io/name=aap-controller-task", pod_command)
        self.assertIn("--field-selector=status.phase=Running", pod_command)
        self.assertIn(19, runner.timeouts)


if __name__ == "__main__":
    unittest.main()
