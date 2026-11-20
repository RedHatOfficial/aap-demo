"""AO catalog and OLM port (ADR-045)."""

from __future__ import annotations

import json
from typing import Dict, List

import pytest
import yaml

from aap_demo.addons.ao import catalog, olm
from aap_demo.addons.ao.postgres import NAMESPACE
from aap_demo.cluster import catalog_signature
from aap_demo.core.errors import AddonError, UsageError
from aap_demo.exec.runner import CompletedCommand, FakeRunner

AAP_INDEX = "registry.redhat.io/redhat/redhat-operator-index:v4.22"


def _ok(stdout: str = "") -> CompletedCommand:
    return CompletedCommand(argv=(), returncode=0, stdout=stdout)


@pytest.fixture
def ready_catalogs(monkeypatch):
    monkeypatch.setattr(catalog_signature, "ensure_policy", lambda ctx: True)
    monkeypatch.setattr(
        catalog_signature,
        "wait_for_catalog_ready",
        lambda *a, **k: catalog_signature.CatalogWait(outcome=catalog_signature.READY, elapsed=0),
    )


# -- manifests --------------------------------------------------------------------


def test_address_catalogsource_proxies_a_service() -> None:
    document = yaml.safe_load(catalog.address_catalogsource("redhat-operators", NAMESPACE, "x:1"))
    assert document["metadata"] == {"name": "redhat-operators", "namespace": NAMESPACE}
    assert document["spec"]["address"] == "x:1"
    assert "image" not in document["spec"] and "secrets" not in document["spec"]


def test_image_catalogsource_sets_the_index() -> None:
    document = yaml.safe_load(catalog.image_catalogsource("redhat-operators", NAMESPACE, "idx:1"))
    assert document["spec"]["image"] == "idx:1"
    assert document["metadata"]["namespace"] == NAMESPACE


def test_registry_manifest_renames_and_repoints() -> None:
    text = catalog.registry_manifest("ao-fallback-registry", "aap-operator", "idx:fallback")
    assert "redhat-operators-registry" not in text
    deployment = next(d for d in yaml.safe_load_all(text) if d["kind"] == "Deployment")
    assert deployment["metadata"]["name"] == "ao-fallback-registry"
    images = [c["image"] for c in deployment["spec"]["template"]["spec"]["containers"]]
    assert images == ["idx:fallback"]


# -- index selection and CatalogSource ----------------------------------------------


def _catalog_runner(*, source_image: str, current_image: str = "") -> FakeRunner:
    def spec_image(args):
        namespace = args[args.index("-n") + 1]
        return _ok(source_image if namespace == "aap-operator" else current_image)

    return (
        FakeRunner()
        .register(["kubectl", "get", "catalogsource", "*", "-n", "*", "-o"], spec_image)
        .ok("kubectl get catalogsource redhat-operators -n aap-operator")
        .ok("kubectl get packagemanifest", "redhat-operators")
        .ok("kubectl get secret redhat-operators-pull-secret", "e30=")
        .ok("kubectl apply -f -")
        .ok("kubectl delete")
        .ok("kubectl rollout status")
    )


def test_index_prefers_the_environment(app_ctx) -> None:
    app_ctx.env = {"AO_INDEX_IMAGE": "custom:1"}
    state = catalog.Catalog()
    assert catalog.select_index(app_ctx, state) == "custom:1"


def test_index_reuses_aaps_catalog(app_ctx) -> None:
    app_ctx.runner = _catalog_runner(source_image=AAP_INDEX)
    assert catalog.select_index(app_ctx, catalog.Catalog()) == AAP_INDEX


def test_same_index_proxies_aaps_catalog_service(app_ctx, ready_catalogs) -> None:
    app_ctx.runner = _catalog_runner(source_image=AAP_INDEX)
    catalog.ensure(app_ctx, catalog.Catalog(), sleep=lambda _s: None)
    applied = [yaml.safe_load(call.input or "") for call in app_ctx.runner.calls if call.input]
    sources = [d for d in applied if d.get("kind") == "CatalogSource"]
    assert sources[-1]["spec"]["address"] == "redhat-operators.aap-operator.svc:50051"
    assert sources[-1]["metadata"]["namespace"] == NAMESPACE


def test_different_index_runs_a_fallback_registry(app_ctx, ready_catalogs) -> None:
    app_ctx.env = {"AO_INDEX_IMAGE": "fallback:1"}
    app_ctx.runner = _catalog_runner(source_image=AAP_INDEX)

    def packages(args):
        return _ok("ao-fallback" if "aap-operator" in args else "redhat-operators")

    app_ctx.runner._rules.insert(0, (("kubectl", "get", "packagemanifest"), packages))
    catalog.ensure(app_ctx, catalog.Catalog(), sleep=lambda _s: None)
    applied = [call.input or "" for call in app_ctx.runner.calls if call.input]
    assert any("ao-fallback-registry" in text and "fallback:1" in text for text in applied)
    final = yaml.safe_load(applied[-1])
    assert final["spec"]["address"] == "ao-fallback-registry.aap-operator.svc:50051"


