"""AO and MCP are native; Ollama remains a bundled installer dependency."""

from __future__ import annotations

import argparse
import base64
import json
import re
from pathlib import Path

import pytest

from aap_demo.addons import get, names
from aap_demo.addons.ao import AoAddon, deps
from aap_demo.addons.shell import scripts_root
from aap_demo.core.errors import AddonError, UsageError
from aap_demo.exec.runner import CompletedCommand

REPO_ROOT = Path(__file__).resolve().parents[2]
_CERT = "-----BEGIN CERTIFICATE-----\nZm9v\n-----END CERTIFICATE-----"


@pytest.fixture(autouse=True)
def _tools(monkeypatch, fake_runner) -> None:
    monkeypatch.setattr("aap_demo.addons.shell.shutil.which", lambda name: f"/usr/bin/{name}")
    fake_runner.ok("kubectl get ansiblemcpservers.mcpserver.ansible.com")
    fake_runner.ok(
        "kubectl get ansiblemcpservers.mcpserver.ansible.com aap-mcp-server "
        "-n aap-operator --ignore-not-found -o name"
    )
    fake_runner.ok(
        "kubectl get deployment aap-mcp-server -n aap-operator --ignore-not-found -o name"
    )
    fake_runner.ok(
        "kubectl get deployment aap-mcp-server -n aap-operator",
        stdout=json.dumps(
            {
                "spec": {
                    "template": {
                        "spec": {
                            "volumes": [{"name": "ingress-ca"}],
                            "containers": [
                                {
                                    "volumeMounts": [{"name": "ingress-ca"}],
                                    "env": [{"name": "NODE_EXTRA_CA_CERTS"}],
                                }
                            ],
                        }
                    }
                }
            }
        ),
    )
    fake_runner.ok(
        "kubectl get deployment aap-mcp-server -n aap-operator --ignore-not-found -o name"
    )
    fake_runner.ok("kubectl cluster-info")
    fake_runner.ok("kubectl get route aap", stdout="aap-aap-operator.apps.example.test")
    fake_runner.ok("kubectl get ingresses.config/cluster")
    fake_runner.ok(
        "kubectl get secret router-certs-default",
        stdout=json.dumps(
            {"data": {"tls.crt": base64.b64encode(_CERT.encode()).decode()}},
        ),
    )
    fake_runner.ok(
        "kubectl get configmap aap-ingress-ca",
        stdout=json.dumps(
            {
                "metadata": {
                    "labels": {
                        "app.kubernetes.io/managed-by": "aap-demo",
                        "app.kubernetes.io/name": "mcp-server",
                    }
                }
            }
        ),
    )
    fake_runner.ok("kubectl apply")
    fake_runner.ok("kubectl rollout status")
    fake_runner.ok("kubectl patch deployment")
    fake_runner.fail("kubectl get deployment automation-orchestrator-backend")
    fake_runner.fail("kubectl get secret aap-admin-password")


def _deploy(name: str) -> str:
    return str(scripts_root() / name / "deploy.sh")


def _ran(app_ctx) -> list:
    calls = app_ctx.runner.calls
    return [Path(call.argv[1]).parent.name for call in calls if call.argv[0] == "bash"]


def _call(app_ctx, name: str):
    return next(call for call in app_ctx.runner.calls if call.argv[1] == _deploy(name))


def test_ao_is_native_and_its_dependencies_are_legacy() -> None:
    assert isinstance(get("ao"), AoAddon)
    assert get("ao").kind == "native"
    assert get("mcp-server").kind == "native"
    assert get("ollama").kind == "legacy"
    for name in ("ao", "mcp-server", "ollama"):
        assert get(name).public is True
        assert get(name).needs_cluster is True
        assert name in names()


def test_prepare_enables_mcp_server_and_ollama_first(app_ctx, tmp_path) -> None:
    secret = tmp_path / "pull-secret.json"
    secret.write_text("{}", encoding="utf-8")
    app_ctx.config.set("deploy.pull_secret_path", str(secret))
    for name in ("mcp-server", "ollama"):
        app_ctx.runner.ok(["bash", _deploy(name)])

    assert deps.prepare(app_ctx) == str(secret)

    assert _ran(app_ctx) == ["ollama"]
    assert app_ctx.config.get("addons.enabled") == ["mcp-server", "ollama"]
    assert "No product demos are enabled" in app_ctx.console.stdout + app_ctx.console.stderr


def test_enabled_dependencies_are_not_installed_again(app_ctx) -> None:
    app_ctx.config.set("addons.enabled", ["product-demos", "mcp-server", "ollama"])
    deps.prepare(app_ctx)
    assert _ran(app_ctx) == []
    assert "No product demos are enabled" not in app_ctx.console.stdout + app_ctx.console.stderr


