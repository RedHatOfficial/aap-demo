"""AoAddon step order: install, adopt, --force and disable (ADR-045)."""

from __future__ import annotations

import argparse
from typing import List

import pytest

import aap_demo.addons.ao as ao_pkg
from aap_demo.addons.ao import AoAddon
from aap_demo.core.errors import AddonError

STEPS = [
    ("deps", "prepare", ""),
    ("postgres", "cnpg_cluster", ""),
    ("instance", "replica_count", 1),
    ("instance", "ingress_host", "automation-orchestrator.apps.example"),
    ("instance", "already_running", None),
    ("catalog", "grant_sccs", None),
    ("admin", "ensure", None),
    ("catalog", "require_aap_catalog", None),
    ("catalog", "ensure", None),
    ("catalog", "package_in_catalog", True),
    ("postgres", "legacy_secrets_present", False),
    ("postgres", "reset_storage", None),
    ("postgres", "ensure_database_secrets", None),
    ("postgres", "apply_manifest", None),
    ("postgres", "ensure_ca", None),
    ("postgres", "wait_ready", None),
    ("postgres", "ensure_databases", None),
    ("olm", "approval", "Automatic"),
    ("olm", "clear_for_force", None),
    ("olm", "install", None),
    ("olm", "wait_available", None),
    ("olm", "link_pull_secret", None),
    ("olm", "set_approval", None),
    ("admin", "generate", None),
    ("instance", "apply", None),
    ("postgres", "reconcile", None),
    ("instance", "wait_ready", None),
    ("instance", "configure_local_access", None),
    ("instance", "allow_aap_ingress", None),
    ("admin", "saved", "pw"),
    ("instance", "show_access", None),
    ("wiring", "wire", None),
]


@pytest.fixture
def steps(monkeypatch, app_ctx) -> List[str]:
    seen: List[str] = []
    for module, name, result in STEPS:
        target = getattr(ao_pkg, module)

        def fake(*_a, _label=f"{module}.{name}", _result=result, **_k):
            seen.append(_label)
            return _result

        monkeypatch.setattr(target, name, fake)
    app_ctx.runner.ok("kubectl create").ok("kubectl get namespace")
    return seen


def _enable(app_ctx) -> int:
    return AoAddon(sleep=lambda _s: None).enable(app_ctx, argparse.Namespace(addon="ao"))


def _index(seen: List[str], label: str) -> int:
    return seen.index(label)


def test_fresh_install_order(app_ctx, steps) -> None:
    assert _enable(app_ctx) == 0
    order = [
        "deps.prepare",
        "admin.ensure",
        "catalog.ensure",
        "postgres.ensure_database_secrets",
        "postgres.apply_manifest",
        "postgres.ensure_ca",
        "postgres.ensure_databases",
        "olm.install",
        "olm.wait_available",
        "instance.apply",
        "instance.wait_ready",
        "instance.configure_local_access",
        "wiring.wire",
    ]
    assert [_index(steps, label) for label in order] == sorted(
        _index(steps, label) for label in order
    )
    assert "postgres.reset_storage" not in steps
    assert "admin.generate" not in steps
    assert app_ctx.config.get("addons.enabled") == ["ao"]


def test_force_resets_the_database_and_admin_password(app_ctx, steps) -> None:
    app_ctx.force = True
    assert _enable(app_ctx) == 0
    assert "admin.ensure" not in steps
    assert _index(steps, "postgres.reset_storage") < _index(steps, "postgres.apply_manifest")
    assert _index(steps, "olm.clear_for_force") < _index(steps, "olm.install")
    assert _index(steps, "admin.generate") < _index(steps, "instance.apply")


def test_running_ao_is_adopted_without_reinstall(app_ctx, steps, monkeypatch) -> None:
    def running(*_a, **_k):
        steps.append("instance.already_running")
        return (8, 8)

    monkeypatch.setattr(ao_pkg.instance, "already_running", running)
    assert _enable(app_ctx) == 0
    assert "catalog.ensure" not in steps and "olm.install" not in steps
    assert _index(steps, "catalog.grant_sccs") < _index(steps, "instance.apply")
    assert _index(steps, "instance.apply") < _index(steps, "postgres.reconcile")
    assert "wiring.wire" in steps


