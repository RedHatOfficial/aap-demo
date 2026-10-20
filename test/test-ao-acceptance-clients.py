"""Contract tests for redacted AAP and AO acceptance API clients."""

from io import BytesIO
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError


ACCEPTANCE_DIR = Path(__file__).parent / "ao-acceptance"
sys.path.insert(0, str(ACCEPTANCE_DIR))

from clients.aap import AapClient  # noqa: E402
from clients.ao import AoClient  # noqa: E402
from clients.http import ApiError, JsonClient  # noqa: E402
from redaction import redact, redact_text  # noqa: E402


class FakeResponse:
    def __init__(self, body, status=200):
        self.body = body.encode("utf-8")
        self.status = status

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False


class RedactionTests(unittest.TestCase):
    def test_redacts_secret_shaped_keys_without_mutating_safe_values(self):
        original = {
            "token": "token-value",
            "password": "password-value",
            "nested": {"secret": "secret-value", "api_key": "key-value"},
            "safe": "visible",
        }

        sanitized = redact(original)

        self.assertEqual(sanitized["token"], "[REDACTED]")
        self.assertEqual(sanitized["password"], "[REDACTED]")
        self.assertEqual(sanitized["nested"]["secret"], "[REDACTED]")
        self.assertEqual(sanitized["nested"]["api_key"], "[REDACTED]")
        self.assertEqual(sanitized["safe"], "visible")
        self.assertEqual(original["token"], "token-value")

    def test_redacts_bearer_tokens_in_text(self):
        sanitized = redact_text("Authorization: Bearer token-value; next")

        self.assertEqual(sanitized, "Authorization: Bearer [REDACTED]; next")


class JsonClientTests(unittest.TestCase):
    def setUp(self):
        self.create_context = patch("clients.http.ssl.create_default_context", return_value=object())
        self.create_context.start()
        self.client = JsonClient("https://aap.example.test/", "token-value", ca_file="/tmp/ca.pem")

    def tearDown(self):
        self.create_context.stop()

    @patch("clients.http.urlopen")
    def test_sends_authorized_json_request_and_decodes_response(self, urlopen):
        urlopen.return_value = FakeResponse('{"id": 7}')

        response = self.client.request("POST", "/api/v2/items/", payload={"name": "demo"})

        self.assertEqual(response, {"id": 7})
        request = urlopen.call_args.args[0]
        self.assertEqual(request.full_url, "https://aap.example.test/api/v2/items/")
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.get_header("Authorization"), "Bearer token-value")
        self.assertEqual(request.get_header("Content-type"), "application/json")
        self.assertEqual(request.data, b'{"name":"demo"}')
        self.assertEqual(urlopen.call_args.kwargs["timeout"], 60)
        self.assertIsNotNone(urlopen.call_args.kwargs["context"])

    @patch("clients.http.urlopen")
    def test_non_success_response_raises_redacted_bounded_api_error(self, urlopen):
        body = b'{"password":"password-value","detail":"Bearer token-value"}' + b"x" * 5000
        urlopen.side_effect = HTTPError(
            "https://aap.example.test/api/v2/items/",
            401,
            "Unauthorized",
            hdrs=None,
            fp=BytesIO(body),
        )

        with self.assertRaises(ApiError) as raised:
            self.client.request("GET", "/api/v2/items/")

        error = raised.exception
        self.assertEqual(error.method, "GET")
        self.assertEqual(error.status, 401)
        self.assertNotIn("password-value", error.body)
        self.assertNotIn("token-value", error.body)
        self.assertIn("[REDACTED]", error.body)
        self.assertLessEqual(len(error.body), 4096)

    @patch("clients.http.urlopen")
    def test_invalid_json_and_connection_failures_are_redacted_api_errors(self, urlopen):
        urlopen.return_value = FakeResponse("not-json")

        with self.assertRaises(ApiError) as malformed:
            self.client.request("GET", "/api/v2/items/")

        self.assertIsNone(malformed.exception.status)
        self.assertNotIn("token-value", str(malformed.exception))

        urlopen.side_effect = URLError("Bearer token-value")
        with self.assertRaises(ApiError) as unavailable:
            self.client.request("GET", "/api/v2/items/")

        self.assertIsNone(unavailable.exception.status)
        self.assertNotIn("token-value", unavailable.exception.body)
        self.assertIn("[REDACTED]", unavailable.exception.body)

    @patch("clients.http.urlopen")
    def test_error_urls_redact_secret_shaped_query_parameters(self, urlopen):
        urlopen.side_effect = URLError("connection refused")

        with self.assertRaises(ApiError) as raised:
            self.client.request("GET", "/api/v2/items/?token=token-value")

        self.assertNotIn("token-value", raised.exception.url)
        self.assertIn("token=[REDACTED]", raised.exception.url)
        self.assertNotIn("token-value", str(raised.exception))


class ResourceClientTests(unittest.TestCase):
    def test_aap_follows_next_links_and_launches_numeric_job_templates(self):
        client = AapClient("https://aap.example.test", "token-value")
        responses = [
            {"results": [{"id": 1}], "next": "https://aap.example.test/api/v2/job_templates/?page=2"},
            {"results": [{"id": 2}], "next": None},
            {"id": 83},
            {"id": 83, "status": "successful"},
        ]
        with patch.object(client, "request", side_effect=responses) as request:
            items = client.list_all("/api/v2/job_templates/")
            job_id = client.launch_job_template(42, {"secret": "value"})
            status = client.job_status(83)

        self.assertEqual(items, [{"id": 1}, {"id": 2}])
        self.assertEqual(job_id, 83)
        self.assertEqual(status["status"], "successful")
        self.assertEqual(request.call_args_list[0].args, ("GET", "/api/v2/job_templates/"))
        self.assertEqual(request.call_args_list[1].args, ("GET", "https://aap.example.test/api/v2/job_templates/?page=2"))
        self.assertEqual(request.call_args_list[2].args, ("POST", "/api/v2/job_templates/42/launch/"))
        self.assertEqual(request.call_args_list[2].kwargs["payload"], {"extra_vars": {"secret": "value"}})
        self.assertEqual(request.call_args_list[3].args, ("GET", "/api/v2/jobs/83/"))

    def test_ao_normalizes_lists_and_exposes_workflow_status(self):
        client = AoClient("https://ao.example.test", "token-value")
        responses = [
            [{"id": "one"}],
            {"id": "execution-7"},
            {"id": "execution-7", "status": "completed"},
        ]
        with patch.object(client, "request", side_effect=responses) as request:
            workflows = client.list_all("/api/v1/workflows")
            execution_id = client.launch_workflow("workflow-3", {"token": "value"})
            status = client.workflow_status("execution-7")

        self.assertEqual(workflows, [{"id": "one"}])
        self.assertEqual(execution_id, "execution-7")
        self.assertEqual(status["status"], "completed")
        self.assertEqual(request.call_args_list[0].args, ("GET", "/api/v1/workflows"))
        self.assertEqual(request.call_args_list[1].args, ("POST", "/api/v1/workflows/workflow-3/launch"))
        self.assertEqual(request.call_args_list[1].kwargs["payload"], {"inputs": {"token": "value"}})
        self.assertEqual(request.call_args_list[2].args, ("GET", "/api/v1/executions/execution-7"))


if __name__ == "__main__":
    unittest.main()
