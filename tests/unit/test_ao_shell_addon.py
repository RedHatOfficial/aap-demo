"""AO and ollama use bundled installers; MCP uses the native V2 addon."""

from __future__ import annotations

import argparse
import base64
import json
import re
from pathlib import Path

import pytest

from aap_demo.addons import get, names
from aap_demo.addons.shell import scripts_root
from aap_demo.core.errors import AddonError, UsageError
from aap_demo.exec.runner import CompletedCommand

REPO_ROOT = Path(__file__).resolve().parents[2]
_CERT = "-----BEGIN CERTIFICATE-----\nZm9v\n-----END CERTIFICATE-----"


@pytest.fixture(autouse=True)
def _tools(monkeypatch, fake_runner) -> None:
    monkeypatch.setattr("aap_demo.addons.shell.shutil.which", lambda name: f"/usr/bin/{name}")
    fake_runner.ok("kubectl get ansiblemcpservers.mcpserver.ansible.com")

    def deployment(args):
        if "name" in args:
            return CompletedCommand(argv=tuple(args), returncode=0)
        return CompletedCommand(
            argv=tuple(args),
            returncode=0,
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

    fake_runner.register("kubectl get deployment aap-mcp-server", deployment)
    fake_runner.ok("kubectl cluster-info")
    fake_runner.ok("kubectl get route aap", stdout="aap-aap-operator.apps.example.test")
    fake_runner.ok("kubectl get ingresses.config/cluster")
    fake_runner.ok(
        "kubectl get secret router-certs-default",
        stdout=json.dumps({"data": {"tls.crt": base64.b64encode(_CERT.encode()).decode()}}),
    )
    fake_runner.ok("kubectl apply")
    fake_runner.ok("kubectl rollout status")
    fake_runner.ok("kubectl patch deployment")
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
    fake_runner.fail("kubectl get secret aap-admin-password")


def _deploy(name: str) -> str:
    return str(scripts_root() / name / "deploy.sh")


def _ran(app_ctx) -> list:
    calls = app_ctx.runner.calls
    return [Path(call.argv[1]).parent.name for call in calls if call.argv[0] == "bash"]


def _call(app_ctx, name: str):
    return next(call for call in app_ctx.runner.calls if call.argv[1] == _deploy(name))


def _enable(app_ctx, *args: str) -> int:
    return get("ao").enable(app_ctx, argparse.Namespace(addon="ao", addon_args=list(args)))


def test_ao_and_ollama_are_public_legacy_addons_and_mcp_is_native() -> None:
    for name in ("ao", "ollama"):
        addon = get(name)
        assert addon.kind == "legacy"
        assert addon.public is True
        assert addon.needs_cluster is True
        assert name in names()
    assert get("mcp-server").kind == "native"
    assert get("mcp-server").public is True


def test_enable_ao_enables_mcp_server_and_ollama_first(app_ctx, tmp_path) -> None:
    secret = tmp_path / "pull-secret.json"
    secret.write_text("{}", encoding="utf-8")
    app_ctx.config.set("deploy.pull_secret_path", str(secret))
    for name in ("mcp-server", "ollama", "ao"):
        app_ctx.runner.ok(["bash", _deploy(name)])

    assert _enable(app_ctx, "--force") == 0

    assert _ran(app_ctx) == ["ollama", "ao"]
    ao = _call(app_ctx, "ao")
    assert ao.argv == ("bash", _deploy("ao"), "--force")
    assert ao.env["AAP_DEMO_WIRE_AFTER_DEPLOY"] == "1"
    assert ao.env["AO_LLM_PROVIDER"] == "ollama"
    assert ao.env["PULL_SECRET_PATH"] == str(secret)
    assert ao.env["KUBECONFIG"] == str(app_ctx.kubeconfig)
    assert ao.env["AAP_DEMO_ENABLED_ADDONS"] == "mcp-server ollama"
    assert app_ctx.config.get("addons.enabled") == ["mcp-server", "ollama", "ao"]
    assert "No product demos are enabled" in app_ctx.console.stdout + app_ctx.console.stderr


def test_enabled_dependencies_are_not_installed_again(app_ctx) -> None:
    app_ctx.config.set("addons.enabled", ["product-demos", "mcp-server", "ollama"])
    app_ctx.runner.ok(["bash", _deploy("ao")])

    assert _enable(app_ctx) == 0

    assert _ran(app_ctx) == ["ao"]
    assert "No product demos are enabled" not in app_ctx.console.stdout + app_ctx.console.stderr


def test_ao_reuses_and_records_a_detected_mcp_server(app_ctx) -> None:
    app_ctx.env["AO_LLM_PROVIDER"] = "none"
    app_ctx.config.set("addons.enabled", ["product-demos"])
    app_ctx.runner._rules.insert(
        0,
        (
            ("kubectl", "get", "ansiblemcpservers.mcpserver.ansible.com"),
            CompletedCommand(argv=(), returncode=0, stdout="ansiblemcpserver/aap-mcp-server\n"),
        ),
    )
    app_ctx.runner.ok(["bash", _deploy("ao")])

    assert _enable(app_ctx) == 0
    assert _ran(app_ctx) == ["ao"]
    assert app_ctx.config.get("addons.enabled") == ["product-demos", "mcp-server", "ao"]
    assert "Using the existing MCP Server" in app_ctx.console.stdout + app_ctx.console.stderr


def test_ao_stops_if_existing_mcp_cannot_be_checked(app_ctx) -> None:
    app_ctx.runner._rules.insert(
        0,
        (
            ("kubectl", "get", "ansiblemcpservers.mcpserver.ansible.com"),
            CompletedCommand(argv=(), returncode=1, stderr="forbidden"),
        ),
    )
    with pytest.raises(AddonError, match="Could not determine whether MCP Server is installed"):
        _enable(app_ctx)
    assert _ran(app_ctx) == []
    assert app_ctx.config.get("addons.enabled") in (None, [])


@pytest.mark.parametrize("provider", ["none", "external"])
def test_an_llm_provider_other_than_ollama_skips_ollama(app_ctx, provider) -> None:
    app_ctx.env["AO_LLM_PROVIDER"] = provider
    for name in ("mcp-server", "ao"):
        app_ctx.runner.ok(["bash", _deploy(name)])

    assert _enable(app_ctx) == 0

    assert _ran(app_ctx) == ["ao"]
    assert _call(app_ctx, "ao").env["AO_LLM_PROVIDER"] == provider


def test_an_unknown_llm_provider_stops_before_any_install(app_ctx) -> None:
    app_ctx.env["AO_LLM_PROVIDER"] = "llama"
    with pytest.raises(UsageError, match="AO_LLM_PROVIDER=llama"):
        _enable(app_ctx)
    assert app_ctx.runner.calls == []


def test_a_failed_dependency_stops_before_ao(app_ctx) -> None:
    app_ctx.env["AO_LLM_PROVIDER"] = "none"
    app_ctx.runner._rules.insert(
        0,
        (("kubectl", "cluster-info"), CompletedCommand(argv=(), returncode=1)),
    )
    with pytest.raises(AddonError, match="kubectl is not connected"):
        _enable(app_ctx)
    assert _ran(app_ctx) == []
    assert app_ctx.config.get("addons.enabled") in (None, [])


def test_the_global_force_flag_reaches_the_installer(app_ctx) -> None:
    app_ctx.config.set("addons.enabled", ["product-demos", "mcp-server", "ollama"])
    app_ctx.force = True
    app_ctx.runner.ok(["bash", _deploy("ao")])

    assert _enable(app_ctx) == 0

    assert _call(app_ctx, "ao").env["FORCE"] == "1"


def test_force_is_not_set_without_the_flag(app_ctx) -> None:
    app_ctx.config.set("addons.enabled", ["product-demos", "mcp-server", "ollama"])
    app_ctx.runner.ok(["bash", _deploy("ao")])

    assert _enable(app_ctx) == 0

    assert "FORCE" not in _call(app_ctx, "ao").env


def test_disable_ao_runs_only_its_delete(app_ctx) -> None:
    app_ctx.config.set("addons.enabled", ["mcp-server", "ollama", "ao"])
    app_ctx.runner.ok(["bash", _deploy("ao"), "--delete"])

    assert get("ao").disable(app_ctx, argparse.Namespace(addon="ao")) == 0

    call = app_ctx.runner.calls[0]
    assert len(app_ctx.runner.calls) == 1
    assert call.argv == ("bash", _deploy("ao"), "--delete")
    assert call.env["AAP_DEMO_WIRE_AFTER_DEPLOY"] == "0"
    assert app_ctx.config.get("addons.enabled") == ["mcp-server", "ollama"]


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
