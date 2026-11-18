"""Wire AO to AAP, the MCP server and an LLM. Ports AO's half of includes/addon-wire.sh.

Every object this creates in AO is named ``aap-demo …`` and described
"Auto-wired by aap-demo", so a re-run updates it instead of adding another.
"""

from __future__ import annotations

import base64
import json
import time
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional

from aap_demo.addons.ao import llm as llm_mod
from aap_demo.addons.ao.admin import SECRET as ADMIN_SECRET
from aap_demo.addons.ao.api import AoClient, Http, Response, aap_token, error_text, quote
from aap_demo.addons.ao.instance import CALLERS, OLLAMA_NAMESPACE
from aap_demo.addons.ao.postgres import NAMESPACE
from aap_demo.addons.common.kube import as_dict
from aap_demo.cluster import ingress_ca
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.exec import kubectl

DESCRIPTION = "Auto-wired by aap-demo"
AAP_CREDENTIAL = "aap-demo AAP Token"
MCP_CREDENTIAL = "aap-demo MCP Token"
AAP_INTEGRATION = "aap-demo AAP"
MCP_INTEGRATION = "aap-demo MCP Server"
TOOL_CHUNK = 50
#: Ollama ignores the key, but AO requires one on an LLM credential.
OLLAMA_INPUTS = {"api_key": "ollama"}  # pragma: allowlist secret
REBIND_NOTE = "Rebound AO agentic nodes to the selected aap-demo LLM model"
#: Restarted after the allow-list changes so they pick up the new hosts.
OTHERS = (
    "automation-orchestrator-redis",
    "automation-orchestrator-temporal",
    "automation-orchestrator-ui",
)

Sleep = Callable[[float], None]


def _secret(ctx: AppContext, name: str, namespace: str) -> str:
    encoded = kubectl.jsonpath(ctx.runner, "secret", name, "-n", namespace, path="{.data.password}")
    try:
        return base64.b64decode(encoded).decode("utf-8") if encoded else ""
    except (ValueError, UnicodeDecodeError):
        return ""


@dataclass
class Routes:
    aap: str
    ao: str
    mcp: str
    ollama: str
    #: The cluster ingress CA that signs these routes, or "" when unreadable.
    ca: str = ""

    @classmethod
    def read(cls, ctx: AppContext, aap_namespace: str) -> "Routes":
        aap = kubectl.jsonpath(
            ctx.runner, "route", "aap", "-n", aap_namespace, path="{.spec.host}"
        ) or kubectl.jsonpath(
            ctx.runner, "route", "-n", aap_namespace, path="{.items[0].spec.host}"
        )
        listed = kubectl.jsonpath(
            ctx.runner,
            "route",
            "-n",
            aap_namespace,
            path='{range .items[*]}{.spec.host}{"\\n"}{end}',
        )
        mcp = next((h for h in listed.splitlines() if "mcp" in h), "")
        return cls(
            aap=aap,
            ao=kubectl.jsonpath(ctx.runner, "route", "-n", NAMESPACE, path="{.items[0].spec.host}"),
            mcp=mcp,
            ollama=kubectl.jsonpath(
                ctx.runner, "route", "ollama", "-n", OLLAMA_NAMESPACE, path="{.spec.host}"
            ),
        )


# -- network access -----------------------------------------------------------------


def allowed_hosts(routes: Routes, aap_namespace: str) -> List[str]:
    hosts = [
        routes.aap,
        routes.ao,
        f"aap.{aap_namespace}.svc.cluster.local",
        f"aap-mcp-server.{aap_namespace}.svc.cluster.local",
        routes.mcp,
        routes.ollama,
    ]
    unique: List[str] = []
    for host in hosts:
        if host and host not in unique:
            unique.append(host)
    return unique


def _container_env(ctx: AppContext, deployment: str) -> Optional[Dict[str, Any]]:
    result = kubectl.run(ctx.runner, "get", "deployment", deployment, "-n", NAMESPACE, "-o", "json")
    if not result.ok:
        return None
    try:
        spec = as_dict(
            as_dict(as_dict(json.loads(result.stdout or "{}")).get("spec")).get("template")
        ).get("spec")
    except json.JSONDecodeError:
        return None
    containers = as_dict(spec).get("containers") or []
    return as_dict(containers[0]) if containers else None


