"""AO wiring, LLM settings and instance helpers (ADR-045)."""

from __future__ import annotations

import json
import stat
import sys
from typing import Any, Callable, Dict, List, Optional, Tuple

import pytest

from aap_demo.addons.ao import api, instance, llm, wiring
from aap_demo.addons.ao.api import AoClient, Http, Response
from aap_demo.core.errors import AddonError, UsageError
from aap_demo.exec.runner import FakeRunner

Handler = Callable[[Optional[Any]], Tuple[int, Any]]


class FakeHttp(Http):
    """Routes ``METHOD path`` (prefix, query string included) to canned replies."""

    def __init__(self, routes: Dict[str, Handler]) -> None:
        super().__init__(context=None)
        self.routes = routes
        self.calls: List[Tuple[str, str, Any]] = []

    def call(self, method, url, *, body=None, headers=None):  # type: ignore[override]
        path = url.split("/api/v1", 1)[-1] if "/api/v1" in url else url
        self.calls.append((method, path, body))
        for pattern, handler in self.routes.items():
            want_method, want_path = pattern.split(" ", 1)
            if method == want_method and path.startswith(want_path):
                status, reply = handler(body)
                return Response(status=status, body=reply)
        raise AssertionError(f"unexpected {method} {path}")

    def sent(self, method: str, prefix: str) -> List[Any]:
        return [b for m, p, b in self.calls if m == method and p.startswith(prefix)]


def _reply(body: Any, status: int = 200) -> Handler:
    return lambda _sent: (status, body)


def _client(routes: Dict[str, Handler]) -> Tuple[AoClient, FakeHttp]:
    http = FakeHttp(
        {
            "GET /projects?limit=10&is_default=true": _reply(
                {"resources": [{"id": "p1", "is_default": True}]}
            ),
            "GET /credential_types": _reply(
                {
                    "resources": [
                        {"id": "t-aap", "name": "Ansible Automation Platform"},
                        {"id": "t-llm", "name": "LLM Provider"},
                    ]
                }
            ),
            **routes,
        }
    )
    return AoClient(http=http, route="ao.example", token="t"), http


# -- LLM settings -------------------------------------------------------------------


def test_llm_defaults_to_ollama(app_ctx) -> None:
    settings = llm.settings(app_ctx)
    assert (settings.provider, settings.model) == ("ollama", llm.DEFAULT_OLLAMA_MODEL)
    assert settings.integration == "aap-demo Ollama"


def test_llm_reads_the_bash_config(app_ctx) -> None:
    legacy = app_ctx.paths.legacy_config_file
    legacy.parent.mkdir(parents=True, exist_ok=True)
    legacy.write_text("AO_LLM_PROVIDER=external\nAO_LLM_MODEL=luna\n")
    settings = llm.settings(app_ctx)
    assert (settings.provider, settings.model) == ("external", "gpt-6-luna")


def test_environment_beats_the_bash_config(app_ctx) -> None:
    legacy = app_ctx.paths.legacy_config_file
    legacy.parent.mkdir(parents=True, exist_ok=True)
    legacy.write_text("AO_LLM_PROVIDER=external\n")
    app_ctx.env = {"AO_LLM_PROVIDER": "none"}
    assert llm.settings(app_ctx).provider == "none"


def test_unknown_provider_is_a_usage_error(app_ctx) -> None:
    app_ctx.env = {"AO_LLM_PROVIDER": "magic"}
    with pytest.raises(UsageError):
        llm.settings(app_ctx)


def test_bash_api_key_is_copied_privately(app_ctx) -> None:
    legacy = app_ctx.paths.legacy_dir / "ao" / llm.KEY_FILE
    legacy.parent.mkdir(parents=True)
    legacy.write_text("sk-legacy\n")
    assert llm.api_key(app_ctx) == "sk-legacy"
    if sys.platform != "win32":  # Windows has no POSIX file modes
        assert stat.S_IMODE(llm.key_path(app_ctx).stat().st_mode) == 0o600
    assert legacy.is_file()


# -- credentials and integrations --------------------------------------------------------


