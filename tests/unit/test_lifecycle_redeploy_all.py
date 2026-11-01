"""``redeploy-all`` is destroy, a pause, create, then deploy."""

from __future__ import annotations

import argparse

import pytest

from aap_demo.cli import lifecycle
from aap_demo.cluster.deploy import DeployResult
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, PrerequisiteError


def _args() -> argparse.Namespace:
    return argparse.Namespace()


def test_redeploy_all_destroys_creates_then_deploys(app_ctx: AppContext, monkeypatch) -> None:
    order = []

    def destroy(ctx, **kwargs):
        del ctx, kwargs
        order.append("destroy")

    def create(ctx, **kwargs):
        del ctx, kwargs
        order.append("create")

    def ensure(ctx):
        del ctx
        order.append("ensure")

    def run(ctx, **kwargs):
        del ctx, kwargs
        order.append("deploy")
        return DeployResult(aap_name="aap", ready=True)

    monkeypatch.setattr(lifecycle.bootstrap_mod, "destroy", destroy)
    monkeypatch.setattr(lifecycle.bootstrap_mod, "create", create)
    monkeypatch.setattr(lifecycle.deploy_mod, "ensure_cluster_running", ensure)
    monkeypatch.setattr(lifecycle.deploy_mod, "run", run)
    monkeypatch.setattr(lifecycle.time, "sleep", lambda seconds: order.append(f"sleep:{seconds}"))

    assert lifecycle.redeploy_all(app_ctx, _args()) == 0
    assert order == ["destroy", "sleep:2", "create", "ensure", "deploy"]


def test_redeploy_all_creates_when_nothing_exists(app_ctx: AppContext, monkeypatch) -> None:
    order = []

    def destroy(ctx, **kwargs):
        del ctx, kwargs
        raise AapDemoError("No CRC cluster to delete", hint="Run 'aap-demo create' to create one.")

    monkeypatch.setattr(lifecycle.bootstrap_mod, "destroy", destroy)
    monkeypatch.setattr(
        lifecycle.bootstrap_mod, "create", lambda ctx, **kwargs: order.append("create")
    )
    monkeypatch.setattr(lifecycle.deploy_mod, "ensure_cluster_running", lambda ctx: None)
    monkeypatch.setattr(
        lifecycle.deploy_mod,
        "run",
        lambda ctx, **kwargs: DeployResult(ready=True),
    )
    monkeypatch.setattr(lifecycle.time, "sleep", lambda _seconds: None)

    assert lifecycle.redeploy_all(app_ctx, _args()) == 0
    assert order == ["create"]
    assert "No CRC cluster" in app_ctx.console.stdout


def test_redeploy_all_stops_when_delete_fails(app_ctx: AppContext, monkeypatch) -> None:
    monkeypatch.setattr(
        lifecycle.bootstrap_mod,
        "destroy",
        lambda ctx, **kwargs: (_ for _ in ()).throw(AapDemoError("CRC delete failed")),
    )
    monkeypatch.setattr(
        lifecycle.bootstrap_mod,
        "create",
        lambda ctx, **kwargs: pytest.fail("create must not run after a failed delete"),
    )

    with pytest.raises(AapDemoError, match="CRC delete failed"):
        lifecycle.redeploy_all(app_ctx, _args())


def test_redeploy_all_still_requires_crc(app_ctx: AppContext, monkeypatch) -> None:
    def destroy(ctx, **kwargs):
        del ctx, kwargs
        raise PrerequisiteError("CRC (OpenShift Local) is required but not found")

    monkeypatch.setattr(lifecycle.bootstrap_mod, "destroy", destroy)

    with pytest.raises(PrerequisiteError, match="CRC"):
        lifecycle.redeploy_all(app_ctx, _args())