def _allowed(container: Dict[str, Any]) -> List[str]:
    """The container's APP_INTEGRATION_URL_ALLOWED_HOSTS, sorted; [] when unset."""
    for entry in container.get("env") or []:
        if as_dict(entry).get("name") == "APP_INTEGRATION_URL_ALLOWED_HOSTS":
            try:
                return sorted(json.loads(str(as_dict(entry).get("value") or "[]")))
            except ValueError:
                return []
    return []


def network_access(
    ctx: AppContext, routes: Routes, aap_namespace: str, *, sleep: Sleep = time.sleep
) -> None:
    """Put AAP, AO, MCP and Ollama hosts on AO's integration allow-list."""
    hosts = allowed_hosts(routes, aap_namespace)
    containers = {name: _container_env(ctx, name) for name in CALLERS}
    if containers["automation-orchestrator-backend"] is None:
        return
    if all(
        _allowed(container) == sorted(hosts)
        for container in containers.values()
        if container is not None
    ):
        ctx.console.success("AO integration allow-list already configured")
        return
    ctx.console.info("Configuring Automation Orchestrator integration URL allow-list...")
    patched = False
    for deployment in CALLERS:
        found = _container_env(ctx, deployment)
        if found is None:
            continue
        env = [{"name": "APP_INTEGRATION_URL_ALLOWED_HOSTS", "value": json.dumps(hosts)}]
        if deployment == "automation-orchestrator-backend":
            env.append({"name": "APP_OIDC_ALLOW_PRIVATE_NETWORKS", "value": "true"})
        patch = {
            "spec": {
                "template": {"spec": {"containers": [{"name": found.get("name"), "env": env}]}}
            }
        }
        result = kubectl.run(
            ctx.runner,
            "patch",
            "deployment",
            deployment,
            "-n",
            NAMESPACE,
            "--type=strategic",
            "-p",
            json.dumps(patch),
        )
        patched = patched or bool(result.ok)
    if not patched:
        ctx.console.warn("Could not patch AO deployments for the integration allow-list")
        return
    for deployment in CALLERS:
        kubectl.run(
            ctx.runner,
            "rollout",
            "status",
            f"deployment/{deployment}",
            "-n",
            NAMESPACE,
            "--timeout=300s",
        )
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    restart = json.dumps(
        {
            "spec": {
                "template": {
                    "metadata": {"annotations": {"kubectl.kubernetes.io/restartedAt": stamp}}
                }
            }
        }
    )
    for deployment in OTHERS:
        kubectl.run(
            ctx.runner,
            "patch",
            "deployment",
            deployment,
            "-n",
            NAMESPACE,
            "--type=strategic",
            "-p",
            restart,
        )
    ctx.console.success(f"AO integration allow-list applied ({len(hosts)} hostnames)")


# -- AO objects -----------------------------------------------------------------------


def _fail(message: str, response: Response) -> AddonError:
    return AddonError(message, hint=error_text(response))


def ensure_credential(ao: AoClient, name: str, type_name: str, inputs: Dict[str, Any]) -> str:
    project = ao.default_project()
    if not project:
        raise AddonError(f"No AO project found for credential {name}")
    types = ao.get("/credential_types?limit=100").items()
    kind = next((t for t in types if t.get("name") == type_name), None)
    if kind is None:
        raise AddonError(f"Could not resolve AO credential type: {type_name}")
    type_id = str(kind.get("id"))
    record = next(
        (
            c
            for c in ao.get(f"/credentials?name={quote(name)}&limit=100").items()
            if c.get("name") == name and str(c.get("project_id")) == project
        ),
        None,
    )
    cred_id = str(record.get("id")) if record else ""
    if record and str(record.get("credential_type_id") or "") not in ("", type_id):
        ao.call("DELETE", f"/credentials/{cred_id}")
        cred_id = ""
    if cred_id:
        scoped = ao.get(f"/projects/{project}/credentials/{cred_id}")
        if as_dict(scoped.body).get("code") == "CREDENTIAL_DECRYPTION_ERROR":
            # The record survived an AO reinstall that changed the encryption
            # key. AO will not detach a required management credential, so drop
            # only integrations this wiring created; they are recreated next.
            for integration in ao.get("/integrations?limit=100").items():
                if (
                    str(integration.get("management_credential_id")) == cred_id
                    and integration.get("description") == DESCRIPTION
                ):
                    ao.call("DELETE", f"/integrations/{integration.get('id')}")
            removed = ao.call("DELETE", f"/projects/{project}/credentials/{cred_id}")
            if removed.body and not removed.ok:
                raise _fail(f"Failed to replace undecryptable AO credential: {name}", removed)
            cred_id = ""
    if cred_id:
        # Managed credential types reject the global endpoint with HTTP 403.
        result = ao.call(
            "PATCH",
            f"/projects/{project}/credentials/{cred_id}",
            {"name": name, "description": DESCRIPTION, "inputs": inputs},
        )
        if not result.ok:
            raise _fail(f"Failed to update AO credential: {name}", result)
        return cred_id
    result = ao.call(
        "POST",
        f"/projects/{project}/credentials",
        {
            "name": name,
            "description": DESCRIPTION,
            "credential_type_id": type_id,
            "inputs": inputs,
        },
    )
    created = result.field("id")
    if not created:
        raise _fail(f"Failed to create AO credential: {name}", result)
    return created


