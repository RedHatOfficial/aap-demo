"""TLS, identity, token, integration, and MCP contract checks."""

from datetime import UTC, datetime
from typing import TYPE_CHECKING
from urllib.parse import urlparse

try:
    from ..inventory import ManagedResourceInventory
    from ..model import CheckResult, CheckStatus, FailureClass
except ImportError:  # Direct execution via run.sh or python runner.py.
    from inventory import ManagedResourceInventory
    from model import CheckResult, CheckStatus, FailureClass

if TYPE_CHECKING:
    from ..probes import ProbeSet


_REQUIRED_INTEGRATIONS = ("aap-demo AAP", "aap-demo MCP Server")
_REQUIRED_USERS = ("admin", "automation-orchestrator")


def _slug(value: str) -> str:
    return "-".join("".join(character if character.isalnum() else " " for character in value.casefold()).split())


def _result(check_id: str, component: str, valid: bool, summary: str, failure_class: FailureClass | None, *, details: dict[str, object]) -> CheckResult:
    now = datetime.now(UTC).isoformat()
    return CheckResult(
        check_id=check_id,
        component=component,
        status=CheckStatus.PASS if valid else CheckStatus.FAIL,
        failure_class=None if valid else failure_class,
        summary=summary,
        started_at=now,
        finished_at=now,
        duration_seconds=0.0,
        details=details,
    )


def _is_private_route(hostname: str) -> bool:
    return hostname.endswith(".nip.io") or hostname.endswith(".crc.testing") or hostname in {"localhost", "127.0.0.1"}


def _integration_checks(inventory: ManagedResourceInventory, probes: "ProbeSet", metadata: dict[str, object]) -> list[CheckResult]:
    integrations = {str(item.get("name", "")).casefold(): item for item in inventory.ao_integrations}
    results: list[CheckResult] = []
    private_routes = metadata.get("private_network_routes", {})
    private_routes = private_routes if isinstance(private_routes, dict) else {}
    for name in _REQUIRED_INTEGRATIONS:
        integration = integrations.get(name.casefold())
        slug = _slug(name)
        endpoint = str(integration.get("endpoint", "")) if integration else ""
        hostname = urlparse(endpoint).hostname or ""
        configured = bool(integration) and bool(endpoint) and integration.get("enabled") is not False and bool(integration.get("credential_id"))
        results.append(_result(
            f"security.integration.{slug}", "integration", configured,
            f"{name} has an enabled endpoint and credential" if configured else f"{name} is missing an endpoint, credential, or enabled state",
            FailureClass.WIRING,
            details={"name": name, "resource_id": integration.get("id") if integration else None, "hostname": hostname},
        ))
        if not hostname:
            continue
        dns = probes.host_dns(hostname)
        results.append(_result(
            f"security.route.{slug}.dns", "tls", dns.ok,
            f"{name} route hostname resolves" if dns.ok else f"{name} route hostname does not resolve",
            FailureClass.PREREQUISITE,
            details={"hostname": hostname, "error": dns.error},
        ))
        https = probes.host_https(endpoint)
        results.append(_result(
            f"security.route.{slug}.tls", "tls", https.ok,
            f"{name} route is trusted over HTTPS" if https.ok else f"{name} route HTTPS trust failed",
            FailureClass.PREREQUISITE,
            details={"hostname": https.hostname, "status": https.status, "certificate_subject": https.certificate_subject, "certificate_issuer": https.certificate_issuer, "error": https.error},
        ))
        pod_https = probes.ee_https(
            getattr(probes, "ee_namespace", "aap-operator"),
            getattr(probes, "ee_selector", "app.kubernetes.io/name=aap-controller-task"),
            endpoint,
        )
        results.append(_result(
            f"security.route.{slug}.pod", "tls", pod_https.ok,
            f"{name} route is trusted from an execution-environment pod" if pod_https.ok else f"{name} route is not trusted from an execution-environment pod",
            FailureClass.PREREQUISITE,
            details={"hostname": pod_https.hostname, "status": pod_https.status, "certificate_subject": pod_https.certificate_subject, "certificate_issuer": pod_https.certificate_issuer, "error": pod_https.error},
        ))
        private_ok = bool(private_routes.get(hostname, not _is_private_route(hostname)))
        results.append(_result(
            f"security.private-network.{slug}", "network", private_ok,
            f"{name} private-network route policy is configured" if private_ok else f"{name} private-network route policy is missing",
            FailureClass.WIRING,
            details={"hostname": hostname, "private_route": _is_private_route(hostname)},
        ))
    return results


def _metadata_checks(inventory: ManagedResourceInventory, metadata: dict[str, object]) -> list[CheckResult]:
    users = metadata.get("users", {})
    users = users if isinstance(users, dict) else {}
    identities_ok = all(users.get(user) is True for user in _REQUIRED_USERS)
    credentials_ok = bool(inventory.credentials) and all(bool(item.get("credential_type_name")) for item in inventory.credentials)
    tokens = metadata.get("tokens", {})
    tokens = tokens if isinstance(tokens, dict) else {}
    tokens_ok = tokens.get("aap") is True and tokens.get("mcp") is True
    mcp = next((item for item in inventory.ao_integrations if str(item.get("name", "")).casefold() == "aap-demo mcp server"), None)
    configured_tools = mcp.get("enabled_tools", mcp.get("tools", [])) if isinstance(mcp, dict) else []
    configured_tools = configured_tools if isinstance(configured_tools, list) else []
    observed_tools = metadata.get("mcp_tools", [])
    observed_tools = observed_tools if isinstance(observed_tools, list) else []
    tools_ok = bool(configured_tools) and bool(observed_tools) and bool(set(map(str, configured_tools)).intersection(map(str, observed_tools)))
    return [
        _result("security.identities", "identity", identities_ok, "required admin and AO service identities are present" if identities_ok else "required admin or AO service identity is missing", FailureClass.WIRING, details={"required_users": list(_REQUIRED_USERS)}),
        _result("security.credentials", "credential", credentials_ok, "managed credentials have expected types" if credentials_ok else "managed credentials or credential types are missing", FailureClass.WIRING, details={"credential_ids": [item.get("id") for item in inventory.credentials]}),
        _result("security.tokens", "token", tokens_ok, "AAP and MCP token metadata confirms usable tokens" if tokens_ok else "AAP or MCP token metadata is missing or unusable", FailureClass.WIRING, details={"token_names": ["aap", "mcp"]}),
        _result("security.mcp.tools", "mcp", tools_ok, "at least one enabled MCP tool is reachable" if tools_ok else "no enabled MCP tool is confirmed reachable", FailureClass.WIRING, details={"integration_id": mcp.get("id") if isinstance(mcp, dict) else None, "tool_count": len(observed_tools)}),
    ]


def run(inventory: ManagedResourceInventory, probes: "ProbeSet") -> list[CheckResult]:
    """Validate route trust and redacted wiring metadata without reading secrets."""
    metadata = probes.security_metadata() if callable(getattr(probes, "security_metadata", None)) else {}
    metadata = metadata if isinstance(metadata, dict) else {}
    return [*_integration_checks(inventory, probes, metadata), *_metadata_checks(inventory, metadata)]
