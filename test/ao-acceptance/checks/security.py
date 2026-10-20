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


def _is_private_route(hostname: str) -> bool:
    return hostname.endswith(".nip.io") or hostname.endswith(".crc.testing") or hostname in {"localhost", "127.0.0.1"}


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


def _integration_checks(inventory: ManagedResourceInventory, probes: "ProbeSet") -> list[CheckResult]:
    integrations = {str(item.get("name", "")).casefold(): item for item in inventory.ao_integrations}
    results: list[CheckResult] = []
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
        selectors = getattr(
            probes,
            "ao_selectors",
            (getattr(probes, "ao_selector", "app.kubernetes.io/component=backend"),),
        )
        ao_https = [
            probes.ao_https(getattr(probes, "ao_namespace", "automation-orchestrator"), selector, endpoint)
            for selector in selectors
        ] if callable(getattr(probes, "ao_https", None)) else []
        ao_ok = bool(ao_https) and all(result.ok for result in ao_https)
        results.append(_result(
            f"security.route.{slug}.ao", "tls", ao_ok,
            f"{name} route is trusted from AO backend and worker pods" if ao_ok else f"{name} route is not trusted from every AO backend/worker pod",
            FailureClass.PREREQUISITE,
            details={"hostname": hostname, "contexts": [{"selector": selector, "status": result.status, "error": result.error} for selector, result in zip(selectors, ao_https)]},
        ))
        policy = probes.private_network_ready(hostname) if callable(getattr(probes, "private_network_ready", None)) else None
        private_ok = policy is True
        results.append(_result(
            f"security.private-network.{slug}", "network", private_ok,
            f"{name} private-network route policy is configured" if private_ok else f"{name} private-network route policy is missing",
            FailureClass.WIRING,
            details={"hostname": hostname, "private_route": _is_private_route(hostname)},
        ))
    return results


def _metadata_checks(inventory: ManagedResourceInventory, probes: "ProbeSet") -> list[CheckResult]:
    users = probes.identity_observations() if callable(getattr(probes, "identity_observations", None)) else {}
    users = users if isinstance(users, dict) else {}
    identities_ok = all(users.get(user) is True for user in _REQUIRED_USERS)
    credentials_ok = bool(inventory.credentials) and all(bool(item.get("credential_type_name")) for item in inventory.credentials)
    integrations = {str(item.get("name", "")).casefold(): item for item in inventory.ao_integrations}
    required_integrations = [integrations.get(name.casefold()) for name in _REQUIRED_INTEGRATIONS]
    token_states = [
        probes.token_usable(integration) if integration and callable(getattr(probes, "token_usable", None)) else None
        for integration in required_integrations
    ]
    tokens_ok = all(state is True for state in token_states)
    mcp = next((item for item in inventory.ao_integrations if str(item.get("name", "")).casefold() == "aap-demo mcp server"), None)
    observed_tools = probes.mcp_tools(mcp) if isinstance(mcp, dict) and callable(getattr(probes, "mcp_tools", None)) else None
    observed_tools = observed_tools if isinstance(observed_tools, list) else []
    tools_ok = bool(observed_tools)
    return [
        _result("security.identities", "identity", identities_ok, "required admin and AO service identities are present" if identities_ok else "required admin or AO service identity observation is missing", FailureClass.PREREQUISITE, details={"required_users": list(_REQUIRED_USERS)}),
        _result("security.credentials", "credential", credentials_ok, "managed credentials have expected types" if credentials_ok else "managed credentials or credential types are missing", FailureClass.WIRING, details={"credential_ids": [item.get("id") for item in inventory.credentials]}),
        _result("security.tokens", "token", tokens_ok, "AAP and MCP integration observations confirm usable tokens" if tokens_ok else "AAP or MCP token usability observation is missing or failed", FailureClass.PREREQUISITE, details={"integration_names": list(_REQUIRED_INTEGRATIONS)}),
        _result("security.mcp.tools", "mcp", tools_ok, "at least one enabled MCP tool is reachable" if tools_ok else "no enabled MCP tool observation is available", FailureClass.PREREQUISITE, details={"integration_id": mcp.get("id") if isinstance(mcp, dict) else None, "tool_count": len(observed_tools)}),
    ]


def run(inventory: ManagedResourceInventory, probes: "ProbeSet") -> list[CheckResult]:
    """Validate route trust and redacted wiring metadata without reading secrets."""
    return [*_integration_checks(inventory, probes), *_metadata_checks(inventory, probes)]
