"""Native monitoring addon contract tests."""

from __future__ import annotations

import argparse
import base64
import json
import os

import pytest

from aap_demo.addons import get
from aap_demo.addons.monitoring import NAMESPACE_UID, OWNERSHIP_TOKEN, OWNERSHIP_TOKEN_LABEL
from aap_demo.cli import observe
from aap_demo.core.errors import AddonError
from aap_demo.exec.runner import CompletedCommand


def _configure_monitoring_credentials(app_ctx) -> None:
    app_ctx.env.update(
        {
            "AAP_MONITORING_CREDENTIAL_SECRET": "monitoring-reader",  # pragma: allowlist secret
            "AAP_MONITORING_GATEWAY_URL": "https://aap.example.test",
        }
    )
    app_ctx.runner.ok(
        ["kubectl", "get", "secret", "monitoring-reader"],
        stdout=json.dumps(
            {
                "data": {
                    "username": base64.b64encode(b"monitoring").decode(),
                    "password": base64.b64encode(b"read-only-password").decode(),
                }
            }
        ),
    )
    app_ctx.runner.ok(
        ["kubectl", "get", "secret", "router-ca"],
        stdout=json.dumps({"data": {"tls.crt": base64.b64encode(b"route-ca").decode()}}),
    )


def _register_ready_deployments(app_ctx) -> None:
    app_ctx.runner.ok(
        ["kubectl", "get", "deployment"],
        stdout=json.dumps(
            {
                "metadata": {"generation": 1},
                "spec": {"replicas": 1},
                "status": {
                    "replicas": 1,
                    "observedGeneration": 1,
                    "updatedReplicas": 1,
                    "readyReplicas": 1,
                    "availableReplicas": 1,
                },
            }
        ),
    )


def test_monitoring_is_a_native_public_addon() -> None:
    addon = get("monitoring")
    assert addon.kind == "native"
    assert addon.public is True
    assert addon.needs_cluster is True


def test_enable_applies_owned_monitoring_resources_and_saves_password(app_ctx) -> None:
    addon = get("monitoring")
    _configure_monitoring_credentials(app_ctx)
    namespace_reads = iter(
        [
            CompletedCommand(
                argv=("kubectl", "get", "namespace", "aap-monitoring"),
                returncode=1,
                stderr="NotFound",
            ),
            CompletedCommand(
                argv=("kubectl", "get", "namespace", "aap-monitoring"),
                returncode=0,
                stdout=json.dumps({"metadata": {"uid": "monitoring-uid"}}),
            ),
        ]
    )
    app_ctx.runner.register(
        ["kubectl", "get", "namespace", "aap-monitoring"], lambda _: next(namespace_reads)
    )
    app_ctx.runner.ok(["kubectl", "create", "-f", "-"])
    app_ctx.runner.ok(["kubectl", "apply"])
    app_ctx.runner.ok(["kubectl", "rollout", "restart"])
    app_ctx.runner.ok(["kubectl", "rollout", "status"])
    app_ctx.runner.ok(["kubectl", "wait"])
    app_ctx.runner.ok(
        ["kubectl", "get", "route", "grafana"],
        stdout=json.dumps(
            {
                "status": {
                    "ingress": [
                        {
                            "host": "grafana.example.test",
                            "conditions": [{"type": "Admitted", "status": "True"}],
                        }
                    ]
                }
            }
        ),
    )
    _register_ready_deployments(app_ctx)

    assert addon.enable(app_ctx, argparse.Namespace(addon_args=[])) == 0

    applied = [
        json.loads(document)
        for call in app_ctx.runner.calls
        if call.argv[:2] == ("kubectl", "apply") and call.input
        for document in call.input.split("---")
        if document.strip().startswith("{")
    ]
    assert any(
        '"name": "aap-monitoring"' in (call.input or "")
        for call in app_ctx.runner.calls
        if call.argv[:3] == ("kubectl", "create", "-f")
    )
    assert any(
        item.get("kind") == "Deployment" and item.get("apiVersion") == "apps/v1" for item in applied
    )
    policies = [item for item in applied if item.get("kind") == "NetworkPolicy"]
    assert policies
    policy = policies[0]
    assert {port["port"] for port in policy["spec"]["egress"][0]["ports"]} == {8000, 443}
    dns_ports = [
        port["port"]
        for rule in policy["spec"]["egress"]
        if rule["to"][0]
        .get("namespaceSelector", {})
        .get("matchLabels", {})
        .get("kubernetes.io/metadata.name")
        in {"kube-system", "openshift-dns"}
        for port in rule["ports"]
    ]
    assert 5353 in dns_ports
    assert (
        policy["spec"]["ingress"][0]["from"][0]["podSelector"]["matchLabels"][
            "app.kubernetes.io/name"
        ]
        == "prometheus"
    )
    assert (
        policy["spec"]["egress"][0]["to"][0]["podSelector"]["matchLabels"][
            "app.kubernetes.io/component"
        ]
        == "aap-gateway"
    )
    assert any(
        rule["to"][0]["namespaceSelector"]["matchLabels"].get("kubernetes.io/metadata.name")
        == "openshift-dns"
        for rule in policy["spec"]["egress"]
    )
    provisioning = [
        item for item in applied if item.get("metadata", {}).get("name") == "grafana-provisioning"
    ]
    assert provisioning
    assert "datasources.yaml" in provisioning[0]["data"]
    assert "dashboards.yaml" in provisioning[0]["data"]
    password = app_ctx.paths.addon_dir("monitoring") / "grafana-admin-password"
    assert password.exists()
    if os.name != "nt":
        assert password.stat().st_mode & 0o777 == 0o600
    assert app_ctx.config.get("addons.enabled") == ["monitoring"]