def find_integration(ao: AoClient, name: str) -> str:
    found = ao.find("/integrations?limit=100", name=name)
    return str(found.get("id")) if found else ""


def ensure_integration(
    ao: AoClient,
    name: str,
    kind: str,
    config: Dict[str, Any],
    credential: str,
    *,
    discover: bool = False,
    sleep: Sleep = time.sleep,
) -> str:
    body = {
        "name": name,
        "description": DESCRIPTION,
        "configuration": config,
        "management_credential_id": credential,
        "enabled": True,
        "scope": "global",
    }
    probe = {"integration_type": kind, "configuration": config, "credential_id": credential}
    integration = find_integration(ao, name)
    if integration:
        result = ao.call("PATCH", f"/integrations/{integration}", body)
        if not result.ok:
            raise _fail(f"Failed to update AO integration: {name}", result)
    else:
        if discover:
            # Discovery can return hundreds of tools; keep the create request small.
            ao.call("POST", "/integrations/discover", probe)
        result = ao.call("POST", "/integrations", {**body, "integration_type": kind})
        integration = result.field("id")
        if not integration:
            raise _fail(f"Failed to create AO integration: {name}", result)
    if not ao.call("POST", f"/integrations/{integration}/validate", probe).ok:
        ao.call("POST", "/integrations/discover", probe)
    if discover:
        enable_tools(ao, integration, sleep=sleep)
    return integration


def enable_tools(ao: AoClient, integration: str, *, sleep: Sleep = time.sleep) -> None:
    path = f"/integrations/{integration}/tools?limit=100"
    tools = [str(t.get("id")) for t in ao.get(path).items()]
    if not tools:
        ao.call("POST", f"/integrations/{integration}/refresh", {})
        sleep(3)
        tools = [str(t.get("id")) for t in ao.get(path).items()]
    if not tools:
        return
    for start in range(0, len(tools), TOOL_CHUNK):
        ao.call(
            "PATCH",
            f"/integrations/{integration}/tools/bulk_update",
            {"tool_ids": tools[start : start + TOOL_CHUNK], "enabled": True},
        )


def _tls(url: str, ca: str) -> Dict[str, Any]:
    """Verify the route against the ingress CA. Skip only when no CA is known."""
    settings: Dict[str, Any] = {"allow_http": url.startswith("http://")}
    if ca:
        settings.update(ca_certificate=ca, insecure_skip_tls_verify=False)
    else:
        settings["insecure_skip_tls_verify"] = url.startswith("https://")
    return settings


def _plain_config(kind: str, url: str, ca: str) -> Dict[str, Any]:
    return {"integration_type": kind, "base_url": url, **_tls(url, ca)}


def wire_aap(ctx: AppContext, ao: AoClient, http: Http, routes: Routes, aap_namespace: str) -> None:
    ctx.console.info("Wiring Automation Orchestrator to AAP...")
    password = _secret(ctx, "aap-admin-password", aap_namespace)
    token = (
        aap_token(http, routes.aap, password, description="aap-demo AO integration")
        if routes.aap and password
        else ""
    )
    if not token:
        raise AddonError("Could not mint an AAP token for the AO integration")
    # AO rejects base URLs that resolve to private addresses; use the route.
    url = f"https://{routes.aap}"
    credential = ensure_credential(
        ao, AAP_CREDENTIAL, "Ansible Automation Platform", {"oauth_token": token}
    )
    ensure_integration(
        ao,
        AAP_INTEGRATION,
        "ansible_automation_platform",
        _plain_config("ansible_automation_platform", url, routes.ca),
        credential,
    )
    ctx.console.success(f"AO integration configured: {AAP_INTEGRATION}")


