"""Contract tests for redacted AAP and AO acceptance API clients."""

from io import BytesIO
from email.message import Message
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler


ACCEPTANCE_DIR = Path(__file__).parent / "ao-acceptance"
sys.path.insert(0, str(ACCEPTANCE_DIR))

from clients.aap import AapClient  # noqa: E402
from clients.ao import AoClient  # noqa: E402
from clients.http import ApiError, JsonClient  # noqa: E402
from clients.mcp import McpClient  # noqa: E402
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

    def test_redacts_complete_quoted_and_assignment_secret_values_with_whitespace(self):
        secret = "correct horse battery staple"

        json_text = redact_text('{"password":"correct horse battery staple"}')
        assignment_text = redact_text('api_key="correct horse battery staple"')

        self.assertEqual(json_text, '{"password":"[REDACTED]"}')
        self.assertEqual(assignment_text, 'api_key="[REDACTED]"')
        self.assertNotIn(secret, json_text)
        self.assertNotIn(secret, assignment_text)

    def test_preserves_unquoted_assignment_and_query_delimiters(self):
        query_text = redact_text("https://aap.example.test/api?token=abc&status=ok")
        assignment_text = redact_text("token=abc;status=ok")

        self.assertEqual(query_text, "https://aap.example.test/api?token=[REDACTED]&status=ok")
        self.assertEqual(assignment_text, "token=[REDACTED];status=ok")


