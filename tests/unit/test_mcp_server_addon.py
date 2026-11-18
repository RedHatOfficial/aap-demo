"""MCP server is managed through the native V2 Kubernetes lifecycle."""

from __future__ import annotations

import argparse
import base64
import json

import yaml

from aap_demo.addons import get


def _runner(app_ctx):
    app_ctx.runner.ok("kubectl cluster-info")
    app_ctx.runner.ok("kubectl get route aap", stdout="aap-aap-operator.apps.example.test")
    app_ctx.runner.ok("kubectl get ingresses.config/cluster", stdout="")
    app_ctx.runner.ok("kubectl apply", stdout="configured")
    app_ctx.runner.ok("kubectl rollout status")
    app_ctx.runner.ok(
        "kubectl get secret router-certs-default",
        stdout=json.dumps({"data": {"tls.crt": base64.b64encode(b"chain").decode()}}),
    )
    app_ctx.runner.ok("kubectl create configmap", stdout="configured")
    app_ctx.runner.ok("kubectl patch deployment")
    app_ctx.runner.ok(
        "kubectl get deployment aap-mcp-server", stdout="deployment.apps/aap-mcp-server"
    )
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
