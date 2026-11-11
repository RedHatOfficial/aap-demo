#!/usr/bin/env python3
"""Read-only live smoke test for AO UI assets and imported automation content."""

from __future__ import annotations

import base64
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
import ssl
import subprocess
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


AO_NAMESPACE = os.environ.get("AO_NAMESPACE", "automation-orchestrator")
AAP_NAMESPACE = os.environ.get("NAMESPACE", "aap-operator")
KUBECONFIG = os.environ.get(
    "KUBECONFIG",
    os.path.expanduser("~/.aap-demo/kubeconfig.microshift"),
)
SSL_CONTEXT = ssl.create_default_context()
SSL_CONTEXT.check_hostname = False
SSL_CONTEXT.verify_mode = ssl.CERT_NONE

EXPECTED_AO_WORKFLOW_SOURCES = {
    "cert-demo-101-manual.json",
    "cert-demo-101-webhook.json",
    "disk-demo-101.json",
    "disk-demo-tier-switch.json",
    "multi-os-cloud-patching.json",
    "rhel-cve-remediation-legacy.json",
    "rhel-cve-remediation.json",
    "snow-disk-autoremediate.json",
    "snow-incident-response.json",
    "ticket-enrichment.json",
}
EXPECTED_AAP_TEMPLATES = {
    "CVE - Fetch and Commit",
    "CVE - Notify Mattermost Investigation",
    "CVE - Sync and Deploy Remediation",
    "Disk Utilization Check",
    "Disk Utilization - Fallback",
    "Incidents | Capacity - Disk Cleanup",
    "Incidents | High CPU - Process Cleanup",
    "Incidents | Update Ticket",
    "Linux - Remediate - Continue",
    "Linux - Remediate - Disk Cleanup",
    "Linux - Remediate - Disk Expand",
    "Notify Chatroom",
    "Notify Mattermost",
    "Renew Certificate",
    "Renew Java Keystore Certificate",
    "SNOW - Auto Remediation",
    "Validate Cert Renewal",
}
EXPECTED_INTEGRATIONS = {
    "aap-demo AAP": "ansible_automation_platform",
    "aap-demo MCP Server": "mcp_server",
}


class SmokeFailure(RuntimeError):
    pass