def mcp_url(ctx: AppContext, routes: Routes, aap_namespace: str) -> str:
    if routes.mcp:
        return f"https://{routes.mcp}/mcp"
    port = (
        kubectl.jsonpath(
            ctx.runner, "svc", "aap-mcp-server", "-n", aap_namespace, path="{.spec.ports[0].port}"
        )
        or "8086"
    )
    return f"http://aap-mcp-server.{aap_namespace}.svc.cluster.local:{port}/mcp"


def wire_mcp(
    ctx: AppContext,
    ao: AoClient,
    http: Http,
    routes: Routes,
    aap_namespace: str,
    *,
    sleep: Sleep = time.sleep,
) -> None:
    if not (
        kubectl.exists(ctx.runner, "ansiblemcpserver", "aap-mcp-server", "-n", aap_namespace)
        or kubectl.exists(ctx.runner, "deployment", "aap-mcp-server", "-n", aap_namespace)
    ):
        raise AddonError(
            "mcp-server is required for Automation Orchestrator but is not deployed",
            hint="Run: aap-demo enable mcp-server",
        )
    ctx.console.info("Wiring Automation Orchestrator to the MCP server...")
    password = _secret(ctx, "aap-admin-password", aap_namespace)
    token = (
        aap_token(http, routes.aap, password, description="aap-demo AO MCP integration")
        if routes.aap and password
        else ""
    )
    if not token:
        raise AddonError("Could not mint an AAP token for the MCP integration")
    url = mcp_url(ctx, routes, aap_namespace)
    credential = ensure_credential(ao, MCP_CREDENTIAL, "HTTP Bearer Token", {"token": token})
    ensure_integration(
        ao,
        MCP_INTEGRATION,
        "mcp_server",
        _plain_config("mcp_server", url, routes.ca),
        credential,
        discover=True,
        sleep=sleep,
    )
    ctx.console.success(f"AO integration configured: {MCP_INTEGRATION}")


# -- LLM ------------------------------------------------------------------------


def _set_default_model(ao: AoClient, integration: str, model: str) -> str:
    found = ao.find(f"/integrations/{integration}/models?limit=50", model_id=model)
    if found is None:
        raise AddonError(f"Model {model} not found in AO after refresh")
    model_id = str(found.get("id"))
    result = ao.call(
        "PATCH", f"/integrations/{integration}/models/{model_id}", {"is_default": True}
    )
    if not result.ok:
        raise _fail(f"Failed to set AO model {model} as the default", result)
    return model_id


def _wire_llm(
    ao: AoClient, name: str, config: Dict[str, Any], inputs: Optional[Dict[str, Any]], model: str
) -> str:
    """Credential, integration, refresh and default model for one provider."""
    if inputs is not None:
        credential = ensure_credential(ao, name, "LLM Provider", inputs)
    else:
        found = ao.find(f"/credentials?name={quote(name)}&limit=100", name=name)
        if found is None:
            raise AddonError(
                "No API key found for the external LLM provider",
                hint="Set AO_LLM_API_KEY and run aap-demo enable ao again.",
            )
        credential = str(found.get("id"))
    integration = ensure_integration(ao, name, "llm_provider", config, credential)
    refreshed = ao.call("POST", f"/integrations/{integration}/refresh", {})
    if not refreshed.ok:
        raise _fail(f"Failed to refresh {name} models", refreshed)
    _set_default_model(ao, integration, model)
    return integration


def wire_llm(ctx: AppContext, ao: AoClient, routes: Routes) -> None:
    settings = llm_mod.settings(ctx)
    if settings.provider == "none":
        ctx.console.info("Skipping AO LLM provider wiring (none selected)")
        return
    if settings.provider == "ollama":
        if not routes.ollama:
            ctx.console.warn("Ollama is not deployed; skipping AO LLM wiring")
            return
        ctx.console.info("Wiring Automation Orchestrator to the Ollama LLM provider...")
        url = f"https://{routes.ollama}/v1"
        config = {
            "integration_type": "llm_provider",
            "provider_hint": "custom",
            "base_url": url,
            **_tls(url, routes.ca),
        }
        _wire_llm(ao, settings.integration, config, OLLAMA_INPUTS, settings.model)
    else:
        ctx.console.info("Wiring Automation Orchestrator to the external LLM provider...")
        config = {
            "integration_type": "llm_provider",
            "provider_hint": "custom",
            "base_url": settings.base_url,
            "allow_http": False,
            "insecure_skip_tls_verify": False,
        }
        key = llm_mod.api_key(ctx)
        _wire_llm(
            ao, settings.integration, config, {"api_key": key} if key else None, settings.model
        )
    ctx.console.success(f"Default AO model set: {settings.model}")


