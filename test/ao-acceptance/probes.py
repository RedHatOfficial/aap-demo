"""Redacted network probes for the opt-in AO live acceptance suite."""

from dataclasses import dataclass
import json
import re
from typing import TYPE_CHECKING
from urllib.parse import urlparse

try:
    from .redaction import redact_text
except ImportError:  # Direct execution via run.sh or python runner.py.
    from redaction import redact_text

if TYPE_CHECKING:
    from .environment import CommandRunner


_CERTIFICATE_FIELD = re.compile(r"(?im)^(?:subject|issuer)\s*[:=]\s*(.+)$")
_ERROR_LIMIT = 1024


@dataclass(frozen=True)
class ProbeResult:
    """The deliberately small, secret-free result of a network probe."""

    ok: bool
    status: int | None
    hostname: str
    certificate_subject: str | None
    certificate_issuer: str | None
    error: str


def https_command(url: str, *, ca_file: str | None = None) -> list[str]:
    """Build a CA-verifying curl invocation without returning response content."""
    args = [
        "curl",
        "--fail",
        "--silent",
        "--show-error",
        "--output",
        "/dev/null",
        "--write-out",
        "\\n%{response_code}\\n%{url.host}\\n%{certs}",
    ]
    if ca_file:
        args.extend(["--cacert", ca_file])
    args.append(url)
    return args


class McpToolsClient:
    """Small injected boundary for an authenticated MCP tools/list request."""

    def __init__(self, runner: "CommandRunner", endpoint: str, token: str, *, ca_file: str | None = None, timeout_seconds: int = 60):
        self.runner = runner
        self.endpoint = endpoint
        self.token = token
        self.ca_file = ca_file
        self.timeout_seconds = timeout_seconds

    def list_tools(self) -> list[str]:
        args = [
            "curl", "--fail", "--silent", "--show-error", "--request", "POST",
            "--header", f"Authorization: Bearer {self.token}",
            "--header", "Content-Type: application/json",
            "--data", '{"jsonrpc":"2.0","id":"ao-acceptance-tools","method":"tools/list","params":{}}',
        ]
        if self.ca_file:
            args.extend(["--cacert", self.ca_file])
        args.append(self.endpoint)
        result = self.runner.run(args, timeout=self.timeout_seconds)
        if result.returncode != 0:
            raise RuntimeError(_error(result.stderr, result.stdout, "MCP tools/list request failed"))
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError("MCP tools/list response was not JSON") from error
        body = payload.get("result", payload) if isinstance(payload, dict) else {}
        tools = body.get("tools") if isinstance(body, dict) else None
        if not isinstance(tools, list):
            raise RuntimeError("MCP tools/list response did not contain tools")
        names = [tool.get("name") if isinstance(tool, dict) else tool for tool in tools]
        if not all(isinstance(name, str) and name for name in names):
            raise RuntimeError("MCP tools/list response contained an invalid tool")
        return names


def _error(*texts: str) -> str:
    return redact_text("\n".join(text for text in texts if text))[:_ERROR_LIMIT]


def _certificate_fields(output: str) -> tuple[str | None, str | None]:
    subject = None
    issuer = None
    for field in _CERTIFICATE_FIELD.finditer(output):
        label = field.group(0).split(field.group(1), 1)[0].casefold()
        if label.startswith("subject"):
            subject = field.group(1).strip()
        elif label.startswith("issuer"):
            issuer = field.group(1).strip()
    return subject, issuer


def _https_result(url: str, returncode: int, stdout: str, stderr: str) -> ProbeResult:
    parsed = urlparse(url)
    hostname = parsed.hostname or ""
    status = None
    for line in stdout.splitlines():
        if line.isdigit() and len(line) == 3:
            status = int(line)
            break
    subject, issuer = _certificate_fields(stdout)
    ok = returncode == 0 and status is not None and 200 <= status < 400
    error = _error(stderr)
    if not error and not ok:
        error = "HTTPS request failed without a safe diagnostic"
    return ProbeResult(ok, status, hostname, subject, issuer, "" if ok else error)