def kubectl(*args: str) -> str:
    env = os.environ.copy()
    env["KUBECONFIG"] = KUBECONFIG
    result = subprocess.run(
        ["kubectl", *args],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    if result.returncode:
        message = result.stderr.strip() or result.stdout.strip()
        raise SmokeFailure(f"kubectl {' '.join(args[:3])} failed: {message}")
    return result.stdout.strip()


def secret(namespace: str, name: str) -> str:
    encoded = kubectl(
        "get",
        "secret",
        name,
        "-n",
        namespace,
        "-o",
        "jsonpath={.data.password}",
    )
    if not encoded:
        raise SmokeFailure(f"secret {namespace}/{name} has no password key")
    return base64.b64decode(encoded).decode()


def request(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: dict[str, Any] | None = None,
) -> tuple[int, str, bytes]:
    request_headers = dict(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        request_headers["Content-Type"] = "application/json"
    req = Request(url, data=data, headers=request_headers, method=method)
    try:
        with urlopen(req, context=SSL_CONTEXT, timeout=30) as response:
            return (
                response.status,
                response.headers.get("Content-Type", ""),
                response.read(),
            )
    except HTTPError as exc:
        raise SmokeFailure(f"{method} {url} returned HTTP {exc.code}") from exc
    except URLError as exc:
        raise SmokeFailure(f"{method} {url} failed: {exc.reason}") from exc


def request_json(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: dict[str, Any] | None = None,
) -> dict[str, Any]:
    status, content_type, content = request(
        url,
        method=method,
        headers=headers,
        body=body,
    )
    if status != 200:
        raise SmokeFailure(f"{method} {url} returned HTTP {status}")
    if "json" not in content_type:
        raise SmokeFailure(f"{method} {url} returned {content_type}, expected JSON")
    try:
        parsed = json.loads(content)
    except json.JSONDecodeError as exc:
        raise SmokeFailure(f"{method} {url} returned malformed JSON") from exc
    if not isinstance(parsed, dict):
        raise SmokeFailure(f"{method} {url} returned an unexpected JSON shape")
    return parsed


def list_items(document: dict[str, Any]) -> list[dict[str, Any]]:
    value = document.get("resources", document.get("results", []))
    if not isinstance(value, list):
        raise SmokeFailure("API list response did not contain resources or results")
    return [item for item in value if isinstance(item, dict)]


def route(namespace: str, name: str | None = None) -> str:
    args = ["get", "route"]
    if name:
        args.append(name)
        jsonpath = "jsonpath={.spec.host}"
    else:
        jsonpath = "jsonpath={.items[0].spec.host}"
    host = kubectl(*args, "-n", namespace, "-o", jsonpath)
    if not host:
        raise SmokeFailure(f"no route found in namespace {namespace}")
    return host


def validate_ui_assets(ao_base: str) -> int:
    status, content_type, _ = request(f"{ao_base}/")
    if status != 200 or "text/html" not in content_type:
        raise SmokeFailure(
            f"AO root returned HTTP {status} with {content_type}, expected HTML"
        )

    output = kubectl(
        "exec",
        "-n",
        AO_NAMESPACE,
        "deployment/automation-orchestrator-ui",
        "-c",
        "ui",
        "--",
        "sh",
        "-c",
        "find /opt/app-root/src -type f -name '*.js' "
        "| sed 's#^/opt/app-root/src/##'",
    )
    assets = sorted({line.strip() for line in output.splitlines() if line.strip()})
    if not assets:
        raise SmokeFailure("AO UI container did not contain JavaScript assets")

    def check_asset(path: str) -> str | None:
        url = f"{ao_base}/{quote(path, safe='/')}"
        try:
            req = Request(url, method="HEAD")
            with urlopen(req, context=SSL_CONTEXT, timeout=30) as response:
                content_type = response.headers.get("Content-Type", "")
                if response.status != 200:
                    return f"{path}: HTTP {response.status}"
                if "javascript" not in content_type:
                    return f"{path}: unexpected Content-Type {content_type}"
        except (HTTPError, URLError) as exc:
            return f"{path}: {exc}"
        return None

    failures: list[str] = []
    with ThreadPoolExecutor(max_workers=12) as executor:
        futures = {executor.submit(check_asset, asset): asset for asset in assets}
        for future in as_completed(futures):
            failure = future.result()
            if failure:
                failures.append(failure)
    if failures:
        details = "\n  ".join(sorted(failures)[:20])
        raise SmokeFailure(f"{len(failures)} AO UI asset(s) failed:\n  {details}")
    return len(assets)


def validate_ao_content(ao_base: str) -> tuple[int, int, int]:
    password = secret(
        AO_NAMESPACE,
        "automation-orchestrator-initial-admin-password",
    )
    login = request_json(
        f"{ao_base}/api/v1/auth/login",
        method="POST",
        body={"username": "admin", "password": password},
    )
    token = login.get("access_token")
    if not isinstance(token, str) or not token:
        raise SmokeFailure("AO login did not return an access token")
    headers = {"Authorization": f"Bearer {token}"}

    integrations = list_items(
        request_json(f"{ao_base}/api/v1/integrations?limit=100", headers=headers)
    )
    by_name = {item.get("name"): item for item in integrations}
    for name, integration_type in EXPECTED_INTEGRATIONS.items():
        integration = by_name.get(name)
        if not integration:
            raise SmokeFailure(f"required AO integration is missing: {name}")
        if integration.get("integration_type") != integration_type:
            raise SmokeFailure(f"AO integration has wrong type: {name}")
        if integration.get("enabled") is not True:
            raise SmokeFailure(f"AO integration is disabled: {name}")
        if integration.get("validation_status") != "available":
            raise SmokeFailure(
                f"AO integration is not available: {name} "
                f"({integration.get('validation_status')})"
            )
    mcp = by_name["aap-demo MCP Server"]
    if int(mcp.get("enabled_tool_count") or 0) < 1:
        raise SmokeFailure("aap-demo MCP Server has no enabled tools")
    mcp_integration_id = mcp.get("id")
    if not mcp_integration_id:
        raise SmokeFailure("aap-demo MCP Server has no integration ID")

    credentials = list_items(
        request_json(f"{ao_base}/api/v1/credentials?limit=100", headers=headers)
    )
    mcp_credential = next(
        (
            item
            for item in credentials
            if item.get("name") == "aap-demo MCP Token"
        ),
        None,
    )
    if not mcp_credential or not mcp_credential.get("id"):
        raise SmokeFailure("required AO credential is missing: aap-demo MCP Token")
    mcp_credential_id = mcp_credential["id"]

    workflows = list_items(
        request_json(f"{ao_base}/api/v1/workflows?limit=100", headers=headers)
    )
    sources = {
        item.get("labels", {}).get("source_file")
        for item in workflows
        if item.get("labels", {}).get("aap-demo") == "true"
    }
    missing = EXPECTED_AO_WORKFLOW_SOURCES - sources
    if missing:
        raise SmokeFailure(
            "AO demo workflows are missing: " + ", ".join(sorted(missing))
        )

    agent_count = 0
    for workflow in workflows:
        labels = workflow.get("labels", {})
        if labels.get("source_file") not in EXPECTED_AO_WORKFLOW_SOURCES:
            continue
        workflow_id = workflow.get("id")
        if not workflow_id:
            raise SmokeFailure(f"AO workflow has no ID: {workflow.get('name')}")
        detail = request_json(
            f"{ao_base}/api/v1/workflows/{workflow_id}",
            headers=headers,
        )
        version = detail.get("version", {})
        definition = (
            version.get("workflow_definition", {})
            if isinstance(version, dict)
            else {}
        )
        nodes = definition.get("nodes", [])
        if not isinstance(nodes, list):
            raise SmokeFailure(
                f"AO workflow has an invalid node definition: {workflow.get('name')}"
            )
        for node in nodes:
            if not isinstance(node, dict) or node.get("type") != "agentic":
                continue
            parameters = node.get("parameters", {})
            if not isinstance(parameters, dict) or not parameters.get(
                "tool_selection_strategy"
            ):
                continue
            agent_count += 1
            connections = parameters.get("integration_connections", [])
            if not isinstance(connections, list) or not any(
                isinstance(connection, dict)
                and str(connection.get("integration_id"))
                == str(mcp_integration_id)
                and str(connection.get("credential_id"))
                == str(mcp_credential_id)
                for connection in connections
            ):
                raise SmokeFailure(
                    "AO agent node is missing its MCP credential connection: "
                    f"{workflow.get('name')} / {node.get('name') or node.get('id')}"
                )
    if agent_count < 1:
        raise SmokeFailure("AO demo workflows contain no tool-using agent nodes")
    return len(EXPECTED_INTEGRATIONS), len(sources), agent_count


def validate_aap_templates(aap_base: str) -> int:
    password = secret(AAP_NAMESPACE, "aap-admin-password")
    authorization = base64.b64encode(f"admin:{password}".encode()).decode()
    headers = {"Authorization": f"Basic {authorization}"}
    query = urlencode({"name": "AAP Orchestrator Demos"})
    projects = list_items(
        request_json(
            f"{aap_base}/api/controller/v2/projects/?{query}",
            headers=headers,
        )
    )
    project = next(
        (item for item in projects if item.get("name") == "AAP Orchestrator Demos"),
        None,
    )
    if not project or not project.get("id"):
        raise SmokeFailure("AAP Orchestrator Demos project is missing")
    templates = list_items(
        request_json(
            f"{aap_base}/api/controller/v2/job_templates/"
            f"?project={project['id']}&page_size=100",
            headers=headers,
        )
    )
    names = {item.get("name") for item in templates}
    missing = EXPECTED_AAP_TEMPLATES - names
    if missing:
        raise SmokeFailure(
            "AAP Orchestrator job templates are missing: "
            + ", ".join(sorted(missing))
        )
    return len(names)


def main() -> int:
    if os.environ.get("AAP_DEMO_LIVE_AO_TEST") != "1":
        print(
            "ERROR: Set AAP_DEMO_LIVE_AO_TEST=1 to run against the live cluster.",
            file=sys.stderr,
        )
        return 2
    try:
        kubectl("cluster-info", "--request-timeout=10s")
        ao_base = f"https://{route(AO_NAMESPACE)}"
        aap_base = f"https://{route(AAP_NAMESPACE, 'aap')}"
        asset_count = validate_ui_assets(ao_base)
        integration_count, workflow_count, agent_count = validate_ao_content(ao_base)
        template_count = validate_aap_templates(aap_base)
    except SmokeFailure as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    print(f"PASS: {asset_count} AO JavaScript assets return JavaScript")
    print(f"PASS: {integration_count} required AO integrations are available")
    print(f"PASS: {workflow_count} AO demo workflows are imported")
    print(f"PASS: {agent_count} AO agent nodes have MCP credential connections")
    print(f"PASS: {template_count} AAP Orchestrator job templates are imported")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