def test_a_detected_mcp_server_is_reused_and_recorded(app_ctx) -> None:
    app_ctx.env["AO_LLM_PROVIDER"] = "none"
    app_ctx.config.set("addons.enabled", ["product-demos"])
    app_ctx.runner._rules.insert(
        0,
        (
            (
                "kubectl",
                "get",
                "ansiblemcpservers.mcpserver.ansible.com",
                "aap-mcp-server",
                "-n",
                "aap-operator",
                "--ignore-not-found",
                "-o",
                "name",
            ),
            CompletedCommand(argv=(), returncode=0, stdout="ansiblemcpserver/aap-mcp-server\n"),
        ),
    )
    deps.prepare(app_ctx)
    assert _ran(app_ctx) == []
    assert app_ctx.config.get("addons.enabled") == ["product-demos", "mcp-server"]
    assert "Using the existing MCP Server" in app_ctx.console.stdout + app_ctx.console.stderr


def test_prepare_stops_if_existing_mcp_cannot_be_checked(app_ctx) -> None:
    app_ctx.runner._rules.insert(
        0,
        (
            (
                "kubectl",
                "get",
                "ansiblemcpservers.mcpserver.ansible.com",
                "aap-mcp-server",
                "-n",
                "aap-operator",
                "--ignore-not-found",
                "-o",
                "name",
            ),
            CompletedCommand(argv=(), returncode=1, stderr="forbidden"),
        ),
    )
    with pytest.raises(AddonError, match="Could not determine whether MCP Server is installed"):
        deps.prepare(app_ctx)
    assert _ran(app_ctx) == []


@pytest.mark.parametrize("provider", ["none", "external"])
def test_an_llm_provider_other_than_ollama_skips_ollama(app_ctx, provider) -> None:
    app_ctx.env["AO_LLM_PROVIDER"] = provider
    deps.prepare(app_ctx)
    assert _ran(app_ctx) == []


def test_a_provider_saved_by_the_bash_command_picks_the_dependencies(app_ctx) -> None:
    legacy = app_ctx.paths.legacy_config_file
    legacy.parent.mkdir(parents=True, exist_ok=True)
    legacy.write_text("AO_LLM_PROVIDER=external\n", encoding="utf-8")
    deps.prepare(app_ctx)
    assert _ran(app_ctx) == []


def test_an_unknown_llm_provider_stops_before_any_install(app_ctx) -> None:
    app_ctx.env["AO_LLM_PROVIDER"] = "llama"
    with pytest.raises(UsageError, match="AO_LLM_PROVIDER=llama"):
        get("ao").enable(app_ctx, argparse.Namespace(addon="ao", addon_args=[]))
    assert app_ctx.runner.calls == []


def test_a_failed_dependency_stops_before_ao(app_ctx) -> None:
    app_ctx.runner._rules.insert(
        0,
        (("kubectl", "cluster-info"), CompletedCommand(argv=(), returncode=1)),
    )
    with pytest.raises(AddonError, match="kubectl is not connected"):
        get("ao").enable(app_ctx, argparse.Namespace(addon="ao", addon_args=[]))
    assert _ran(app_ctx) == []
    assert not any(c.argv[:2] == ("kubectl", "create") for c in app_ctx.runner.calls)


def test_product_demos_still_leave_wiring_to_the_command(app_ctx) -> None:
    app_ctx.runner.ok(["bash", _deploy("product-demo-linux")])
    app_ctx.runner.ok(["bash"])
    get("product-demo-linux").enable(app_ctx, argparse.Namespace(addon_args=[]))
    assert _call(app_ctx, "product-demo-linux").env["AAP_DEMO_WIRE_AFTER_DEPLOY"] == "0"


# --- The wheel carries what the bundled scripts load ------------------------

_INCLUDE_RE = re.compile(r"includes/([\w.-]+\.sh)")
_CONFIG_RE = re.compile(r"config/(olm/[\w.-]+\.yaml)")
_ADDON_RE = re.compile(r"REPO_ROOT\}/addons/([\w-]+)/")


def _force_included() -> dict:
    text = (REPO_ROOT / "pyproject.toml").read_text(encoding="utf-8")
    section = text.split("[tool.hatch.build.targets.wheel.force-include]", 1)[1].split("\n[", 1)[0]
    return dict(re.findall(r'^"([^"]+)" = "([^"]+)"$', section, flags=re.M))


def _bundled_scripts() -> list:
    included = _force_included()
    files = [
        path
        for source in included
        if source.startswith(("addons/", "includes"))
        for path in sorted((REPO_ROOT / source).rglob("*.sh"))
    ]
    return files


def test_bundled_paths_mirror_the_repository() -> None:
    for source, target in _force_included().items():
        assert target == f"aap_demo/bundled/{source}"


def test_every_file_a_bundled_script_loads_is_in_the_wheel() -> None:
    included = _force_included()
    for script in _bundled_scripts():
        text = script.read_text(encoding="utf-8")
        for name in _INCLUDE_RE.findall(text):
            assert (REPO_ROOT / "includes" / name).is_file(), (script.name, name)
            assert "includes" in included
        for name in _CONFIG_RE.findall(text):
            if (REPO_ROOT / "config" / name).is_file():
                assert "config/olm" in included, (script.name, name)
        for addon in _ADDON_RE.findall(text):
            if (REPO_ROOT / "addons" / addon).is_dir():
                assert f"addons/{addon}" in included, (script.name, addon)