def test_running_cnpg_ao_is_left_alone(app_ctx, steps, monkeypatch) -> None:
    monkeypatch.setattr(ao_pkg.instance, "already_running", lambda *_a, **_k: (8, 8))
    monkeypatch.setattr(ao_pkg.postgres, "cnpg_cluster", lambda *_a, **_k: "cluster/x")
    assert _enable(app_ctx) == 0
    assert "instance.apply" not in steps and "postgres.reconcile" not in steps
    assert "CloudNativePG" in app_ctx.console.stdout + app_ctx.console.stderr


def test_cnpg_install_needs_force(app_ctx, steps, monkeypatch) -> None:
    monkeypatch.setattr(ao_pkg.postgres, "cnpg_cluster", lambda *_a, **_k: "cluster/x")
    with pytest.raises(AddonError, match="CloudNativePG"):
        _enable(app_ctx)
    assert "postgres.apply_manifest" not in steps


def test_legacy_secrets_need_force(app_ctx, steps, monkeypatch) -> None:
    monkeypatch.setattr(ao_pkg.postgres, "legacy_secrets_present", lambda *_a, **_k: True)
    with pytest.raises(AddonError, match="Legacy PostgreSQL credentials"):
        _enable(app_ctx)
    assert "postgres.reset_storage" not in steps


def test_disable_keeps_the_password_and_waits_for_the_namespace(app_ctx, monkeypatch) -> None:
    seen: List[str] = []
    monkeypatch.setattr(ao_pkg.admin, "save", lambda ctx: seen.append("save"))
    monkeypatch.setattr(ao_pkg.instance, "remove_finalizers", lambda ctx: seen.append("fin"))
    monkeypatch.setattr(ao_pkg.olm, "cleanup", lambda ctx, ns: seen.append("olm"))
    monkeypatch.setattr(ao_pkg.olm, "cleanup_early_access", lambda ctx: seen.append("ea"))
    monkeypatch.setattr(ao_pkg.catalog, "remove", lambda ctx: seen.append("catalog"))
    app_ctx.config.set("addons.enabled", ["mcp-server", "ao"])
    app_ctx.runner.ok("kubectl delete").fail("kubectl get namespace", stderr="NotFound")
    assert AoAddon(sleep=lambda _s: None).disable(app_ctx, argparse.Namespace()) == 0
    assert seen == ["save", "fin", "olm", "catalog", "ea"]
    assert app_ctx.runner.called("kubectl delete namespace automation-orchestrator")
    bindings = [c for c in app_ctx.runner.commands if "clusterrolebinding" in c]
    assert (
        len(bindings) == 1
        and "aap-demo-scc-privileged-automation-orchestrator-default" in bindings[0]
    )
    assert app_ctx.config.get("addons.enabled") == ["mcp-server"]


def test_disable_with_purge_forgets_the_password(app_ctx, monkeypatch) -> None:
    seen: List[str] = []
    monkeypatch.setattr(ao_pkg.admin, "forget", lambda ctx: seen.append("forget"))
    monkeypatch.setattr(ao_pkg.admin, "save", lambda ctx: seen.append("save"))
    monkeypatch.setattr(ao_pkg.postgres, "cnpg_cluster", lambda ctx: "")
    monkeypatch.setattr(
        ao_pkg.postgres, "reset_storage", lambda ctx, cnpg_expected: seen.append("reset")
    )
    for module, name in (
        ("instance", "remove_finalizers"),
        ("olm", "cleanup"),
        ("olm", "cleanup_early_access"),
        ("catalog", "remove"),
    ):
        monkeypatch.setattr(getattr(ao_pkg, module), name, lambda *_a, **_k: None)
    app_ctx.env = {"AO_PURGE_DATA": "1"}
    app_ctx.runner.ok("kubectl delete").fail("kubectl get namespace", stderr="NotFound")
    AoAddon(sleep=lambda _s: None).disable(app_ctx, argparse.Namespace())
    assert seen == ["forget", "reset"]