def test_new_credential_is_created_in_the_default_project() -> None:
    ao, http = _client(
        {
            "GET /credentials": _reply({"resources": []}),
            "POST /projects/p1/credentials": _reply({"id": "c1"}),
        }
    )
    assert (
        wiring.ensure_credential(
            ao, "aap-demo AAP Token", "Ansible Automation Platform", {"oauth_token": "x"}
        )
        == "c1"
    )
    created = http.sent("POST", "/projects/p1/credentials")[0]
    assert created["credential_type_id"] == "t-aap"
    assert created["description"] == wiring.DESCRIPTION


def test_undecryptable_credential_is_replaced_with_only_our_integrations() -> None:
    ao, http = _client(
        {
            "GET /credentials": _reply(
                {
                    "resources": [
                        {"id": "c1", "name": "n", "project_id": "p1", "credential_type_id": "t-aap"}
                    ]
                }
            ),
            "GET /projects/p1/credentials/c1": _reply({"code": "CREDENTIAL_DECRYPTION_ERROR"}, 400),
            "GET /integrations": _reply(
                {
                    "resources": [
                        {
                            "id": "i-ours",
                            "management_credential_id": "c1",
                            "description": wiring.DESCRIPTION,
                        },
                        {
                            "id": "i-theirs",
                            "management_credential_id": "c1",
                            "description": "manual",
                        },
                    ]
                }
            ),
            "DELETE /integrations/": _reply({}, 204),
            "DELETE /projects/p1/credentials/c1": _reply({}, 204),
            "POST /projects/p1/credentials": _reply({"id": "c2"}),
        }
    )
    assert wiring.ensure_credential(ao, "n", "Ansible Automation Platform", {}) == "c2"
    deleted = [p for m, p, _b in http.calls if m == "DELETE" and p.startswith("/integrations/")]
    assert deleted == ["/integrations/i-ours"]


def test_existing_integration_is_patched_not_duplicated() -> None:
    ao, http = _client(
        {
            "GET /integrations": _reply({"resources": [{"id": "i1", "name": "aap-demo AAP"}]}),
            "PATCH /integrations/i1": _reply({"id": "i1"}),
            "POST /integrations/i1/validate": _reply({}),
        }
    )
    assert (
        wiring.ensure_integration(ao, "aap-demo AAP", "ansible_automation_platform", {}, "c1")
        == "i1"
    )
    assert not http.sent("POST", "/integrations?")
    assert http.sent("PATCH", "/integrations/i1")[0]["management_credential_id"] == "c1"


def test_tools_are_enabled_in_chunks() -> None:
    tools = {"resources": [{"id": str(n)} for n in range(120)]}
    ao, http = _client(
        {
            "GET /integrations/i1/tools": _reply(tools),
            "PATCH /integrations/i1/tools/bulk_update": _reply({}),
        }
    )
    wiring.enable_tools(ao, "i1", sleep=lambda _s: None)
    sizes = [len(b["tool_ids"]) for b in http.sent("PATCH", "/integrations/i1/tools/bulk_update")]
    assert sizes == [50, 50, 20]


def test_tools_on_later_pages_are_enabled_too() -> None:
    first = {"resources": [{"id": str(n)} for n in range(100)], "next": "c/2"}
    second = {"resources": [{"id": str(n)} for n in range(100, 144)], "next": None}
    ao, http = _client(
        {
            "GET /integrations/i1/tools?limit=100&cursor=c%2F2": _reply(second),
            "GET /integrations/i1/tools?limit=100": _reply(first),
            "PATCH /integrations/i1/tools/bulk_update": _reply({}),
        }
    )
    wiring.enable_tools(ao, "i1", sleep=lambda _s: None)
    sent = http.sent("PATCH", "/integrations/i1/tools/bulk_update")
    assert sum(len(b["tool_ids"]) for b in sent) == 144


def test_a_cursor_that_never_ends_stops_at_the_page_limit() -> None:
    ao, http = _client({"GET /things": _reply({"resources": [{"id": "x"}], "next": "again"})})
    assert len(ao.list_all("/things?limit=1")) == api.MAX_PAGES
    assert len(http.calls) == api.MAX_PAGES


