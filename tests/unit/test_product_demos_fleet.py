"""Fleet host selection for product-demo workflow targets."""

import json

import pytest

from aap_demo.addons.product_demos_fleet import discover_fleet_host, select_fleet_host
from aap_demo.core.errors import AddonError


def pod(name, os_id, ready=True, terminating=False):
    return {
        "metadata": {
            "labels": {
                "app.kubernetes.io/name": "fleet-node",
                "app.kubernetes.io/instance": name,
                "aap-demo/os": os_id,
            },
            **({"deletionTimestamp": "2026-01-01T00:00:00Z"} if terminating else {}),
        },
        "status": {
            "phase": "Running",
            "conditions": [{"type": "Ready", "status": "True" if ready else "False"}],
        },
    }


def service(name):
    return {
        "metadata": {"name": name},
        "spec": {
            "selector": {
                "app.kubernetes.io/name": "fleet-node",
                "app.kubernetes.io/instance": name,
            },
            "ports": [{"port": 22}],
        },
    }


def test_select_fleet_host_prefers_ready_rhel_and_stable_name():
    pods = [pod("other", "debian"), pod("rhel-b", "rhel"), pod("rhel-a", "rhel")]
    assert select_fleet_host(pods) == "rhel-a"


def test_select_fleet_host_falls_back_to_ready_ubi():
    pods = [pod("rhel", "rhel", ready=False), pod("ubi", "ubi9")]
    assert select_fleet_host(pods) == "ubi"


def test_select_fleet_host_rejects_terminating_or_unready_nodes():
    pods = [pod("gone", "ubi9", terminating=True), pod("waiting", "ubi10", ready=False)]
    with pytest.raises(AddonError, match="no suitable.*Fleet"):
        select_fleet_host(pods)


def test_discovery_uses_configured_fleet_namespace(app_ctx):
    app_ctx.config.set("addons.options", {"fleet": {"namespace": "custom-fleet"}})
    app_ctx.runner.ok(
        ["kubectl", "get", "pods"], stdout=json.dumps({"items": [pod("node", "ubi9")]})
    )
    app_ctx.runner.ok(
        ["kubectl", "get", "services"], stdout=json.dumps({"items": [service("node")]})
    )
    assert discover_fleet_host(app_ctx) == "node"
    assert app_ctx.runner.calls[0].argv == (
        "kubectl",
        "get",
        "pods",
        "-n",
        "custom-fleet",
        "-l",
        "app.kubernetes.io/name=fleet-node",
        "-o",
        "json",
    )


def test_discovery_skips_ready_pod_without_matching_ssh_service(app_ctx):
    app_ctx.runner.ok(
        ["kubectl", "get", "pods"],
        stdout=json.dumps({"items": [pod("a", "rhel"), pod("b", "ubi9")]}),
    )
    app_ctx.runner.ok(["kubectl", "get", "services"], stdout=json.dumps({"items": [service("b")]}))
    assert discover_fleet_host(app_ctx) == "b"


def test_discovery_fails_if_no_ready_pod_has_matching_ssh_service(app_ctx):
    app_ctx.runner.ok(["kubectl", "get", "pods"], stdout=json.dumps({"items": [pod("a", "ubi9")]}))
    app_ctx.runner.ok(["kubectl", "get", "services"], stdout='{"items": []}')
    with pytest.raises(AddonError, match="no suitable.*Fleet"):
        discover_fleet_host(app_ctx)


def test_discovery_reports_cluster_errors(app_ctx):
    app_ctx.runner.fail(["kubectl", "get", "pods"], stderr="connection refused")
    with pytest.raises(AddonError, match="could not inspect Fleet pods"):
        discover_fleet_host(app_ctx)