class ProbeSet:
    """Use injected command execution for host and in-cluster network probes."""

    def __init__(
        self,
        runner: "CommandRunner",
        *,
        ca_file: str | None = None,
        timeout_seconds: int = 60,
        ee_namespace: str = "aap-operator",
        ee_selector: str = "app.kubernetes.io/name=aap-controller-task",
        ao_namespace: str = "automation-orchestrator",
        ao_selector: str = "app.kubernetes.io/component=backend",
        ao_selectors: tuple[str, ...] | None = None,
        aap_url: str | None = None,
        ao_url: str | None = None,
        mcp_url: str | None = None,
        aap_client=None,
        ao_client=None,
        mcp_client=None,
        metadata: dict[str, object] | None = None,
    ):
        self.runner = runner
        self.ca_file = ca_file
        self.timeout_seconds = timeout_seconds
        self.ee_namespace = ee_namespace
        self.ee_selector = ee_selector
        self.ao_namespace = ao_namespace
        self.ao_selector = ao_selector
        self.ao_selectors = ao_selectors or (
            "app.kubernetes.io/component=backend",
            "app.kubernetes.io/component=worker",
        )
        self.aap_url = aap_url
        self.ao_url = ao_url
        self.mcp_url = mcp_url
        self.aap_client = aap_client
        self.ao_client = ao_client
        self.mcp_client = mcp_client
        del metadata  # Legacy constructor input is deliberately not an observation.

    def host_dns(self, host: str) -> ProbeResult:
        result = self.runner.run(["getent", "hosts", host], timeout=self.timeout_seconds)
        return ProbeResult(
            result.returncode == 0 and bool(result.stdout.strip()),
            None,
            host,
            None,
            None,
            "" if result.returncode == 0 and result.stdout.strip() else _error(result.stderr, result.stdout),
        )

    def host_https(self, url: str) -> ProbeResult:
        result = self.runner.run(https_command(url, ca_file=self.ca_file), timeout=self.timeout_seconds)
        return _https_result(url, result.returncode, result.stdout, result.stderr)

    def ee_https(self, namespace: str, selector: str, url: str) -> ProbeResult:
        return self._pod_https(namespace, selector, url, "execution-environment")

    def ao_https(self, namespace: str, selector: str, url: str) -> ProbeResult:
        return self._pod_https(namespace, selector, url, "AO backend/worker")

    def _pod_https(self, namespace: str, selector: str, url: str, pod_kind: str) -> ProbeResult:
        pod_result = self.runner.run(
            [
                "kubectl", "get", "pods", "-n", namespace, "-l", selector,
                "--field-selector=status.phase=Running",
                "-o", "jsonpath={.items[0].metadata.name}",
            ],
            timeout=self.timeout_seconds,
        )
        pod = pod_result.stdout.strip()
        if pod_result.returncode != 0 or not pod:
            hostname = urlparse(url).hostname or ""
            return ProbeResult(False, None, hostname, None, None, _error(pod_result.stderr, pod_result.stdout, f"no {pod_kind} pod found"))
        curl_args = https_command(url, ca_file=self.ca_file)
        result = self.runner.run(
            ["kubectl", "exec", "-n", namespace, pod, "--", *curl_args],
            timeout=self.timeout_seconds,
        )
        return _https_result(url, result.returncode, result.stdout, result.stderr)

    def aap_ready(self) -> bool:
        return bool(self.aap_url and self.host_https(self.aap_url).ok)

    def ao_ready(self) -> bool:
        return bool(self.ao_url and self.host_https(self.ao_url).ok)

    def mcp_ready(self) -> bool:
        return bool(self.mcp_url and self.host_https(self.mcp_url).ok)

    def identity_observations(self) -> dict[str, bool]:
        admin = self._aap_admin_identity()
        service_account = self.runner.run(
            ["kubectl", "get", "deployment", "automation-orchestrator-backend", "-n", self.ao_namespace, "-o", "jsonpath={.spec.template.spec.serviceAccountName}"],
            timeout=self.timeout_seconds,
        )
        service_account_name = service_account.stdout.strip()
        account = self.runner.run(
            ["kubectl", "get", "serviceaccount", service_account_name, "-n", self.ao_namespace, "-o", "name"],
            timeout=self.timeout_seconds,
        ) if service_account.returncode == 0 and service_account_name else None
        return {
            "admin": admin,
            "automation-orchestrator": bool(
                account and account.returncode == 0 and account.stdout.strip()
            ),
        }

    def token_usable(self, integration: dict) -> bool | None:
        name = str(integration.get("name", "")).casefold()
        if name == "aap-demo aap":
            return self._aap_admin_identity()
        if name != "aap-demo mcp server" or self.mcp_client is None:
            return None
        try:
            self.mcp_client.list_tools()
        except Exception:
            return False
        return True

    def mcp_tools(self, integration: dict) -> list[str] | None:
        del integration
        if self.mcp_client is None:
            return None
        try:
            return self.mcp_client.list_tools()
        except Exception:
            return None

    def _aap_admin_identity(self) -> bool:
        if self.aap_client is None:
            return False
        try:
            payload = self.aap_client.get("/api/gateway/v1/me/")
        except Exception:
            return False
        if not isinstance(payload, dict):
            return False
        username = payload.get("username", payload.get("user", payload.get("name")))
        if isinstance(username, dict):
            username = username.get("username", username.get("name"))
        return isinstance(username, str) and username.casefold() == "admin"

    def private_network_ready(self, hostname: str) -> bool | None:
        for deployment in ("automation-orchestrator-backend", "automation-orchestrator-worker"):
            result = self.runner.run(
                ["kubectl", "get", "deployment", deployment, "-n", self.ao_namespace, "-o", "jsonpath={.spec.template.spec.containers[0].env[?(@.name==\"APP_INTEGRATION_URL_ALLOWED_HOSTS\")].value}"],
                timeout=self.timeout_seconds,
            )
            if result.returncode != 0:
                return None
            if hostname not in result.stdout:
                return False
            if hostname.endswith((".nip.io", ".crc.testing")) or hostname in {"localhost", "127.0.0.1"}:
                aliases = self.runner.run(
                    ["kubectl", "get", "deployment", deployment, "-n", self.ao_namespace, "-o", "jsonpath={.spec.template.spec.hostAliases[*].hostnames[*]}"],
                    timeout=self.timeout_seconds,
                )
                if aliases.returncode != 0:
                    return None
                if hostname not in aliases.stdout:
                    return False
        return True