def test_rebind_updates_only_aap_demo_agentic_nodes(app_ctx) -> None:
    workflow = {
        "id": "w1",
        "labels": {"aap-demo": "true"},
        "workflow_definition": {
            "nodes": [
                {"type": "agentic", "parameters": {"model": "old", "keep": 1}},
                {"type": "task", "parameters": {}},
            ]
        },
    }
    other = {"id": "w2", "labels": {}, "workflow_definition": {"nodes": [{"type": "agentic"}]}}
    ao, http = _client(
        {
            "GET /credentials": _reply({"resources": [{"id": "c1", "name": "aap-demo Ollama"}]}),
            "GET /integrations?": _reply({"resources": [{"id": "i1", "name": "aap-demo Ollama"}]}),
            "GET /integrations/i1/models": _reply(
                {"resources": [{"id": "m1", "model_id": llm.DEFAULT_OLLAMA_MODEL}]}
            ),
            "GET /workflows": _reply({"resources": [workflow, other]}),
            "PATCH /workflows/w1": _reply({"id": "w1"}),
        }
    )
    wiring.rebind_workflows(app_ctx, ao)
    assert not http.sent("PATCH", "/workflows/w2")
    nodes = http.sent("PATCH", "/workflows/w1")[0]["workflow_definition"]["nodes"]
    assert nodes[0]["parameters"] == {
        "keep": 1,
        "credential_id": "c1",
        "integration_id": "i1",
        "llm_model_id": "m1",
    }
    assert nodes[1]["parameters"] == {}


def test_rebind_warns_when_the_model_is_missing(app_ctx) -> None:
    ao, _http = _client(
        {
            "GET /credentials": _reply({"resources": []}),
            "GET /integrations?": _reply({"resources": []}),
        }
    )
    wiring.rebind_workflows(app_ctx, ao)
    assert "workflow rebinding skipped" in app_ctx.console.stderr + app_ctx.console.stdout


def test_wire_llm_without_ollama_only_warns(app_ctx) -> None:
    ao, http = _client({})
    routes = wiring.Routes(aap="aap.x", ao="ao.x", mcp="", ollama="")
    wiring.wire_llm(app_ctx, ao, routes)
    assert http.calls == []


def test_allowed_hosts_are_unique_and_skip_blanks() -> None:
    routes = wiring.Routes(aap="aap.x", ao="ao.x", mcp="", ollama="aap.x")
    assert wiring.allowed_hosts(routes, "aap-operator") == [
        "aap.x",
        "ao.x",
        "aap.aap-operator.svc.cluster.local",
        "aap-mcp-server.aap-operator.svc.cluster.local",
    ]


# -- instance ---------------------------------------------------------------------


@pytest.mark.parametrize(
    ("value", "count"), [("", 1), ("true", 1), ("1", 1), ("0", 2), ("false", 2)]
)
def test_replica_count(app_ctx, value: str, count: int) -> None:
    app_ctx.env = {"AO_LOW_RESOURCE": value}
    assert instance.replica_count(app_ctx) == count


def test_replica_count_rejects_other_values(app_ctx) -> None:
    app_ctx.env = {"AO_LOW_RESOURCE": "maybe"}
    with pytest.raises(UsageError):
        instance.replica_count(app_ctx)


def test_local_hosts() -> None:
    assert instance.is_local_host("aap-aap-operator.apps.127.0.0.1.nip.io")
    assert instance.is_local_host("aap.apps-crc.crc.testing")
    assert not instance.is_local_host("aap.example.com")


def test_wait_ready_times_out_with_the_degraded_reason(app_ctx) -> None:
    status = '{"status":{"conditions":[{"type":"Degraded","status":"True","reason":"DbDown"}]}}'
    app_ctx.runner = (
        FakeRunner()
        .ok("kubectl get automationorchestrator", status)
        .ok("kubectl get pods", "")
        .ok("kubectl get routes", "")
    )
    ticks = iter([0.0, 0.0, 2000.0])
    with pytest.raises(AddonError, match="not Ready") as excinfo:
        instance.wait_ready(app_ctx, sleep=lambda _s: None, clock=lambda: next(ticks))
    assert "DbDown" in (excinfo.value.hint or "")


# -- TLS for AO's integrations -----------------------------------------------------


def test_integrations_trust_the_ingress_ca() -> None:
    config = wiring._plain_config("mcp_server", "https://mcp.x/mcp", "PEM")
    assert config["ca_certificate"] == "PEM"
    assert config["insecure_skip_tls_verify"] is False
    assert config["allow_http"] is False


