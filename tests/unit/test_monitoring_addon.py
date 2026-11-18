"""Native monitoring addon contract tests."""

from __future__ import annotations

import argparse
import base64
import json

import pytest

from aap_demo.addons import get
from aap_demo.cli import observe
from aap_demo.core.errors import AddonError


def test_monitoring_is_a_native_public_addon() -> None:
    addon = get("monitoring")
    assert addon.kind == "native"
    assert addon.public is True
    assert addon.needs_cluster is True


def test_enable_applies_owned_monitoring_resources_and_saves_password(app_ctx) -> None:
    addon = get("monitoring")
    app_ctx.runner.ok(
        ["kubectl", "get", "secret", "aap-admin-password"],
        stdout=json.dumps({"data": {"password": base64.b64encode(b"aap-password").decode()}}),
    )
    app_ctx.runner.ok(["kubectl", "apply"])
    app_ctx.runner.ok(["kubectl", "wait"])

    assert addon.enable(app_ctx, argparse.Namespace(addon_args=[])) == 0

    applied = [
        json.loads(document)
        for call in app_ctx.runner.calls
        if call.argv[:2] == ("kubectl", "apply") and call.input
        for document in call.input.split("---")
        if document.strip().startswith("{")
    ]
    assert any(item.get("metadata", {}).get("name") == "aap-monitoring" for item in applied)
    assert any(
        item.get("kind") == "Deployment" and item.get("apiVersion") == "apps/v1" for item in applied
    )
    provisioning = [
        item for item in applied if item.get("metadata", {}).get("name") == "grafana-provisioning"
    ]
    assert provisioning
    assert "datasources.yaml" in provisioning[0]["data"]
    assert "dashboards.yaml" in provisioning[0]["data"]
    password = app_ctx.paths.addon_dir("monitoring") / "grafana-admin-password"
    assert password.exists()
    assert password.stat().st_mode & 0o777 == 0o600
    assert app_ctx.config.get("addons.enabled") == ["monitoring"]


def test_enable_uses_configured_aap_namespace(app_ctx) -> None:
    app_ctx.config.set("core.namespace", "custom-aap")
    app_ctx.runner.ok(
        ["kubectl", "get", "secret", "aap-admin-password"],
        stdout=json.dumps({"data": {"password": base64.b64encode(b"aap-password").decode()}}),
    )
    app_ctx.runner.ok(["kubectl", "apply"])
    app_ctx.runner.ok(["kubectl", "wait"])

    get("monitoring").enable(app_ctx, argparse.Namespace(addon_args=[]))

    apply_call = next(
        call
        for call in app_ctx.runner.calls
        if call.argv[:2] == ("kubectl", "apply")
        and "aap.custom-aap.svc.cluster.local" in call.input
    )
    assert "aap.custom-aap.svc.cluster.local" in apply_call.input


def test_enable_reuses_configured_pull_secret_for_monitoring_images(app_ctx, tmp_path) -> None:
    pull_secret = tmp_path / "pull-secret.json"
    pull_secret.write_text('{"auths":{"quay.io":{"auth":"fixture"}}}\n', encoding="utf-8")
    app_ctx.config.set("deploy.pull_secret_path", str(pull_secret))
    app_ctx.runner.ok(
        ["kubectl", "get", "secret", "aap-admin-password"],
        stdout=json.dumps({"data": {"password": base64.b64encode(b"aap-password").decode()}}),
    )
    app_ctx.runner.ok(["kubectl", "delete", "secret"])
    app_ctx.runner.ok(["kubectl", "create", "secret"])
    app_ctx.runner.ok(["kubectl", "get", "serviceaccount"])
    app_ctx.runner.ok(["kubectl", "patch", "serviceaccount"])
    app_ctx.runner.ok(["kubectl", "apply"])
    app_ctx.runner.ok(["kubectl", "wait"])

    get("monitoring").enable(app_ctx, argparse.Namespace(addon_args=[]))

    create_call = next(
        call for call in app_ctx.runner.calls if call.argv[:3] == ("kubectl", "create", "secret")
    )
    assert f"--from-file=.dockerconfigjson={pull_secret}" in create_call.argv
    assert "--type=kubernetes.io/dockerconfigjson" in create_call.argv
    patch_call = next(
        call
        for call in app_ctx.runner.calls
        if call.argv[:3] == ("kubectl", "patch", "serviceaccount")
    )
    assert '"name": "redhat-operators-pull-secret"' in patch_call.argv[-1]
    assert "fixture" not in patch_call.argv[-1]


def test_disable_deletes_only_owned_namespace(app_ctx) -> None:
    addon = get("monitoring")
    app_ctx.config.set("addons.enabled", ["monitoring"])
    app_ctx.config.save()
    app_ctx.runner.ok(
        ["kubectl", "get", "namespace", "aap-monitoring"],
        stdout=json.dumps(
            {"metadata": {"labels": {"app.kubernetes.io/managed-by": "aap-demo-monitoring"}}}
        ),
    )
    app_ctx.runner.ok(["kubectl", "delete", "namespace", "aap-monitoring"])

    assert addon.disable(app_ctx, argparse.Namespace()) == 0
    assert app_ctx.runner.called(["kubectl", "delete", "namespace", "aap-monitoring"])
    assert app_ctx.config.get("addons.enabled") == []


def test_disable_refuses_unowned_namespace(app_ctx) -> None:
    app_ctx.runner.ok(
        ["kubectl", "get", "namespace", "aap-monitoring"],
        stdout=json.dumps({"metadata": {"labels": {"owner": "someone-else"}}}),
    )

    with pytest.raises(AddonError, match="unowned namespace"):
        get("monitoring").disable(app_ctx, argparse.Namespace())

    assert not app_ctx.runner.called(["kubectl", "delete", "namespace", "aap-monitoring"])


def test_monitoring_rejects_unknown_population_action(app_ctx) -> None:
    with pytest.raises(AddonError, match="unsupported monitoring action"):
        get("monitoring").enable(app_ctx, argparse.Namespace(addon_args=["unknown"]))


def test_status_command_can_target_monitoring(app_ctx) -> None:
    app_ctx.runner.ok(
        ["kubectl", "get", "namespace", "aap-monitoring"],
        stdout=json.dumps({"metadata": {"name": "aap-monitoring"}}),
    )
    app_ctx.runner.ok(
        ["kubectl", "get", "deployment"],
        stdout=json.dumps({"status": {"availableReplicas": 1}}),
    )
    app_ctx.runner.ok(["kubectl", "get", "route", "grafana"], stdout="grafana.example.test\n")

    assert observe.status(app_ctx, argparse.Namespace(addon="monitoring")) == 0
    assert "Monitoring status" in app_ctx.console.stdout
    assert "grafana_route: grafana.example.test" in app_ctx.console.stdout
    assert "readiness: ready" in app_ctx.console.stdout


def test_status_reports_not_ready_when_resources_are_missing(app_ctx) -> None:
    app_ctx.runner.fail(["kubectl", "get", "namespace", "aap-monitoring"], stderr="NotFound")
    app_ctx.runner.ok(["kubectl", "get", "route", "grafana"], stdout="")

    assert observe.status(app_ctx, argparse.Namespace(addon="monitoring")) == 1
    assert "readiness: not-ready" in app_ctx.console.stdout
