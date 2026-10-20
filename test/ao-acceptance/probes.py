"""Redacted network probes for the opt-in AO live acceptance suite."""

from dataclasses import dataclass
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
        ee_selector: str = "app.kubernetes.io/component=execution-environment",
        ao_namespace: str = "automation-orchestrator",
        ao_selector: str = "app.kubernetes.io/component=backend",
        aap_url: str | None = None,
        ao_url: str | None = None,
        mcp_url: str | None = None,
        metadata: dict[str, object] | None = None,
    ):
        self.runner = runner
        self.ca_file = ca_file
        self.timeout_seconds = timeout_seconds
        self.ee_namespace = ee_namespace
        self.ee_selector = ee_selector
        self.ao_namespace = ao_namespace
        self.ao_selector = ao_selector
        self.aap_url = aap_url
        self.ao_url = ao_url
        self.mcp_url = mcp_url
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
        admin = self.runner.run(
            ["kubectl", "get", "secret", "aap-admin-password", "-n", self.ee_namespace, "-o", "name"],
            timeout=self.timeout_seconds,
        )
        service_account = self.runner.run(
            ["kubectl", "get", "deployment", "automation-orchestrator-backend", "-n", self.ao_namespace, "-o", "jsonpath={.spec.template.spec.serviceAccountName}"],
            timeout=self.timeout_seconds,
        )
        return {
            "admin": admin.returncode == 0 and bool(admin.stdout.strip()),
            "automation-orchestrator": service_account.returncode == 0 and bool(service_account.stdout.strip()),
        }

    def token_usable(self, integration: dict) -> bool | None:
        status = integration.get(
            "status", integration.get("validation_status", integration.get("health", integration.get("state")))
        )
        if status is None:
            return None
        return str(status).casefold() in {"available", "healthy", "valid", "ready"}

    def mcp_tools(self, integration: dict) -> list[str] | None:
        tools = integration.get("enabled_tools", integration.get("tools"))
        return [str(tool) for tool in tools] if isinstance(tools, list) else None

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
        return True