def test_integrations_skip_verification_only_without_a_ca() -> None:
    assert wiring._tls("https://aap.x", "")["insecure_skip_tls_verify"] is True
    plain = wiring._tls("http://aap-mcp-server.ns.svc.cluster.local:8086/mcp", "")
    assert plain == {"allow_http": True, "insecure_skip_tls_verify": False}


def _deployment(hosts, *, oidc=True):
    env = (
        []
        if hosts is None
        else [{"name": "APP_INTEGRATION_URL_ALLOWED_HOSTS", "value": json.dumps(hosts)}]
    )
    if oidc:
        env.append({"name": "APP_OIDC_ALLOW_PRIVATE_NETWORKS", "value": "true"})
    return json.dumps({"spec": {"template": {"spec": {"containers": [{"name": "c", "env": env}]}}}})


def test_allow_list_is_patched_when_only_a_worker_is_missing_it(app_ctx) -> None:
    routes = wiring.Routes(aap="aap.x", ao="ao.x", mcp="", ollama="")
    hosts = wiring.allowed_hosts(routes, "aap-operator")
    app_ctx.runner = (
        FakeRunner()
        .ok("kubectl get deployment automation-orchestrator-backend", _deployment(hosts))
        .ok("kubectl get deployment automation-orchestrator-worker", _deployment(None))
        .ok("kubectl get deployment automation-orchestrator-background-worker", _deployment(hosts))
        .ok("kubectl patch deployment")
        .ok("kubectl rollout status")
    )
    wiring.network_access(app_ctx, routes, "aap-operator", sleep=lambda _s: None)
    assert app_ctx.runner.called("kubectl patch deployment automation-orchestrator-worker")


def test_allow_list_already_on_every_caller_is_left_alone(app_ctx) -> None:
    routes = wiring.Routes(aap="aap.x", ao="ao.x", mcp="", ollama="")
    hosts = wiring.allowed_hosts(routes, "aap-operator")
    app_ctx.runner = FakeRunner().ok("kubectl get deployment", _deployment(hosts))
    wiring.network_access(app_ctx, routes, "aap-operator", sleep=lambda _s: None)
    assert not app_ctx.runner.called("kubectl patch")


def test_backend_without_private_network_oidc_is_patched(app_ctx) -> None:
    routes = wiring.Routes(aap="aap.x", ao="ao.x", mcp="", ollama="")
    hosts = wiring.allowed_hosts(routes, "aap-operator")
    app_ctx.runner = (
        FakeRunner()
        .ok(
            "kubectl get deployment automation-orchestrator-backend",
            _deployment(hosts, oidc=False),
        )
        .ok("kubectl get deployment", _deployment(hosts))
        .ok("kubectl patch deployment")
        .ok("kubectl rollout status")
    )
    wiring.network_access(app_ctx, routes, "aap-operator", sleep=lambda _s: None)
    assert app_ctx.runner.called("kubectl patch deployment automation-orchestrator-backend")


def test_a_failed_caller_patch_is_reported(app_ctx) -> None:
    routes = wiring.Routes(aap="aap.x", ao="ao.x", mcp="", ollama="")
    app_ctx.runner = (
        FakeRunner()
        .ok("kubectl get deployment", _deployment(None))
        .fail("kubectl patch deployment automation-orchestrator-worker")
        .ok("kubectl patch deployment")
        .ok("kubectl rollout status")
    )
    wiring.network_access(app_ctx, routes, "aap-operator", sleep=lambda _s: None)
    assert "allow-list on automation-orchestrator-worker" in app_ctx.console.stderr


def test_an_unreadable_caller_is_not_treated_as_configured(app_ctx) -> None:
    routes = wiring.Routes(aap="aap.x", ao="ao.x", mcp="", ollama="")
    hosts = wiring.allowed_hosts(routes, "aap-operator")
    app_ctx.runner = (
        FakeRunner()
        .fail("kubectl get deployment automation-orchestrator-worker")
        .ok("kubectl get deployment", _deployment(hosts))
        .ok("kubectl patch deployment")
        .ok("kubectl rollout status")
    )
    wiring.network_access(app_ctx, routes, "aap-operator", sleep=lambda _s: None)
    assert app_ctx.runner.called("kubectl patch deployment automation-orchestrator-backend")
    assert "allow-list on automation-orchestrator-worker" in app_ctx.console.stderr
