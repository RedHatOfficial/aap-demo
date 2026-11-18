"""MCP server is managed through the native V2 Kubernetes lifecycle."""

from __future__ import annotations

import argparse
import base64
import json

import pytest
import yaml

from aap_demo.addons import get
from aap_demo.addons.mcp_server import _generate_token
from aap_demo.core.errors import AddonError
from aap_demo.exec.runner import CompletedCommand

_CERT = "-----BEGIN CERTIFICATE-----\nZm9v\n-----END CERTIFICATE-----"


def _runner(app_ctx, *, deployment_stdout=None):
    app_ctx.runner.ok("kubectl cluster-info")
    app_ctx.runner.ok("kubectl get route aap", stdout="aap-aap-operator.apps.example.test")
    app_ctx.runner.ok("kubectl get ingresses.config/cluster", stdout="")
    app_ctx.runner.ok("kubectl apply", stdout="configured")
    app_ctx.runner.ok("kubectl rollout status")
    app_ctx.runner.ok(
        "kubectl get secret router-certs-default",
        stdout=json.dumps({"data": {"tls.crt": base64.b64encode(_CERT.encode()).decode()}}),
    )
    app_ctx.runner.ok("kubectl create configmap", stdout="configured")
    app_ctx.runner.ok("kubectl patch deployment")
    app_ctx.runner.ok(
        "kubectl get deployment aap-mcp-server",
        stdout=deployment_stdout
        or json.dumps(
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
    app_ctx.runner.ok(
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
    app_ctx.runner.fail("kubectl get secret aap-admin-password")
    app_ctx.runner.ok("kubectl delete ansiblemcpserver")
    app_ctx.runner.ok("kubectl delete configmap")
    return app_ctx.runner


def test_mcp_server_is_registered_as_native_addon() -> None:
    addon = get("mcp-server")
    assert addon.kind == "native"
    assert addon.public is True
    assert addon.needs_cluster is True


def test_enable_applies_domain_aware_manifest_and_records_state(app_ctx) -> None:
    runner = _runner(app_ctx)
    assert (
        get("mcp-server").enable(app_ctx, argparse.Namespace(addon="mcp-server", addon_args=[]))
        == 0
    )
    applied = next(call for call in runner.calls if call.argv[:2] == ("kubectl", "apply"))
    document = yaml.safe_load(applied.input or "")
    assert document["spec"]["hostname"] == "aap-mcp-aap-operator.apps.example.test"
    assert document["spec"]["public_base_url"] == "http://aap.aap-operator.svc.cluster.local"
    assert app_ctx.config.get("addons.enabled") == ["mcp-server"]
    assert "MCP Server deployed" in app_ctx.console.stdout


def test_disable_removes_only_mcp_resources(app_ctx) -> None:
    runner = _runner(app_ctx)
    assert get("mcp-server").disable(app_ctx, argparse.Namespace(addon="mcp-server")) == 0
    assert runner.called("kubectl delete ansiblemcpserver aap-mcp-server")
    assert runner.called("kubectl delete configmap aap-ingress-ca")


def test_enable_waits_for_rollout_after_ingress_ca_patch(app_ctx) -> None:
    runner = _runner(app_ctx, deployment_stdout=json.dumps({"spec": {"template": {"spec": {}}}}))
    assert get("mcp-server").enable(app_ctx, argparse.Namespace(addon="mcp-server")) == 0
    assert sum(call.argv[:3] == ("kubectl", "rollout", "status") for call in runner.calls) == 2


def test_malformed_ingress_certificate_is_reported_as_addon_error(app_ctx) -> None:
    runner = _runner(app_ctx)
    runner._rules.insert(
        0,
        (
            ("kubectl", "get", "secret", "router-certs-default"),
            CompletedCommand(
                argv=("kubectl", "get", "secret", "router-certs-default"),
                returncode=0,
                stdout=json.dumps({"data": {"tls.crt": "not-base64"}}),
            ),
        ),
    )
    with pytest.raises(AddonError, match="decode the ingress certificate"):
        get("mcp-server").enable(app_ctx, argparse.Namespace(addon="mcp-server"))


def test_reenable_does_not_duplicate_ingress_ca_configuration(app_ctx) -> None:
    runner = _runner(app_ctx)
    deployment = json.dumps(
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
    )
    runner.ok("kubectl get deployment aap-mcp-server", stdout=deployment)
    assert get("mcp-server").enable(app_ctx, argparse.Namespace(addon="mcp-server")) == 0
    assert not runner.called("kubectl patch deployment")


def test_disable_preserves_unowned_ingress_ca_configmap(app_ctx) -> None:
    runner = _runner(app_ctx)
    runner._rules.insert(
        0,
        (
            ("kubectl", "get", "configmap", "aap-ingress-ca"),
            CompletedCommand(
                argv=("kubectl", "get", "configmap", "aap-ingress-ca"),
                returncode=0,
                stdout=json.dumps(
                    {"metadata": {"labels": {"app.kubernetes.io/managed-by": "other"}}}
                ),
            ),
        ),
    )
    assert get("mcp-server").disable(app_ctx, argparse.Namespace(addon="mcp-server")) == 0
    assert not runner.called("kubectl delete configmap")


def test_token_request_quotes_curl_config_values_and_parses_response(app_ctx) -> None:
    app_ctx.runner.ok(
        "kubectl get secret aap-admin-password",
        stdout=base64.b64encode(b'p@ss"word').decode(),
    )
    app_ctx.runner.ok(
        "curl --silent --show-error --fail",
        stdout=json.dumps({"token": "temporary-token"}),
    )

    assert _generate_token(app_ctx, "aap.apps.example.test") == "temporary-token"
    request = next(call for call in app_ctx.runner.calls if call.argv[0] == "curl")
    assert 'header = "Content-Type: application/json"' in request.input
    assert 'user = "admin:p@ss\\"word"' in request.input
    assert 'data = "{\\"description\\":\\"claude-mcp\\",\\"scope\\":\\"write\\"}"' in request.input


def test_token_request_treats_http_failure_as_no_token(app_ctx) -> None:
    app_ctx.runner.ok(
        "kubectl get secret aap-admin-password",
        stdout=base64.b64encode(b"password").decode(),
    )
    app_ctx.runner.fail("curl --silent --show-error --fail", stderr="HTTP 401")

    assert _generate_token(app_ctx, "aap.apps.example.test") is None