def test_aap_catalog_must_be_ready(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr(catalog_signature, "catalog_state", lambda *a, **k: "TRANSIENT_FAILURE")
    app_ctx.runner = FakeRunner().ok("kubectl get catalogsource redhat-operators -n aap-operator")
    with pytest.raises(AddonError, match="not READY"):
        catalog.require_aap_catalog(app_ctx)


# -- OLM ------------------------------------------------------------------------


def test_invalid_approval_mode_is_a_usage_error(app_ctx) -> None:
    app_ctx.env = {"AO_INSTALL_PLAN_APPROVAL": "Sometimes"}
    with pytest.raises(UsageError):
        olm.approval(app_ctx)


def test_approval_keeps_the_subscriptions_mode(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok("kubectl get subscription", "Manual")
    assert olm.approval(app_ctx) == "Manual"


def _plans(items: List[Dict]) -> str:
    return json.dumps({"items": items})


def test_pending_installplans_are_owned_and_unapproved(app_ctx) -> None:
    owner = [{"kind": "Subscription", "name": olm.SUBSCRIPTION}]
    items = [
        {"metadata": {"name": "ip-owned", "ownerReferences": owner}, "spec": {"approved": False}},
        {"metadata": {"name": "ip-done", "ownerReferences": owner}, "spec": {"approved": True}},
        {"metadata": {"name": "ip-other"}, "spec": {"approved": False}},
        {"metadata": {"name": "ip-current"}, "spec": {"approved": False}},
    ]
    app_ctx.runner = (
        FakeRunner()
        .ok("kubectl get installplan -n", _plans(items))
        .ok("kubectl get subscription", "ip-current")
    )
    assert olm.pending_installplans(app_ctx) == ["ip-owned", "ip-current"]


def _install_runner(*, csv_after: int, conditions: List[Dict]) -> FakeRunner:
    state = {"polls": 0}

    def csvs(_args):
        state["polls"] += 1
        return _ok(
            "clusterserviceversion/automation-orchestrator.v1" if state["polls"] > csv_after else ""
        )

    owner = [{"kind": "Subscription", "name": olm.SUBSCRIPTION}]
    plans = _plans([{"metadata": {"name": "ip-1", "ownerReferences": owner}, "spec": {}}])
    return (
        FakeRunner()
        .ok("kubectl delete")
        .ok("kubectl apply -f -")
        .ok("kubectl get installplan -n", plans)
        .ok(
            [
                "kubectl",
                "get",
                "subscription",
                olm.SUBSCRIPTION,
                "-n",
                NAMESPACE,
                "-o",
                "~^jsonpath=",
            ]
        )
        .ok(
            ["kubectl", "get", "subscription", olm.SUBSCRIPTION, "-n", NAMESPACE, "-o", "json"],
            json.dumps({"status": {"conditions": conditions}}),
        )
        .register("kubectl get csv", csvs)
        .ok("kubectl patch installplan")
        .ok("kubectl get packagemanifest", "redhat-operators")
        .ok("kubectl get catalogsource", "")
    )


def test_automatic_install_approves_the_plan(app_ctx) -> None:
    app_ctx.runner = _install_runner(csv_after=1, conditions=[])
    olm.install(app_ctx, catalog.Catalog(), "aap-operator", mode="Automatic", sleep=lambda _s: None)
    assert app_ctx.runner.called("kubectl patch installplan ip-1")


def test_manual_install_waits_without_approving(app_ctx) -> None:
    app_ctx.runner = _install_runner(csv_after=10_000, conditions=[])
    with pytest.raises(AddonError, match="manual InstallPlan approval.*ip-1"):
        olm.install(
            app_ctx, catalog.Catalog(), "aap-operator", mode="Manual", sleep=lambda _s: None
        )
    assert not app_ctx.runner.called("kubectl patch installplan")


def test_unresolvable_subscription_resets_once_then_reports(app_ctx) -> None:
    app_ctx.env = {"AO_DISABLE_INDEX_FALLBACK": "1"}
    failed = [{"type": "ResolutionFailed", "status": "True", "message": "nope"}]
    app_ctx.runner = _install_runner(csv_after=10_000, conditions=failed)
    with pytest.raises(AddonError, match="could not resolve"):
        olm.install(
            app_ctx, catalog.Catalog(), "aap-operator", mode="Automatic", sleep=lambda _s: None
        )
    subscriptions_applied = [
        call for call in app_ctx.runner.calls if call.input and "kind: Subscription" in call.input
    ]
    assert len(subscriptions_applied) == 2