def test_enable_requires_an_explicit_https_read_only_credential(app_ctx) -> None:
    app_ctx.runner.fail(["kubectl", "get", "namespace", "aap-monitoring"], stderr="NotFound")
    app_ctx.env["AAP_MONITORING_CREDENTIAL_SECRET"] = "reader"  # pragma: allowlist secret
    app_ctx.env["AAP_MONITORING_GATEWAY_URL"] = "http://aap.example.test"

    with pytest.raises(AddonError, match="HTTPS Gateway credential"):
        get("monitoring").enable(app_ctx, argparse.Namespace(addon_args=[]))


def test_enable_uses_configured_aap_namespace(app_ctx) -> None:
    _configure_monitoring_credentials(app_ctx)
    app_ctx.config.set("core.namespace", "custom-aap")
    namespace_reads = iter(
        [
            CompletedCommand(
                argv=("kubectl", "get", "namespace", "aap-monitoring"),
                returncode=1,
                stderr="NotFound",
            ),
            CompletedCommand(
                argv=("kubectl", "get", "namespace", "aap-monitoring"),
                returncode=0,
                stdout=json.dumps({"metadata": {"uid": "monitoring-uid"}}),
            ),
        ]
    )
    app_ctx.runner.register(
        ["kubectl", "get", "namespace", "aap-monitoring"], lambda _: next(namespace_reads)
    )
    app_ctx.runner.ok(["kubectl", "create", "-f", "-"])
    app_ctx.runner.ok(["kubectl", "apply"])
    app_ctx.runner.ok(["kubectl", "rollout", "restart"])
    app_ctx.runner.ok(["kubectl", "rollout", "status"])
    app_ctx.runner.ok(["kubectl", "wait"])
    app_ctx.runner.ok(
        ["kubectl", "get", "route", "grafana"],
        stdout=json.dumps(
            {
                "status": {
                    "ingress": [
                        {
                            "host": "grafana.example.test",
                            "conditions": [{"type": "Admitted", "status": "True"}],
                        }
                    ]
                }
            }
        ),
    )
    _register_ready_deployments(app_ctx)

    get("monitoring").enable(app_ctx, argparse.Namespace(addon_args=[]))

    apply_call = next(
        call
        for call in app_ctx.runner.calls
        if call.argv[:2] == ("kubectl", "apply") and "https://aap.example.test" in call.input
    )
    assert "https://aap.example.test" in apply_call.input


def test_enable_refuses_unowned_namespace_before_writing_state(app_ctx) -> None:
    app_ctx.runner.ok(
        ["kubectl", "get", "namespace", "aap-monitoring"],
        stdout=json.dumps({"metadata": {"labels": {"owner": "someone-else"}}}),
    )

    with pytest.raises(AddonError, match="unowned namespace"):
        get("monitoring").enable(app_ctx, argparse.Namespace(addon_args=[]))

    assert not app_ctx.runner.called(["kubectl", "get", "secret", "aap-admin-password"])
    assert not app_ctx.runner.called(["kubectl", "apply"])