def rebind_workflows(ctx: AppContext, ao: AoClient) -> None:
    """Point aap-demo's agentic workflow nodes at the selected LLM model."""
    settings = llm_mod.settings(ctx)
    if settings.provider == "none":
        return
    credential = ao.find(
        f"/credentials?name={quote(settings.integration)}&limit=100", name=settings.integration
    )
    integration = find_integration(ao, settings.integration)
    model = (
        ao.find(f"/integrations/{integration}/models?limit=50", model_id=settings.model)
        if integration
        else None
    )
    if not (credential and integration and model):
        ctx.console.warn(
            f"AO has no {settings.integration} credential, integration and model "
            f"{settings.model}; workflow rebinding skipped"
        )
        return
    cursor = ""
    while True:
        path = "/workflows?limit=100" + (f"&cursor={quote(cursor)}" if cursor else "")
        page = ao.get(path)
        for workflow in page.items():
            if as_dict(workflow.get("labels")).get("aap-demo") != "true":
                continue
            definition = as_dict(workflow.get("workflow_definition"))
            nodes = [as_dict(n) for n in definition.get("nodes") or []]
            agents = [n for n in nodes if n.get("type") == "agentic"]
            if not agents:
                continue
            for node in agents:
                parameters = {
                    k: v for k, v in as_dict(node.get("parameters")).items() if k != "model"
                }
                parameters.update(
                    credential_id=str(credential.get("id")),
                    integration_id=integration,
                    llm_model_id=str(model.get("id")),
                )
                node["parameters"] = parameters
            definition["nodes"] = nodes
            result = ao.call(
                "PATCH",
                f"/workflows/{workflow.get('id')}",
                {
                    "workflow_definition": definition,
                    "change_description": REBIND_NOTE,
                },
            )
            if result.ok:
                ctx.console.success(
                    f"Rebound {len(agents)} AO agentic node(s) in workflow {workflow.get('id')}"
                )
            else:
                ctx.console.warn(f"Failed to rebind AO workflow {workflow.get('id')}")
        cursor = page.field("next")
        if not cursor:
            break


# -- entry point ----------------------------------------------------------------------


@dataclass
class Session:
    """What the wiring opened, reused by the demo import."""

    ao: AoClient
    http: Http
    context: Any
    routes: Routes


def wire(
    ctx: AppContext,
    aap_namespace: str,
    *,
    http: Optional[Http] = None,
    sleep: Sleep = time.sleep,
) -> Optional[Session]:
    """Everything ``aap_demo_wire`` did for AO. Raises on AAP or MCP failure.

    None when AO's backend is not deployed.
    """
    from aap_demo.addons.ao.api import tls_context

    if not kubectl.exists(
        ctx.runner, "deployment", "automation-orchestrator-backend", "-n", NAMESPACE
    ):
        return None
    routes = Routes.read(ctx, aap_namespace)
    for attempt in range(12):
        if routes.ao:
            break
        if attempt + 1 < 12:
            sleep(5)
        routes = Routes.read(ctx, aap_namespace)
    else:
        raise AddonError("Automation Orchestrator route not ready after 60s")
    network_access(ctx, routes, aap_namespace, sleep=sleep)
    routes.ca = ingress_ca.fetch_cluster_ca(ctx) or ""
    if not routes.ca:
        ctx.console.warn(
            "Could not read the cluster ingress CA; AO's integrations will not verify "
            "the AAP, MCP and Ollama route certificates."
        )
    context = http.context if http is not None else tls_context(ctx, routes.ca)
    client = http or Http(context=context)
    ao = AoClient(http=client, route=routes.ao)
    ao.login(_secret(ctx, ADMIN_SECRET, NAMESPACE))
    if kubectl.exists(ctx.runner, "aap", "-n", aap_namespace):
        wire_aap(ctx, ao, client, routes, aap_namespace)
    wire_mcp(ctx, ao, client, routes, aap_namespace, sleep=sleep)
    try:
        wire_llm(ctx, ao, routes)
    except AddonError as exc:
        ctx.console.warn(f"AO LLM provider wiring skipped: {exc.message}")
    rebind_workflows(ctx, ao)
    return Session(ao=ao, http=client, context=context, routes=routes)


__all__ = ["Routes", "Session", "wire"]
