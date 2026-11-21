"""AO's ``ollama`` provider uses the host's Ollama (ADR-046)."""

from __future__ import annotations

import argparse
import json
from typing import Any, Dict, List, Optional

import pytest

from aap_demo.addons import get
from aap_demo.addons.ao import host_ollama
from aap_demo.core.errors import AddonError
from aap_demo.exec.runner import CompletedCommand, FakeRunner

API = host_ollama.HOST_API
CHECK = f"kubectl run {host_ollama.CHECK_POD}"


class FakeOllama:
    """The host's Ollama API, answering by URL."""

    def __init__(
        self,
        *,
        version: str = "0.40.14",
        models: Optional[List[str]] = None,
        capabilities: Optional[Dict[str, Any]] = None,
    ) -> None:
        self.version = version
        self.models = ["granite:8b"] if models is None else models
        self.capabilities = capabilities or {}
        self.calls: List[str] = []

    def __call__(self, url: str, body: Optional[Dict[str, Any]] = None) -> Optional[Any]:
        self.calls.append(url)
        if not self.version:
            return None
        if url.endswith("/api/version"):
            return {"version": self.version}
        if url.endswith("/api/tags"):
            return {"models": [{"name": name} for name in self.models]}
        if url.endswith("/api/show"):
            assert body is not None
            found = self.capabilities.get(body["model"], ["completion", "tools"])
            return {} if found is None else {"capabilities": found}
        raise AssertionError(url)


def _runner(*, reaches: bool = True, old_namespace: bool = False) -> FakeRunner:
    runner = FakeRunner()
    if old_namespace:
        runner.ok(f"kubectl get namespace {host_ollama.OLD_NAMESPACE}")
    else:
        runner.fail(f"kubectl get namespace {host_ollama.OLD_NAMESPACE}")
    runner.ok(f"kubectl delete pod {host_ollama.CHECK_POD}")
    if reaches:
        runner.ok(CHECK, "200")
    else:
        runner.register(CHECK, CompletedCommand(argv=(), returncode=1, stdout="000"))
    return runner


def _prepare(app_ctx, ollama: FakeOllama, **kwargs: Any) -> str:
    kwargs.setdefault("platform", "darwin")
    return host_ollama.prepare(app_ctx, host_ollama.CLUSTER_URL, get=ollama, **kwargs)


def _out(app_ctx) -> str:
    return app_ctx.console.stdout + app_ctx.console.stderr


# -- detection ----------------------------------------------------------------------


def test_one_model_is_chosen_saved_and_checked_from_the_cluster(app_ctx) -> None:
    app_ctx.runner = _runner()
    assert _prepare(app_ctx, FakeOllama()) == "granite:8b"
    assert app_ctx.config.get("addons.options")["ao"]["ollama_model"] == "granite:8b"
    assert "Ollama 0.40.14 on the host" in _out(app_ctx)
    check = next(
        c for c in app_ctx.runner.calls if c.argv[:3] == ("kubectl", "run", "aap-demo-ollama-check")
    )
    overrides = json.loads(
        next(a for a in check.argv if a.startswith("--overrides=")).split("=", 1)[1]
    )
    container = overrides["spec"]["containers"][0]
    assert container["command"][-1] == "http://192.168.127.254:11434/api/version"
    assert container["securityContext"]["capabilities"] == {"drop": ["ALL"]}
    assert overrides["spec"]["securityContext"]["runAsNonRoot"] is True
    assert "docker.io" not in host_ollama.CHECK_IMAGE


def test_ollama_not_running_says_how_to_install_it(app_ctx) -> None:
    app_ctx.runner = FakeRunner()
    with pytest.raises(AddonError, match="Ollama is not running at http://127.0.0.1:11434") as exc:
        _prepare(app_ctx, FakeOllama(version=""))
    assert "ollama.com" in (exc.value.hint or "")
    assert "AO_LLM_PROVIDER=external" in (exc.value.hint or "")
    assert app_ctx.runner.calls == []


def test_no_models_says_to_pull_one_and_never_pulls(app_ctx) -> None:
    app_ctx.runner = _runner()
    ollama = FakeOllama(models=[])
    with pytest.raises(AddonError, match="has no models") as exc:
        _prepare(app_ctx, ollama)
    assert "ollama pull" in (exc.value.hint or "")
    assert not any("/api/pull" in url for url in ollama.calls)


def test_a_requested_model_that_is_missing_stops(app_ctx) -> None:
    app_ctx.runner = _runner()
    app_ctx.env = {"OLLAMA_MODEL": "llama3.2"}
    with pytest.raises(AddonError, match="llama3.2 is not on this host") as exc:
        _prepare(app_ctx, FakeOllama(models=["granite:8b"]))
    assert "ollama pull llama3.2" in (exc.value.hint or "")


def test_a_model_without_a_tag_matches_latest(app_ctx) -> None:
    app_ctx.runner = _runner()
    app_ctx.env = {"OLLAMA_MODEL": "granite"}
    assert _prepare(app_ctx, FakeOllama(models=["granite:latest", "qwen3:8b"])) == "granite:latest"


