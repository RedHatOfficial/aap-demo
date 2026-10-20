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
from checks import execution_environments, security  # noqa: E402


class FakeRunner:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def run(self, args, *, check=False, timeout=60):
        del check, timeout
        self.calls.append(args)
        key = tuple(args)
        return self.responses.get(key, CommandResult(1, "", "unexpected command"))


class ProbeSetTests(unittest.TestCase):
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
        pod = "controller-task-abc"
        curl_args = probes.https_command(f"https://{host}/mcp")
        runner = FakeRunner({
            ("getent", "hosts", host): CommandResult(2, "", "token=do-not-leak DNS failure"),
            (
                "kubectl", "get", "pods", "-n", "aap-operator", "-l", "app=controller-task",
                "-o", "jsonpath={.items[0].metadata.name}",
            ): CommandResult(0, pod, ""),
            tuple(["kubectl", "exec", "-n", "aap-operator", pod, "--", *curl_args]): CommandResult(
                60, "subject=CN=mcp.example.test\n-----BEGIN CERTIFICATE-----\nnot-diagnostic-data", "SSL certificate problem: token=do-not-leak"
            ),
        })
        probe_set = probes.ProbeSet(runner)

        dns = probe_set.host_dns(host)
        pod_https = probe_set.ee_https("aap-operator", "app=controller-task", f"https://{host}/mcp")

        self.assertFalse(dns.ok)
        self.assertFalse(pod_https.ok)
        self.assertNotIn("do-not-leak", dns.error)
        self.assertNotIn("do-not-leak", pod_https.error)
        self.assertNotIn("BEGIN CERTIFICATE", pod_https.error)
        self.assertEqual(pod_https.hostname, host)
        self.assertIn("certificate", pod_https.error.lower())


class SecurityProbeDouble:
    def __init__(self, *, tls_ok=True, dns_ok=True, pod_ok=True, metadata=None):
        self.tls_ok = tls_ok
        self.dns_ok = dns_ok
        self.pod_ok = pod_ok
        self.metadata = metadata or {
            "users": {"admin": True, "automation-orchestrator": True},
            "tokens": {"aap": True, "mcp": True},
            "mcp_tools": ["controller_jobs_list"],
            "private_network_routes": {},
        }
        self.calls = []

    def host_dns(self, host):
        self.calls.append(("dns", host))
        return probes.ProbeResult(self.dns_ok, None, host, None, None, "dns failed" if not self.dns_ok else "")

    def host_https(self, url):
        self.calls.append(("https", url))
        return probes.ProbeResult(self.tls_ok, 200 if self.tls_ok else None, url.split("/")[2], "CN=route", "CN=CA", "tls failed" if not self.tls_ok else "")

    def ee_https(self, namespace, selector, url):
        self.calls.append(("pod", namespace, selector, url))
        return probes.ProbeResult(self.pod_ok, 200 if self.pod_ok else None, url.split("/")[2], "CN=route", "CN=CA", "pod tls failed" if not self.pod_ok else "")

    def security_metadata(self):
        return self.metadata


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
        checks = security.run(security_inventory(), SecurityProbeDouble())

        self.assertTrue(all(check.status == CheckStatus.PASS for check in checks))
        self.assertTrue(any(check.check_id == "security.mcp.tools" for check in checks))
        self.assertTrue(any(check.check_id == "security.private-network.aap-demo-aap" for check in checks))

    def test_security_checks_report_tls_and_missing_token_metadata_as_wiring_failures(self):
        metadata = {
            "users": {"admin": True, "automation-orchestrator": False},
            "tokens": {"aap": True, "mcp": False},
            "mcp_tools": [],
            "private_network_routes": {"aap.example.test": False, "mcp.example.test": False},
        }
        checks = security.run(security_inventory(), SecurityProbeDouble(tls_ok=False, metadata=metadata))

        tls = next(check for check in checks if check.check_id == "security.route.aap-demo-aap.tls")
        token = next(check for check in checks if check.check_id == "security.tokens")
        self.assertEqual(tls.status, CheckStatus.FAIL)
        self.assertEqual(tls.failure_class, FailureClass.PREREQUISITE)
        self.assertEqual(token.status, CheckStatus.FAIL)
        self.assertEqual(token.failure_class, FailureClass.WIRING)


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
            {"id": 40, "name": "APD | Read-only representative", "execution_environment_id": 10, "can_start": True},
            {"id": 41, "name": "APD | Unstartable representative", "execution_environment_id": 11, "can_start": second_startable},
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


if __name__ == "__main__":
    unittest.main()
