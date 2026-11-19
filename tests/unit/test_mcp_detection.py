"""Detect an existing MCP addon without modifying the cluster."""

from __future__ import annotations

import pytest

from aap_demo.addons.common import mcp
from aap_demo.cluster import status
from aap_demo.core.errors import AapDemoError

CR = "kubectl get ansiblemcpservers.mcpserver.ansible.com"
DEPLOYMENT = "kubectl get deployment aap-mcp-server"


@pytest.mark.parametrize("kind", ["cr", "deployment"])
def test_detects_either_resource_in_the_selected_namespace(app_ctx, kind) -> None:
    app_ctx.config.set("core.namespace", "custom-aap")
    app_ctx.runner.ok(
        CR, stdout="ansiblemcpserver.mcpserver.ansible.com/aap-mcp-server\n" if kind == "cr" else ""
    )
    app_ctx.runner.ok(
        DEPLOYMENT, stdout="deployment.apps/aap-mcp-server\n" if kind == "deployment" else ""
    )

    assert mcp.installed(app_ctx) is True
    assert all("custom-aap" in call.argv for call in app_ctx.runner.calls)
    assert all(call.env["KUBECONFIG"] == str(app_ctx.kubeconfig) for call in app_ctx.runner.calls)
    assert all(call.timeout == mcp.PROBE_TIMEOUT_SECONDS for call in app_ctx.runner.calls)


def test_absence_including_a_missing_crd_is_not_an_error(app_ctx) -> None:
    app_ctx.runner.fail(
        CR, stderr='error: the server doesn\'t have a resource type "ansiblemcpservers"'
    )
    app_ctx.runner.ok(DEPLOYMENT)
    assert mcp.installed(app_ctx) is False


@pytest.mark.parametrize("error", ["forbidden", "connection refused"])
def test_an_incomplete_check_is_unknown(app_ctx, error) -> None:
    app_ctx.runner.fail(CR, stderr=error)
    app_ctx.runner.ok(DEPLOYMENT)
    assert mcp.installed(app_ctx) is None


def test_detected_deployment_wins_over_a_failed_cr_probe(app_ctx) -> None:
    app_ctx.runner.fail(CR, stderr="forbidden")
    app_ctx.runner.ok(DEPLOYMENT, stdout="deployment.apps/aap-mcp-server\n")
    assert mcp.installed(app_ctx) is True


def test_timed_out_probe_is_unknown(app_ctx) -> None:
    app_ctx.runner.register(CR, AapDemoError("timed out"))
    app_ctx.runner.ok(DEPLOYMENT)
    assert mcp.installed(app_ctx) is None


@pytest.mark.parametrize(
    ("configured", "resource", "expected", "source"),
    [
        (True, None, True, "configured"),
        (False, "found", True, "detected"),
        (False, "absent", False, "absent"),
        (False, "error", None, "unknown"),
    ],
)
def test_addon_status_distinguishes_config_detection_and_unknown(
    app_ctx, configured, resource, expected, source
) -> None:
    if resource == "found":
        app_ctx.runner.ok(CR, stdout="ansiblemcpserver/aap-mcp-server\n")
    elif resource == "absent":
        app_ctx.runner.ok(CR)
        app_ctx.runner.ok(DEPLOYMENT)
    elif resource == "error":
        app_ctx.runner.fail(CR, stderr="forbidden")
        app_ctx.runner.ok(DEPLOYMENT)
    app_ctx.runner.fail("kubectl get namespace automation-orchestrator")
    enabled = ["mcp-server"] if configured else []

    addons = status._addon_statuses(app_ctx, enabled)
    addon = next(item for item in addons if item.name == "mcp-server")

    assert addon.as_dict() == {"name": "mcp-server", "enabled": expected, "source": source}
    report = status.StatusReport(tool_version="test", built="test", cluster_state="running")
    report.addons = [addon]
    status.render_text(app_ctx.console, report)
    label = "unknown" if expected is None else ("enabled" if expected else "disabled")
    assert f"mcp-server      {label}" in app_ctx.console.stdout
    if source in ("configured", "detected"):
        assert f"({source})" in app_ctx.console.stdout
