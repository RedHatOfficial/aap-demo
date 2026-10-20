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
        ee_selector: str = "app.kubernetes.io/name=aap-controller-task",
        metadata: dict[str, object] | None = None,
    ):
        self.runner = runner
        self.ca_file = ca_file
        self.timeout_seconds = timeout_seconds
        self.ee_namespace = ee_namespace
        self.ee_selector = ee_selector
        self._metadata = dict(metadata or {})

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
            return ProbeResult(False, None, hostname, None, None, _error(pod_result.stderr, pod_result.stdout, "no execution-environment pod found"))
        curl_args = https_command(url, ca_file=self.ca_file)
        result = self.runner.run(
            ["kubectl", "exec", "-n", namespace, pod, "--", *curl_args],
            timeout=self.timeout_seconds,
        )
        return _https_result(url, result.returncode, result.stdout, result.stderr)

    def security_metadata(self) -> dict[str, object]:
        """Return caller-supplied booleans only; token values are never read."""
        return dict(self._metadata)