class JsonClientTests(unittest.TestCase):
    def setUp(self):
        self.context = object()
        self.create_context = patch("clients.http.ssl.create_default_context", return_value=self.context)
        self.create_context.start()
        self.create_opener = patch("clients.http.build_opener")
        self.build_opener = self.create_opener.start()
        self.opener = self.build_opener.return_value
        self.client = JsonClient("https://aap.example.test/", "token-value", ca_file="/tmp/ca.pem")

    def tearDown(self):
        self.create_opener.stop()
        self.create_context.stop()

    def test_opener_uses_the_explicit_ca_context(self):
        handlers = self.build_opener.call_args.args
        https_handler = next(handler for handler in handlers if hasattr(handler, "_context"))

        self.assertIs(https_handler._context, self.context)

    def test_sends_authorized_json_request_and_decodes_response(self):
        self.opener.open.return_value = FakeResponse('{"id": 7}')

        response = self.client.request("POST", "/api/v2/items/", payload={"name": "demo"})

        self.assertEqual(response, {"id": 7})
        request = self.opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://aap.example.test/api/v2/items/")
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.get_header("Authorization"), "Bearer token-value")
        self.assertEqual(request.get_header("Content-type"), "application/json")
        self.assertEqual(request.data, b'{"name":"demo"}')
        self.assertEqual(self.opener.open.call_args.kwargs["timeout"], 60)

    def test_decodes_top_level_json_list_response(self):
        self.opener.open.return_value = FakeResponse('[{"id": "one"}]')

        response = self.client.request("GET", "/api/v1/workflows")

        self.assertEqual(response, [{"id": "one"}])

    def test_non_success_response_raises_redacted_bounded_api_error(self):
        body = b'{"password":"password-value","detail":"Bearer token-value"}' + b"x" * 5000
        self.opener.open.side_effect = HTTPError(
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

    def test_non_success_response_omits_unlabeled_response_values(self):
        # Break caught: key-name redaction cannot identify a secret returned in
        # an ordinary API field, so failure diagnostics must not retain bodies.
        unlabeled_secret = "synthetic-unlabeled-api-secret"
        self.opener.open.side_effect = HTTPError(
            "https://aap.example.test/api/v2/items/",
            500,
            "Server Error",
            hdrs=None,
            fp=BytesIO(f'{{"message":"{unlabeled_secret}"}}'.encode()),
        )

        with self.assertRaises(ApiError) as raised:
            self.client.request("GET", "/api/v2/items/")

        self.assertNotIn(unlabeled_secret, raised.exception.body)
        self.assertNotIn(unlabeled_secret, str(raised.exception))
        self.assertIn("omitted", raised.exception.body)

    def test_invalid_json_and_connection_failures_are_redacted_api_errors(self):
        self.opener.open.return_value = FakeResponse("not-json")

        with self.assertRaises(ApiError) as malformed:
            self.client.request("GET", "/api/v2/items/")

        self.assertIsNone(malformed.exception.status)
        self.assertNotIn("token-value", str(malformed.exception))

        self.opener.open.side_effect = URLError("Bearer token-value")
        with self.assertRaises(ApiError) as unavailable:
            self.client.request("GET", "/api/v2/items/")

        self.assertIsNone(unavailable.exception.status)
        self.assertNotIn("token-value", unavailable.exception.body)
        self.assertIn("[REDACTED]", unavailable.exception.body)

    def test_error_urls_redact_secret_shaped_query_parameters(self):
        self.opener.open.side_effect = URLError("connection refused")

        with self.assertRaises(ApiError) as raised:
            self.client.request("GET", "/api/v2/items/?token=token-value")

        self.assertNotIn("token-value", raised.exception.url)
        self.assertIn("token=[REDACTED]", raised.exception.url)
        self.assertNotIn("token-value", str(raised.exception))

    def test_api_error_redacts_whitespace_secrets_in_url_body_and_message(self):
        secret = "correct horse battery staple"
        error = ApiError(
            "GET",
            "https://aap.example.test/api/v2/items/?token=correct horse battery staple",
            401,
            '{"password":"correct horse battery staple"}',
        )

        self.assertNotIn(secret, error.url)
        self.assertNotIn(secret, error.body)
        self.assertNotIn(secret, str(error))
        self.assertEqual(error.body, '{"password":"[REDACTED]"}')

    def test_cross_origin_redirect_is_not_followed_with_authorization(self):
        redirect_headers = Message()
        redirect_headers["Location"] = "https://evil.example.test/capture"
        redirect = HTTPError(
            "https://aap.example.test/api/v2/items/",
            302,
            "Found",
            redirect_headers,
            BytesIO(b"redirect"),
        )
        self.opener.open.side_effect = redirect

        with self.assertRaises(ApiError) as raised:
            self.client.request("GET", "/api/v2/items/")

        request = self.opener.open.call_args.args[0]
        handlers = self.build_opener.call_args.args
        redirect_handler = next(
            handler for handler in handlers if isinstance(handler, HTTPRedirectHandler)
        )
        self.assertEqual(self.opener.open.call_count, 1)
        self.assertEqual(request.full_url, "https://aap.example.test/api/v2/items/")
        self.assertEqual(request.get_header("Authorization"), "Bearer token-value")
        self.assertEqual(raised.exception.status, 302)
        self.assertIsNone(
            redirect_handler.redirect_request(
                request, None, 302, "Found", redirect_headers, redirect_headers["Location"]
            )
        )


class ResourceClientTests(unittest.TestCase):
    def test_mcp_lists_and_calls_tools_through_authenticated_json_transport(self):
        with patch("clients.http.ssl.create_default_context", return_value=object()):
            client = McpClient(
                "https://mcp.example.test/mcp", "mcp-token", ca_file="/tmp/ca.pem"
            )
        responses = [
            {"jsonrpc": "2.0", "id": "ao-acceptance-tools", "result": {
                "tools": [{"name": "controller.job_templates_list"}],
            }},
            {"jsonrpc": "2.0", "id": "ao-acceptance-call", "result": {
                "content": [{"type": "text", "text": "untrusted response body"}],
                "isError": False,
            }},
        ]

        with patch.object(client._client, "request", side_effect=responses) as request:
            tools = client.list_tools()
            observation = client.call_tool("controller.job_templates_list", {})

        self.assertEqual(tools, ["controller.job_templates_list"])
        self.assertEqual(observation, {
            "tool_name": "controller.job_templates_list",
            "content_types": ["text"],
            "is_error": False,
        })
        self.assertEqual(request.call_args_list[0].args, ("POST", "/mcp"))
        self.assertEqual(
            request.call_args_list[0].kwargs["payload"]["method"], "tools/list"
        )
        self.assertEqual(
            request.call_args_list[1].kwargs["payload"]["method"], "tools/call"
        )

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
            {"results": [{"id": "one"}], "next": None},
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

    def test_ao_list_all_accepts_repository_resources_envelopes(self):
        client = AoClient("https://ao.example.test", "token-value")
        responses = [
            {"resources": [{"id": "one"}], "next": "https://ao.example.test/api/v1/workflows?cursor=next"},
            {"resources": [{"id": "two"}], "next": None},
        ]

        with patch.object(client, "request", side_effect=responses) as request:
            workflows = client.list_all("/api/v1/workflows")

        self.assertEqual(workflows, [{"id": "one"}, {"id": "two"}])
        self.assertEqual(request.call_args_list[0].args, ("GET", "/api/v1/workflows"))
        self.assertEqual(request.call_args_list[1].args, ("GET", "https://ao.example.test/api/v1/workflows?cursor=next"))

    def test_ao_list_all_accepts_a_direct_list_through_json_transport(self):
        client = AoClient("https://ao.example.test", "token-value")
        with patch.object(client._opener, "open", return_value=FakeResponse('[{"id": "one"}]')):
            workflows = client.list_all("/api/v1/workflows")

        self.assertEqual(workflows, [{"id": "one"}])


if __name__ == "__main__":
    unittest.main()