def test_a_saved_model_is_used_again(app_ctx) -> None:
    app_ctx.runner = _runner()
    app_ctx.config.set("addons.options", {"ao": {"ollama_model": "qwen3:8b"}})
    assert _prepare(app_ctx, FakeOllama(models=["granite:8b", "qwen3:8b"])) == "qwen3:8b"


def test_several_models_without_a_terminal_list_them(app_ctx) -> None:
    app_ctx.runner = _runner()
    with pytest.raises(AddonError, match="several models") as exc:
        _prepare(app_ctx, FakeOllama(models=["granite:8b", "qwen3:8b"]))
    assert "granite:8b, qwen3:8b" in (exc.value.hint or "")
    assert "OLLAMA_MODEL" in (exc.value.hint or "")


@pytest.mark.parametrize("answer", ["2", "qwen3:8b"])
def test_several_models_are_offered_in_a_terminal(app_ctx, answer) -> None:
    app_ctx.runner = _runner()
    app_ctx.env = {"AAP_DEMO_INTERACTIVE": "1"}
    chosen = _prepare(
        app_ctx, FakeOllama(models=["granite:8b", "qwen3:8b"]), read=lambda _q: answer
    )
    assert chosen == "qwen3:8b"
    assert app_ctx.config.get("addons.options")["ao"]["ollama_model"] == "qwen3:8b"


def test_an_empty_answer_chooses_nothing(app_ctx) -> None:
    app_ctx.runner = _runner()
    app_ctx.env = {"AAP_DEMO_INTERACTIVE": "1"}
    with pytest.raises(AddonError, match="No model chosen"):
        _prepare(app_ctx, FakeOllama(models=["a:1", "b:1"]), read=lambda _q: "")


def test_a_model_without_tools_is_a_warning(app_ctx) -> None:
    app_ctx.runner = _runner()
    _prepare(app_ctx, FakeOllama(capabilities={"granite:8b": ["completion"]}))
    assert "does not list tool support" in _out(app_ctx)


def test_an_ollama_without_capabilities_warns_that_the_check_was_skipped(app_ctx) -> None:
    app_ctx.runner = _runner()
    _prepare(app_ctx, FakeOllama(capabilities={"granite:8b": None}))
    assert "does not report model capabilities" in _out(app_ctx)


def test_the_old_in_cluster_ollama_is_pointed_out(app_ctx) -> None:
    app_ctx.runner = _runner(old_namespace=True)
    _prepare(app_ctx, FakeOllama())
    assert "aap-demo disable ollama" in _out(app_ctx)


def test_a_base_url_override_checks_that_address(app_ctx) -> None:
    app_ctx.runner = _runner()
    ollama = FakeOllama()
    host_ollama.prepare(app_ctx, "http://192.168.130.1:11434/v1", get=ollama, platform="linux")
    assert ollama.calls[0] == "http://192.168.130.1:11434/api/version"


# -- reachability -------------------------------------------------------------------


@pytest.mark.parametrize(
    ("setting", "why"),
    [("host-network-access : false", "created without"), ("host-network-access : true", "may")],
)
def test_an_unreachable_host_explains_the_new_vm(app_ctx, setting, why) -> None:
    app_ctx.runner = _runner(reaches=False).ok("crc config get host-network-access", setting)
    with pytest.raises(AddonError, match="cannot reach Ollama") as exc:
        _prepare(app_ctx, FakeOllama())
    hint = exc.value.hint or ""
    assert why in hint
    assert "aap-demo destroy, then aap-demo create" in hint
    assert not app_ctx.runner.called("crc cleanup")


def test_an_unreachable_host_on_linux_points_at_the_base_url(app_ctx) -> None:
    app_ctx.runner = _runner(reaches=False)
    with pytest.raises(AddonError, match="cannot reach Ollama") as exc:
        _prepare(app_ctx, FakeOllama(), platform="linux")
    assert "AO_LLM_BASE_URL" in (exc.value.hint or "")
    assert not app_ctx.runner.called("crc")


# -- the ollama addon ---------------------------------------------------------------


def test_enable_ollama_explains_the_host_ollama(app_ctx) -> None:
    app_ctx.runner = FakeRunner()
    with pytest.raises(AddonError, match="no longer installs Ollama") as exc:
        get("ollama").enable(app_ctx, argparse.Namespace(addon="ollama"))
    assert "ollama.com" in (exc.value.hint or "")
    assert app_ctx.runner.calls == []


def test_disable_ollama_removes_the_old_install(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok("kubectl delete")
    app_ctx.config.set("addons.enabled", ["mcp-server", "ollama", "ao"])
    assert get("ollama").disable(app_ctx, argparse.Namespace(addon="ollama")) == 0
    assert app_ctx.runner.called("kubectl delete namespace aap-demo-ollama --ignore-not-found")
    assert app_ctx.runner.called(
        "kubectl delete clusterrolebinding aap-demo-ollama-anyuid --ignore-not-found"
    )
    assert app_ctx.config.get("addons.enabled") == ["mcp-server", "ao"]
