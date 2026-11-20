"""MCP server is managed through the native V2 Kubernetes lifecycle."""

from __future__ import annotations

import argparse
import base64
import json

import pytest
import yaml

from aap_demo.addons import get, mcp_server
from aap_demo.addons.mcp_server import _apply_ingress_ca, _configure_claude, _generate_token
from aap_demo.core.errors import AddonError
from aap_demo.exec.runner import CompletedCommand

_CERT = "-----BEGIN CERTIFICATE-----\nZm9v\n-----END CERTIFICATE-----"


def _runner(app_ctx, *, deployment_stdout=None):
    if not app_ctx.env.get("HOME"):
        app_ctx.env = {"HOME": str(app_ctx.paths.legacy_dir.parent)}
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
    app_ctx.runner.ok("kubectl create -f -", stdout="created")
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
    app_ctx.runner.fail("kubectl get deployment automation-orchestrator-backend")
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
    runner = _runner(
        app_ctx,
        deployment_stdout=json.dumps(
            {"spec": {"template": {"spec": {"containers": [{"name": "mcp"}]}}}}
        ),
    )
    deployment = {"spec": {"template": {"spec": {"containers": [{"name": "mcp"}]}}}}
    patch_results = []

    def apply_patch(argv):
        operations = json.loads(argv[argv.index("-p") + 1])
        patched = json.loads(json.dumps(deployment))
        for operation in operations:
            tokens = operation["path"].strip("/").split("/")
            parent = patched
            for token in tokens[:-1]:
                parent = parent[int(token)] if isinstance(parent, list) else parent[token]
            key = tokens[-1]
            if isinstance(parent, list):
                assert key == "-"
                parent.append(operation["value"])
            else:
                assert key not in parent
                parent[key] = operation["value"]
        patch_results.append(patched)
        return CompletedCommand(tuple(argv), 0)

    runner._rules.insert(0, (("kubectl", "patch", "deployment"), apply_patch))
    assert get("mcp-server").enable(app_ctx, argparse.Namespace(addon="mcp-server")) == 0
    assert sum(call.argv[:3] == ("kubectl", "rollout", "status") for call in runner.calls) == 2
    patched_spec = patch_results[0]["spec"]["template"]["spec"]
    assert patched_spec["volumes"]
    assert patched_spec["containers"][0]["env"]
    assert patched_spec["containers"][0]["volumeMounts"]


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


