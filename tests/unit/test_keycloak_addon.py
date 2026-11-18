"""Keycloak is a native V2 addon, not a shell dispatch."""

from __future__ import annotations

import argparse
import base64
import json

import pytest
import yaml

from aap_demo.addons import get
from aap_demo.core.errors import AddonError


def _namespace(name: str = "aap-demo-keycloak") -> str:
    return json.dumps(
        {
            "metadata": {
                "name": name,
                "labels": {
                    "app.kubernetes.io/managed-by": "aap-demo-keycloak",
                    "app.kubernetes.io/part-of": "aap-demo",
                },
            }
        }
    )


def _runner(app_ctx):
    app_ctx.runner.ok("kubectl cluster-info")
    app_ctx.runner.ok("kubectl get route aap", stdout="aap-aap-operator.apps.example.test")
    app_ctx.runner.ok("kubectl get route", stdout="automation-orchestrator.apps.example.test")
    app_ctx.runner.ok("kubectl get namespace aap-demo-keycloak", stdout=_namespace())
    app_ctx.runner.ok("kubectl create namespace")
    app_ctx.runner.ok("kubectl label namespace")
    app_ctx.runner.ok("kubectl apply", stdout="configured")
    app_ctx.runner.ok("kubectl rollout status")
    app_ctx.runner.ok("kubectl get namespace", stdout=_namespace())
    app_ctx.runner.ok("kubectl delete namespace")
    return app_ctx.runner


def test_keycloak_is_registered_as_a_public_native_addon() -> None:
    addon = get("keycloak")
    assert addon.kind == "native"
    assert addon.public is True
    assert addon.needs_cluster is True


def test_enable_is_idempotent_and_redacts_credentials(app_ctx) -> None:
    runner = _runner(app_ctx)
    args = argparse.Namespace(addon="keycloak", addon_args=[])

    assert get("keycloak").enable(app_ctx, args) == 0
    first = list(app_ctx.paths.addon_dir("keycloak").iterdir())
    assert first
    assert all(path.stat().st_mode & 0o077 == 0 for path in first)
    assert app_ctx.config.get("addons.enabled") == ["keycloak"]
    apply = next(call for call in runner.calls if call.argv[:2] == ("kubectl", "apply"))
    assert "--server-side" in apply.argv
    documents = list(yaml.safe_load_all(apply.input or ""))
    realm = base64.b64decode(documents[1]["data"]["aap-lab-realm.json"]).decode()
    assert "aap-demo-aap groups" in realm
    assert "aap-demo-aap audience" in realm
    assert not (app_ctx.paths.addon_dir("keycloak") / "aap-redirect-uri").exists()
    assert "Credentials:" in app_ctx.console.stdout
    assert "admin-password" not in app_ctx.console.stdout
    assert all(secret.read_text(encoding="utf-8") not in app_ctx.console.stdout for secret in first)

    # A second enable reuses the credentials and reapplies the same desired state.
    assert get("keycloak").enable(app_ctx, args) == 0
    assert len([call for call in runner.calls if call.argv[:2] == ("kubectl", "apply")]) == 2


def test_explicit_redirect_override_allows_custom_https_callback(app_ctx) -> None:
    _runner(app_ctx)
    app_ctx.env = {
        "KEYCLOAK_AAP_REDIRECT_URI": "https://aap.example.test/generated-callback",
        "KEYCLOAK_AO_REDIRECT_URI": "https://ao.example.test/oidc/return",
    }
    assert get("keycloak").enable(app_ctx, argparse.Namespace(addon="keycloak", addon_args=[])) == 0


def test_redirect_override_rejects_query_and_credentials(app_ctx) -> None:
    _runner(app_ctx)
    app_ctx.env = {"KEYCLOAK_AAP_REDIRECT_URI": "https://example.test/callback?token=bad"}
    with pytest.raises(AddonError, match="redirect URI"):
        get("keycloak").enable(app_ctx, argparse.Namespace(addon="keycloak", addon_args=[]))


def test_disable_requires_owned_namespace_and_keeps_credentials(app_ctx) -> None:
    runner = _runner(app_ctx)
    get("keycloak").enable(app_ctx, argparse.Namespace(addon="keycloak", addon_args=[]))
    assert get("keycloak").disable(app_ctx, argparse.Namespace(addon="keycloak")) == 0
    assert app_ctx.paths.addon_dir("keycloak").is_dir()
    assert app_ctx.config.get("addons.enabled") == []
    assert runner.called("kubectl delete namespace aap-demo-keycloak")


def test_disable_refuses_unowned_namespace(app_ctx) -> None:
    app_ctx.runner.ok("kubectl cluster-info")
    app_ctx.runner.ok(
        "kubectl get namespace aap-demo-keycloak",
        stdout=json.dumps({"metadata": {"labels": {"app.kubernetes.io/part-of": "someone-else"}}}),
    )
    with pytest.raises(AddonError, match="unowned namespace"):
        get("keycloak").disable(app_ctx, argparse.Namespace(addon="keycloak"))


def test_enable_refuses_unowned_namespace(app_ctx) -> None:
    app_ctx.runner.ok("kubectl cluster-info")
    app_ctx.runner.ok("kubectl get route aap", stdout="aap-aap-operator.apps.example.test")
    app_ctx.runner.ok("kubectl get route", stdout="automation-orchestrator.apps.example.test")
    app_ctx.runner.ok(
        "kubectl get namespace aap-demo-keycloak",
        stdout=json.dumps({"metadata": {"labels": {"app.kubernetes.io/part-of": "someone-else"}}}),
    )
    with pytest.raises(AddonError, match="unowned namespace"):
        get("keycloak").enable(app_ctx, argparse.Namespace(addon="keycloak", addon_args=[]))