def test_enable_reuses_configured_pull_secret_for_monitoring_images(app_ctx, tmp_path) -> None:
    _configure_monitoring_credentials(app_ctx)
    pull_secret = tmp_path / "pull-secret.json"
    pull_secret.write_text('{"auths":{"quay.io":{"auth":"fixture"}}}\n', encoding="utf-8")
    app_ctx.config.set("deploy.pull_secret_path", str(pull_secret))
    namespace_reads = iter(
        [
            CompletedCommand(
                argv=("kubectl", "get", "namespace", "aap-monitoring"),
                returncode=1,
                stderr="NotFound",
            ),
            CompletedCommand(
                argv=("kubectl", "get", "namespace", "aap-monitoring"),
                returncode=0,
                stdout=json.dumps({"metadata": {"uid": "monitoring-uid"}}),
            ),
        ]
    )
    app_ctx.runner.register(
        ["kubectl", "get", "namespace", "aap-monitoring"], lambda _: next(namespace_reads)
    )
    app_ctx.runner.ok(["kubectl", "delete", "secret"])
    app_ctx.runner.ok(["kubectl", "create", "secret"])
    app_ctx.runner.ok(["kubectl", "get", "serviceaccount"])
    app_ctx.runner.ok(["kubectl", "patch", "serviceaccount"])
    app_ctx.runner.ok(["kubectl", "create", "-f", "-"])
    app_ctx.runner.ok(["kubectl", "apply"])
    app_ctx.runner.ok(["kubectl", "rollout", "restart"])
    app_ctx.runner.ok(["kubectl", "rollout", "status"])
    app_ctx.runner.ok(["kubectl", "wait"])
    app_ctx.runner.ok(
        ["kubectl", "get", "route", "grafana"],
        stdout=json.dumps(
            {
                "status": {
                    "ingress": [
                        {
                            "host": "grafana.example.test",
                            "conditions": [{"type": "Admitted", "status": "True"}],
                        }
                    ]
                }
            }
        ),
    )
    _register_ready_deployments(app_ctx)

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
    state_dir = app_ctx.paths.addon_dir("monitoring")
    state_dir.mkdir(parents=True)
    (state_dir / OWNERSHIP_TOKEN).write_text("token\n", encoding="utf-8")
    (state_dir / NAMESPACE_UID).write_text("monitoring-uid\n", encoding="utf-8")
    app_ctx.runner.ok(
        ["kubectl", "get", "namespace", "aap-monitoring"],
        stdout=json.dumps(
            {
                "metadata": {
                    "uid": "monitoring-uid",
                    "labels": {
                        "app.kubernetes.io/managed-by": "aap-demo-monitoring",
                        OWNERSHIP_TOKEN_LABEL: "token",
                    },
                }
            }
        ),
    )
    app_ctx.runner.ok(["kubectl", "delete", "--raw"])

    assert addon.disable(app_ctx, argparse.Namespace()) == 0
    assert app_ctx.runner.called(["kubectl", "delete", "--raw"])
    delete_call = next(
        call for call in app_ctx.runner.calls if call.argv[:3] == ("kubectl", "delete", "--raw")
    )
    assert '"uid": "monitoring-uid"' in delete_call.input
    assert app_ctx.config.get("addons.enabled") == []


def test_disable_refuses_unowned_namespace(app_ctx) -> None:
    app_ctx.runner.ok(
        ["kubectl", "get", "namespace", "aap-monitoring"],
        stdout=json.dumps({"metadata": {"labels": {"owner": "someone-else"}}}),
    )

    with pytest.raises(AddonError, match="unowned namespace"):
        get("monitoring").disable(app_ctx, argparse.Namespace())

    assert not app_ctx.runner.called(["kubectl", "delete", "--raw"])


def test_monitoring_rejects_unknown_population_action(app_ctx) -> None:
    with pytest.raises(AddonError, match="unsupported monitoring action"):
        get("monitoring").enable(app_ctx, argparse.Namespace(addon_args=["unknown"]))


def test_disable_is_safe_when_namespace_is_already_absent(app_ctx) -> None:
    app_ctx.runner.fail(["kubectl", "get", "namespace", "aap-monitoring"], stderr="NotFound")

    assert get("monitoring").disable(app_ctx, argparse.Namespace()) == 0
    assert not app_ctx.runner.called(["kubectl", "delete"])


def test_status_command_can_target_monitoring(app_ctx) -> None:
    app_ctx.runner.ok(
        ["kubectl", "get", "namespace", "aap-monitoring"],
        stdout=json.dumps({"metadata": {"name": "aap-monitoring"}}),
    )
    app_ctx.runner.ok(
        ["kubectl", "get", "deployment"],
        stdout=json.dumps(
            {
                "metadata": {"generation": 1},
                "spec": {"replicas": 1},
                "status": {
                    "replicas": 1,
                    "observedGeneration": 1,
                    "updatedReplicas": 1,
                    "readyReplicas": 1,
                    "availableReplicas": 1,
                },
            }
        ),
    )
    app_ctx.runner.ok(
        ["kubectl", "get", "route", "grafana"],
        stdout=json.dumps(
            {
                "status": {
                    "ingress": [
                        {
                            "host": "grafana.example.test",
                            "conditions": [{"type": "Admitted", "status": "True"}],
                        }
                    ]
                }
            }
        ),
    )

    assert observe.status(app_ctx, argparse.Namespace(addon="monitoring")) == 0
    assert "Monitoring status" in app_ctx.console.stdout
    assert "grafana_route: grafana.example.test" in app_ctx.console.stdout
    assert "readiness: ready" in app_ctx.console.stdout


def test_status_reports_not_ready_when_resources_are_missing(app_ctx) -> None:
    app_ctx.runner.fail(["kubectl", "get", "namespace", "aap-monitoring"], stderr="NotFound")
    app_ctx.runner.fail(["kubectl", "get", "route", "grafana"], stderr="NotFound")

    assert observe.status(app_ctx, argparse.Namespace(addon="monitoring")) == 1
    assert "readiness: not-ready" in app_ctx.console.stdout