def test_enable_recovers_when_ingress_ca_patch_races_with_operator(app_ctx) -> None:
    runner = _runner(
        app_ctx,
        deployment_stdout=json.dumps({"spec": {"template": {"spec": {}}}}),
    )
    configured = json.dumps(
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
    deployment_reads = iter(
        (
            "deployment.apps/aap-mcp-server",
            json.dumps({"spec": {"template": {"spec": {"containers": [{"name": "mcp"}]}}}}),
            configured,
            configured,
        )
    )
    for index, (prefix, _result) in enumerate(runner._rules):
        if prefix == ("kubectl", "get", "deployment", "aap-mcp-server"):
            runner._rules[index] = (
                prefix,
                lambda _argv: CompletedCommand((), 0, next(deployment_reads)),
            )
            break
    else:
        raise AssertionError("deployment read rule not found")
    for index, (prefix, _result) in enumerate(runner._rules):
        if prefix == ("kubectl", "patch", "deployment"):
            runner._rules[index] = (
                prefix,
                CompletedCommand((), 1, stderr="Duplicate value: ingress-ca"),
            )
            break
    else:
        raise AssertionError("deployment patch rule not found")

    assert get("mcp-server").enable(app_ctx, argparse.Namespace(addon="mcp-server")) == 0
    assert runner.called("kubectl get deployment aap-mcp-server")


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


def test_enable_does_not_overwrite_unowned_ingress_ca_configmap(app_ctx) -> None:
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

    with pytest.raises(AddonError, match="already exists and is not managed by mcp-server"):
        _apply_ingress_ca(app_ctx)

    assert not runner.called("kubectl apply -f -")


def test_enable_creates_ingress_ca_configmap_when_absent(app_ctx) -> None:
    runner = _runner(app_ctx)
    runner._rules.insert(
        0,
        (
            ("kubectl", "get", "configmap", "aap-ingress-ca"),
            CompletedCommand(
                argv=("kubectl", "get", "configmap", "aap-ingress-ca"),
                returncode=1,
                stderr='Error from server (NotFound): configmaps "aap-ingress-ca" not found',
            ),
        ),
    )

    _apply_ingress_ca(app_ctx)

    assert runner.called("kubectl create -f -")


def test_enable_skips_token_request_when_claude_is_unavailable(app_ctx, monkeypatch) -> None:
    runner = _runner(app_ctx)
    monkeypatch.setattr(mcp_server.shutil, "which", lambda _name: None)
    runner.ok(
        "kubectl get secret aap-admin-password",
        stdout=base64.b64encode(b"password").decode(),
    )
    runner.ok("curl --silent --show-error --fail", stdout=json.dumps({"token": "unused"}))

    assert get("mcp-server").enable(app_ctx, argparse.Namespace(addon="mcp-server")) == 0

    assert not runner.called("curl")
    assert "Claude CLI was not found" in app_ctx.console.stdout + app_ctx.console.stderr


def test_failed_token_generation_reports_credential_free_recovery(app_ctx, monkeypatch) -> None:
    runner = _runner(app_ctx)
    monkeypatch.setattr(mcp_server.shutil, "which", lambda _name: "/usr/bin/claude")
    runner.fail("kubectl get secret aap-admin-password", stderr="not ready")

    assert get("mcp-server").enable(app_ctx, argparse.Namespace(addon="mcp-server")) == 0

    output = app_ctx.console.stderr
    assert "Claude Code setup was skipped" in output
    assert "rerun aap-demo enable mcp-server" in output
    assert "password" not in output.lower()


def test_failed_claude_replacement_restores_previous_entry(app_ctx, tmp_path, monkeypatch) -> None:
    app_ctx.env = {"HOME": str(tmp_path)}
    config_path = tmp_path / ".claude.json"
    previous = {"type": "http", "url": "https://old.example/mcp", "headers": {"X-Old": "x"}}
    config_path.write_text(json.dumps({"mcpServers": {"aap-demo": previous}}), encoding="utf-8")
    monkeypatch.setattr(mcp_server.shutil, "which", lambda _name: "/usr/bin/claude")
    runner = _runner(app_ctx)
    runner.ok(["claude", "mcp", "remove", "aap-demo", "--scope", "user"])
    runner.fail("claude mcp add aap-demo", stderr="write failed")
    runner.ok(["claude", "mcp", "remove", "aap-demo", "--scope", "user"])
    runner.ok("claude mcp add-json aap-demo")

    assert not _configure_claude(app_ctx, "mcp.apps.example.test", "temporary-secret")

    restore = next(call for call in runner.calls if call.argv[:3] == ("claude", "mcp", "add-json"))
    assert json.loads(restore.argv[4]) == previous
    assert "temporary-secret" not in app_ctx.console.stderr
    assert "previous Claude MCP entry was restored" in app_ctx.console.stderr


def test_claude_connection_failure_includes_host_dns_guidance(
    app_ctx, tmp_path, monkeypatch
) -> None:
    app_ctx.env = {"HOME": str(tmp_path)}
    monkeypatch.setattr(mcp_server.shutil, "which", lambda _name: "/usr/bin/claude")
    app_ctx.paths.ingress_ca.parent.mkdir(parents=True)
    app_ctx.paths.ingress_ca.write_text("test CA", encoding="utf-8")
    runner = _runner(app_ctx)
    runner.ok("claude mcp add aap-demo")
    runner.ok("claude mcp get aap-demo", stdout="✗ Failed to connect")

    assert _configure_claude(app_ctx, "mcp.apps.example.test", "temporary-secret")

    output = app_ctx.console.stdout + app_ctx.console.stderr
    assert str(app_ctx.paths.ingress_ca) in output
    assert "NODE_EXTRA_CA_CERTS" in output
    assert "mcp.apps.example.test" in output
    assert "aap-demo start" in output
    assert (
        next(call for call in runner.calls if call.argv[:3] == ("claude", "mcp", "add")).env is None
    )


def test_disable_keeps_state_when_configmap_inspection_is_forbidden(app_ctx) -> None:
    runner = _runner(app_ctx)
    app_ctx.config.set("addons.enabled", ["mcp-server", "ao"])
    runner._rules.insert(
        0,
        (
            ("kubectl", "get", "configmap", "aap-ingress-ca"),
            CompletedCommand((), 1, stderr="Error from server (Forbidden): denied"),
        ),
    )

    with pytest.raises(AddonError, match="could not read configmap aap-ingress-ca"):
        get("mcp-server").disable(app_ctx, argparse.Namespace(addon="mcp-server"))

    assert app_ctx.config.get("addons.enabled") == ["mcp-server", "ao"]
    assert "MCP Server removed" not in app_ctx.console.stdout


def test_both_mcp_rollouts_use_configured_timeout(app_ctx, monkeypatch) -> None:
    runner = _runner(
        app_ctx,
        deployment_stdout=json.dumps(
            {"spec": {"template": {"spec": {"containers": [{"name": "mcp"}]}}}}
        ),
    )
    monkeypatch.setattr(mcp_server.shutil, "which", lambda _name: None)
    app_ctx.env = {"HOME": str(app_ctx.paths.legacy_dir.parent), "MCP_ROLLOUT_TIMEOUT": "20m"}

    assert get("mcp-server").enable(app_ctx, argparse.Namespace(addon="mcp-server")) == 0

    rollouts = [
        call.argv for call in runner.calls if call.argv[:3] == ("kubectl", "rollout", "status")
    ]
    assert len(rollouts) == 2
    assert all("--timeout=20m" in argv for argv in rollouts)


@pytest.mark.parametrize(("output", "load"), [("json", json.loads), ("yaml", yaml.safe_load)])
def test_structured_enable_includes_addon_and_enabled_fields(
    app_ctx, monkeypatch, output, load
) -> None:
    _runner(app_ctx)
    monkeypatch.setattr(mcp_server.shutil, "which", lambda _name: None)
    app_ctx.output = output
    app_ctx.console.structured = True

    assert get("mcp-server").enable(app_ctx, argparse.Namespace(addon="mcp-server")) == 0

    payload = load(app_ctx.console.stdout)
    assert payload["addon"] == "mcp-server"
    assert payload["enabled"] is True


@pytest.mark.parametrize(("output", "load"), [("json", json.loads), ("yaml", yaml.safe_load)])
def test_structured_disable_includes_addon_and_enabled_fields(app_ctx, output, load) -> None:
    _runner(app_ctx)
    app_ctx.output = output
    app_ctx.console.structured = True
    app_ctx.config.set("addons.enabled", ["mcp-server"])

    assert get("mcp-server").disable(app_ctx, argparse.Namespace(addon="mcp-server")) == 0

    payload = load(app_ctx.console.stdout)
    assert payload["addon"] == "mcp-server"
    assert payload["enabled"] is False


def test_enabling_mcp_runs_ao_wiring_when_ao_is_already_installed(app_ctx, monkeypatch) -> None:
    _runner(app_ctx)
    calls = []
    monkeypatch.setattr(
        "aap_demo.addons.ao.wiring.wire", lambda ctx, namespace: calls.append(namespace)
    )

    assert get("mcp-server").enable(app_ctx, argparse.Namespace(addon="mcp-server")) == 0

    assert calls == [app_ctx.namespace]


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
