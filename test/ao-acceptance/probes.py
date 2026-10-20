"""Redacted network probes for the opt-in AO live acceptance suite."""

from dataclasses import dataclass
import json
from pathlib import Path
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
_AO_SERVICE_ACCOUNT_NAME = "automation-orchestrator"
_POD_HTTPS_SCRIPT = r"""
import json
import ssl
import sys
import urllib.parse
import urllib.request

config = json.load(sys.stdin)
url = config["url"]
hostname = urllib.parse.urlparse(url).hostname or ""
context = ssl.create_default_context(cadata=config.get("ca_pem") or None)
request = urllib.request.Request(url, headers={"Accept": "application/json"})
try:
    with urllib.request.urlopen(request, context=context, timeout=30) as response:
        status = response.status
    print(json.dumps({"ok": 200 <= status < 400, "status": status, "hostname": hostname}))
except Exception:
    print(json.dumps({"ok": False, "status": None, "hostname": hostname, "error": "HTTPS certificate or connectivity probe failed"}))
    raise SystemExit(1)
""".strip()
_POD_MCP_SCRIPT = r"""
import json
import ssl
import sys
import urllib.parse
import urllib.request

config = json.load(sys.stdin)
endpoint = config["endpoint"]
hostname = urllib.parse.urlparse(endpoint).hostname or ""
context = ssl.create_default_context(cadata=config.get("ca_pem") or None)
request = urllib.request.Request(
    endpoint,
    data=json.dumps(config["request"], separators=(",", ":")).encode("utf-8"),
    headers={
        "Accept": "application/json",
        "Authorization": "Bearer " + config["token"],
        "Content-Type": "application/json",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(request, context=context, timeout=30) as response:
        payload = json.loads(response.read(1048576))
    tools = payload.get("result", {}).get("tools", [])
    names = [item.get("name") for item in tools if isinstance(item, dict)]
    valid = bool(names) and all(
        isinstance(name, str) and 0 < len(name) <= 256 for name in names
    )
    print(json.dumps({"ok": valid, "hostname": hostname, "tool_names": names if valid else []}))
    raise SystemExit(0 if valid else 1)
except Exception:
    print(json.dumps({"ok": False, "hostname": hostname, "tool_names": [], "error": "authenticated MCP tools/list probe failed"}))
    raise SystemExit(1)
""".strip()


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


def _pod_probe_result(url: str, returncode: int, stdout: str) -> ProbeResult:
    """Parse only the controlled schema emitted by the in-pod probe."""
    hostname = urlparse(url).hostname or ""
    try:
        payload = json.loads(stdout)
    except (json.JSONDecodeError, TypeError):
        payload = {}
    status = payload.get("status") if isinstance(payload, dict) else None
    if isinstance(status, bool) or not isinstance(status, int):
        status = None
    observed_hostname = payload.get("hostname") if isinstance(payload, dict) else None
    if not isinstance(observed_hostname, str) or observed_hostname != hostname:
        observed_hostname = hostname
    ok = bool(
        returncode == 0
        and isinstance(payload, dict)
        and payload.get("ok") is True
        and status is not None
        and 200 <= status < 400
    )
    error = ""
    if not ok:
        candidate = payload.get("error") if isinstance(payload, dict) else None
        error = candidate if candidate in {
            "HTTPS certificate or connectivity probe failed",
        } else "in-pod HTTPS probe failed without a safe diagnostic"
    return ProbeResult(ok, status, observed_hostname, None, None, error)


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
        ao_service_account_name: str = _AO_SERVICE_ACCOUNT_NAME,
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
        self.ao_service_account_name = ao_service_account_name
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

    def mcp_tools_from_pod(self, namespace: str, selector: str) -> list[str] | None:
        """Run authenticated tools/list in one selected pod with stdin-only secrets."""
        if self.mcp_client is None:
            return None
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
            return None
        ca_pem, ca_error = self._ca_pem()
        if ca_error:
            return None
        try:
            request = self.mcp_client.pod_request(
                "tools/list", {}, ca_pem=ca_pem
            )
        except Exception:
            return None
        result = self.runner.run(
            [
                "kubectl", "exec", "-i", "-n", namespace, pod, "--",
                "python3", "-c", _POD_MCP_SCRIPT,
            ],
            timeout=self.timeout_seconds,
            input_text=json.dumps(request),
        )
        if result.returncode != 0:
            return None
        try:
            payload = json.loads(result.stdout)
        except (json.JSONDecodeError, TypeError):
            return None
        names = payload.get("tool_names") if isinstance(payload, dict) else None
        if payload.get("ok") is not True or not isinstance(names, list):
            return None
        if not names or not all(
            isinstance(name, str) and 0 < len(name) <= 256 for name in names
        ):
            return None
        return names

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
        ca_pem, ca_error = self._ca_pem()
        if ca_error:
            return ProbeResult(
                False, None, urlparse(url).hostname or "", None, None, ca_error
            )
        probe_input = json.dumps({"url": url, "ca_pem": ca_pem})
        result = self.runner.run(
            [
                "kubectl", "exec", "-i", "-n", namespace, pod, "--",
                "python3", "-c", _POD_HTTPS_SCRIPT,
            ],
            timeout=self.timeout_seconds,
            input_text=probe_input,
        )
        return _pod_probe_result(url, result.returncode, result.stdout)

    def aap_ready(self) -> bool:
        return bool(self.aap_url and self.host_https(self.aap_url).ok)

    def ao_ready(self) -> bool:
        return bool(self.ao_url and self.host_https(self.ao_url).ok)

    def mcp_ready(self) -> bool:
        if not self.mcp_url or self.mcp_client is None:
            return False
        try:
            return bool(self.mcp_client.list_tools())
        except Exception:
            return False

    def _ca_pem(self) -> tuple[str, str | None]:
        if not self.ca_file:
            return "", None
        try:
            return Path(self.ca_file).read_text(encoding="utf-8"), None
        except OSError:
            return "", "configured CA file could not be read"

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
        ) if (
            service_account.returncode == 0
            and service_account_name == self.ao_service_account_name
            and service_account_name != "default"
        ) else None
        return {
            "admin": admin,
            "automation-orchestrator": bool(
                account
                and account.returncode == 0
                and account.stdout.strip() == f"serviceaccount/{self.ao_service_account_name}"
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
