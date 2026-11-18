"""AO admin password: host copy, legacy import, and retained-database rules."""

from __future__ import annotations

import base64
import json
import stat

import pytest

from aap_demo.addons.ao import admin, postgres
from aap_demo.core.errors import AddonError
from aap_demo.exec.runner import FakeRunner

NS = postgres.NAMESPACE


def _runner(*, retained: str = "", cluster_password: str = "") -> FakeRunner:
    encoded = base64.b64encode(cluster_password.encode()).decode() if cluster_password else ""
    runner = FakeRunner()
    for kind, name in (
        ("pvc", postgres.PVC),
        ("pvc", postgres.CNPG_PVC),
        ("clusters.postgresql.cnpg.io", postgres.CNPG_CLUSTER),
    ):
        if retained == name:
            runner.ok(f"kubectl get {kind} {name} -n {NS}")
        else:
            runner.fail(f"kubectl get {kind} {name} -n {NS}", stderr="NotFound")
    return (
        runner.ok(f"kubectl get secret {admin.SECRET} -n {NS} -o", encoded)
        .ok(f"kubectl delete secret {admin.SECRET}")
        .ok("kubectl apply -f -")
    )


def _applied_password(runner: FakeRunner) -> str:
    applied = [call for call in runner.calls if call.argv[:2] == ("kubectl", "apply")]
    return json.loads(applied[-1].input or "{}")["stringData"]["password"]


def test_fresh_install_generates_a_private_password(app_ctx) -> None:
    app_ctx.runner = _runner()
    admin.ensure(app_ctx)
    value = admin.path(app_ctx).read_text()
    assert len(value) == 32
    assert stat.S_IMODE(admin.path(app_ctx).stat().st_mode) == 0o600
    assert _applied_password(app_ctx.runner) == value
    assert not any(value in " ".join(call.argv) for call in app_ctx.runner.calls)


def test_saved_password_is_restored(app_ctx) -> None:
    admin.path(app_ctx).parent.mkdir(parents=True)
    admin.path(app_ctx).write_text("kept")
    app_ctx.runner = _runner(retained=postgres.PVC)
    admin.ensure(app_ctx)
    assert _applied_password(app_ctx.runner) == "kept"


def test_bash_password_is_copied_in_and_left_for_v1(app_ctx) -> None:
    legacy = admin.legacy_path(app_ctx)
    legacy.parent.mkdir(parents=True)
    legacy.write_text("from-bash\n")
    app_ctx.runner = _runner(retained=postgres.PVC)
    admin.ensure(app_ctx)
    assert admin.path(app_ctx).read_text() == "from-bash"
    assert legacy.is_file()
    assert _applied_password(app_ctx.runner) == "from-bash"


@pytest.mark.parametrize("retained", [postgres.PVC, postgres.CNPG_PVC, postgres.CNPG_CLUSTER])
def test_retained_database_keeps_the_cluster_password(app_ctx, retained: str) -> None:
    app_ctx.runner = _runner(retained=retained, cluster_password="in-cluster")
    admin.ensure(app_ctx)
    assert admin.path(app_ctx).read_text() == "in-cluster"
    assert not app_ctx.runner.called("kubectl apply -f -")


def test_retained_database_without_a_password_stops(app_ctx) -> None:
    app_ctx.runner = _runner(retained=postgres.PVC)
    with pytest.raises(AddonError, match="no recoverable admin password"):
        admin.ensure(app_ctx)


def test_save_refuses_when_data_exists_without_a_password(app_ctx) -> None:
    app_ctx.runner = _runner(retained=postgres.PVC)
    with pytest.raises(AddonError, match="Refusing to remove AO"):
        admin.save(app_ctx)


def test_forget_leaves_the_bash_copy(app_ctx) -> None:
    legacy = admin.legacy_path(app_ctx)
    legacy.parent.mkdir(parents=True)
    legacy.write_text("from-bash")
    admin.path(app_ctx).parent.mkdir(parents=True)
    admin.path(app_ctx).write_text("kept")
    admin.forget(app_ctx)
    assert not admin.path(app_ctx).exists()
    assert legacy.is_file()
