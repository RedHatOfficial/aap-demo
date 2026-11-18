"""AO PostgreSQL port (ADR-043, ADR-045): storage, reset, CNPG, Secrets and CA."""

from __future__ import annotations

import base64
import json
from typing import Dict, List, Tuple

import pytest

from aap_demo.addons.ao import postgres
from aap_demo.core.errors import AddonError
from aap_demo.exec.runner import CompletedCommand, FakeRunner

NS = postgres.NAMESPACE


def _ok(stdout: str = "") -> CompletedCommand:
    return CompletedCommand(argv=(), returncode=0, stdout=stdout)


def _fail(stderr: str = "boom") -> CompletedCommand:
    return CompletedCommand(argv=(), returncode=1, stderr=stderr)


def _statefulset(size: str) -> str:
    return json.dumps(
        {
            "spec": {
                "volumeClaimTemplates": [
                    {
                        "metadata": {"name": "data"},
                        "spec": {"resources": {"requests": {"storage": size}}},
                    }
                ]
            }
        }
    )


# -- settings ---------------------------------------------------------------------


@pytest.mark.parametrize("size", ["3Gi", "500Mi", "1.5Gi", "10G"])
def test_valid_storage_sizes(size: str) -> None:
    assert postgres.validate_storage_size(size) == size


@pytest.mark.parametrize("size", ["0", "0Gi", "0.0Gi", "3GB", "-1Gi", "abc", "3 Gi"])
def test_invalid_storage_sizes(size: str) -> None:
    with pytest.raises(AddonError):
        postgres.validate_storage_size(size)


def test_storage_size_keeps_the_statefulset_template(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok(
        f"kubectl get statefulset {postgres.STATEFULSET} -n {NS}", _statefulset("5Gi")
    )
    assert postgres.storage_size(app_ctx, "3Gi") == "5Gi"


def test_storage_size_uses_a_retained_pvc(app_ctx) -> None:
    pvc = json.dumps({"spec": {"resources": {"requests": {"storage": "8Gi"}}}})
    app_ctx.runner = (
        FakeRunner()
        .ok(f"kubectl get statefulset {postgres.STATEFULSET} -n {NS}", "")
        .ok(f"kubectl get pvc {postgres.PVC} -n {NS}", pvc)
    )
    assert postgres.storage_size(app_ctx, "3Gi") == "8Gi"


def test_storage_size_uses_the_request_for_a_new_database(app_ctx) -> None:
    app_ctx.runner = (
        FakeRunner()
        .ok(f"kubectl get statefulset {postgres.STATEFULSET} -n {NS}", "")
        .ok(f"kubectl get pvc {postgres.PVC} -n {NS}", "")
    )
    assert postgres.storage_size(app_ctx, "4Gi") == "4Gi"


def test_storage_size_stops_when_the_statefulset_cannot_be_read(app_ctx) -> None:
    app_ctx.runner = FakeRunner().fail(f"kubectl get statefulset {postgres.STATEFULSET}")
    with pytest.raises(AddonError, match="refusing"):
        postgres.storage_size(app_ctx, "3Gi")


def test_storage_class_prefers_topolvm(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok(f"kubectl get sc {postgres.BLOCK_CLASS}")
    assert postgres.storage_class(app_ctx) == postgres.BLOCK_CLASS


def test_storage_class_never_falls_back_to_nfs(app_ctx) -> None:
    app_ctx.runner = (
        FakeRunner()
        .fail(f"kubectl get sc {postgres.BLOCK_CLASS}")
        .ok("kubectl get sc -o", postgres.NFS_CLASS + "\n")
    )
    with pytest.raises(AddonError, match="block StorageClass"):
        postgres.storage_class(app_ctx)


def test_storage_class_rejects_unsafe_names(app_ctx) -> None:
    app_ctx.env = {"AO_POSTGRES_STORAGE_CLASS": "bad|name"}
    with pytest.raises(AddonError, match="not a valid name"):
        postgres.storage_class(app_ctx)


def test_image_reuses_aaps_postgres(app_ctx) -> None:
    ref = "registry.redhat.io/rhel9/postgresql-15@sha256:abc"
    sets = {
        "items": [
            {"spec": {"template": {"spec": {"containers": [{"image": "quay.io/x/gateway:1"}]}}}},
            {"spec": {"template": {"spec": {"containers": [{"image": ref}]}}}},
        ]
    }
    app_ctx.runner = FakeRunner().ok("kubectl get statefulset -n aap-operator", json.dumps(sets))
    assert postgres.image(app_ctx, "aap-operator") == ref


def test_image_falls_back_when_aap_cannot_be_read(app_ctx) -> None:
    app_ctx.runner = FakeRunner().fail("kubectl get statefulset -n aap-operator")
    assert postgres.image(app_ctx, "aap-operator") == postgres.IMAGE_FALLBACK


# -- CNPG -------------------------------------------------------------------


def test_cnpg_cluster_absent_without_the_crd(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok("kubectl get crd clusters.postgresql.cnpg.io", "")
    assert postgres.cnpg_cluster(app_ctx) == ""


def test_cnpg_lookup_failure_is_not_absence(app_ctx) -> None:
    app_ctx.runner = FakeRunner().fail("kubectl get crd clusters.postgresql.cnpg.io")
    with pytest.raises(AddonError, match="refusing"):
        postgres.cnpg_cluster(app_ctx)


def _cnpg_runner(owner: str) -> Tuple[FakeRunner, List[str]]:
    state = {"cluster": True}
    deleted: List[str] = []

    def cluster(_args):
        return _ok("cluster.postgresql.cnpg.io/orchestrator-postgres" if state["cluster"] else "")

    def delete_cluster(_args):
        state["cluster"] = False
        deleted.append("cluster")
        return _ok()

    def delete_db(args):
        deleted.append(args[3])
        return _ok()

    runner = (
        FakeRunner()
        .ok("kubectl get crd clusters.postgresql.cnpg.io", "crd/clusters")
        .ok("kubectl get crd databases.postgresql.cnpg.io", "crd/databases")
        .register("kubectl get clusters.postgresql.cnpg.io", cluster)
        .register("kubectl delete clusters.postgresql.cnpg.io", delete_cluster)
        .ok("kubectl get databases.postgresql.cnpg.io", owner)
        .register("kubectl delete databases.postgresql.cnpg.io", delete_db)
        .ok(f"kubectl delete pvc {postgres.CNPG_PVC}")
    )
    return runner, deleted


def test_remove_cnpg_deletes_only_aos_objects(app_ctx) -> None:
    app_ctx.runner, deleted = _cnpg_runner(postgres.CNPG_CLUSTER)
    postgres.remove_cnpg(app_ctx, expected=True)
    assert deleted == ["cluster", *postgres.CNPG_DATABASES]
    assert not any("--all" in call for call in app_ctx.runner.commands)


def test_remove_cnpg_refuses_a_database_owned_by_another_cluster(app_ctx) -> None:
    app_ctx.runner, deleted = _cnpg_runner("someone-else")
    with pytest.raises(AddonError, match="belongs to someone-else"):
        postgres.remove_cnpg(app_ctx, expected=True)
    assert deleted == ["cluster"]


def test_remove_cnpg_stops_when_the_crd_vanishes(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok("kubectl get crd clusters.postgresql.cnpg.io", "")
    with pytest.raises(AddonError, match="disappeared"):
        postgres.remove_cnpg(app_ctx, expected=True)


# -- reset ----------------------------------------------------------------------


def _reset_runner(present: List[str], *, get_error: bool = False, pvc_stuck: bool = False):
    calls: List[str] = []

    def get(args):
        if get_error:
            return _fail()
        return _ok(args[2] if args[2] in present else "")

    def delete_pvc(_args):
        if f"pvc/{postgres.PVC}" in present:
            present.remove(f"pvc/{postgres.PVC}")
        calls.append("delete pvc")
        return _ok()

    runner = (
        FakeRunner()
        .ok("kubectl delete statefulset")
        .ok(["kubectl", "wait", "--for=delete", "~^pod/"])
        .register(["kubectl", "get", "~^(statefulset|pod|pvc)/"], get)
        .register("kubectl delete pvc " + postgres.PVC, delete_pvc)
        .register(["kubectl", "wait", "--for=delete", "~^pvc/"], _fail() if pvc_stuck else _ok())
        .ok("kubectl get crd clusters.postgresql.cnpg.io", "")
    )
    return runner, calls


def test_reset_deletes_the_pvc_once_the_pod_is_gone(app_ctx) -> None:
    app_ctx.runner, calls = _reset_runner([f"pvc/{postgres.PVC}"])
    postgres.reset_storage(app_ctx, cnpg_expected=False)
    assert calls == ["delete pvc"]


@pytest.mark.parametrize("left", [f"pod/{postgres.POD}", f"statefulset/{postgres.STATEFULSET}"])
def test_reset_stops_while_the_old_database_remains(app_ctx, left: str) -> None:
    app_ctx.runner, calls = _reset_runner([left, f"pvc/{postgres.PVC}"])
    with pytest.raises(AddonError, match="still present"):
        postgres.reset_storage(app_ctx, cnpg_expected=False)
    assert calls == []


def test_reset_stops_when_it_cannot_check(app_ctx) -> None:
    app_ctx.runner, calls = _reset_runner([f"pvc/{postgres.PVC}"], get_error=True)
    with pytest.raises(AddonError):
        postgres.reset_storage(app_ctx, cnpg_expected=False)
    assert calls == []


def test_reset_stops_when_the_pvc_is_stuck(app_ctx) -> None:
    app_ctx.runner, _calls = _reset_runner([f"pvc/{postgres.PVC}"], pvc_stuck=True)
    with pytest.raises(AddonError, match="did not finish deleting"):
        postgres.reset_storage(app_ctx, cnpg_expected=False)


# -- Secrets and CA ---------------------------------------------------------------


def _secret_runner(stored: Dict[str, str], *, pvc: bool = False) -> FakeRunner:
    def read(args):
        name = args[3]
        return _ok(stored.get(name, ""))

    return (
        FakeRunner()
        .register("kubectl get secret", read)
        .ok(f"kubectl get pvc/{postgres.PVC}", f"pvc/{postgres.PVC}" if pvc else "")
        .ok("kubectl apply -f -")
    )


def test_database_secrets_reuse_the_existing_password(app_ctx) -> None:
    encoded = base64.b64encode(b"kept-password").decode()
    app_ctx.runner = _secret_runner({"orchestrator-postgres-secret": encoded})
    postgres.ensure_database_secrets(app_ctx)
    applied = json.loads(app_ctx.runner.calls[-1].input or "{}")
    passwords = {item["stringData"]["password"] for item in applied["items"]}
    assert passwords == {"kept-password"}
    assert {item["metadata"]["name"] for item in applied["items"]} == set(postgres.DATABASE_SECRETS)


def test_database_secrets_generate_one_password_for_a_new_install(app_ctx) -> None:
    app_ctx.runner = _secret_runner({})
    postgres.ensure_database_secrets(app_ctx)
    applied = json.loads(app_ctx.runner.calls[-1].input or "{}")
    passwords = {item["stringData"]["password"] for item in applied["items"]}
    assert len(passwords) == 1 and len(passwords.pop()) == 32


def test_sync_ca_reports_change_match_and_missing(app_ctx) -> None:
    old = base64.b64encode(b"old-ca").decode()
    for bundle, stored, expected in (
        ("new-ca", old, True),
        ("old-ca", old, False),
        ("", old, None),
    ):
        app_ctx.runner = (
            FakeRunner()
            .ok(f"kubectl get configmap {postgres.CA_BUNDLE}", bundle)
            .ok(f"kubectl get secret {postgres.CA_SECRET}", stored)
            .ok("kubectl apply -f -")
        )
        assert postgres.sync_ca(app_ctx) is expected
        assert app_ctx.runner.called("kubectl apply -f -") is (expected is True)


def test_restart_clients_skips_the_operator(app_ctx) -> None:
    listing = "\n".join(
        [
            "deployment.apps/automation-orchestrator-backend",
            "deployment.apps/automation-orchestrator-operator-controller-manager",
            "deployment.apps/unrelated",
        ]
    )
    app_ctx.runner = (
        FakeRunner().ok("kubectl get deployment -n", listing).ok("kubectl rollout restart")
    )
    postgres.restart_clients(app_ctx)
    restarted = [c for c in app_ctx.runner.commands if "rollout restart" in c]
    assert restarted == [
        f"kubectl rollout restart deployment.apps/automation-orchestrator-backend -n {NS}"
    ]


def test_restart_clients_reports_a_failed_list(app_ctx) -> None:
    app_ctx.runner = FakeRunner().fail("kubectl get deployment -n")
    with pytest.raises(AddonError, match="Could not list AO deployments"):
        postgres.restart_clients(app_ctx)


def test_a_kept_database_without_its_secret_is_not_given_a_new_password(app_ctx) -> None:
    app_ctx.runner = _secret_runner({}, pvc=True)
    with pytest.raises(AddonError, match="password Secret is missing"):
        postgres.ensure_database_secrets(app_ctx)
    assert not app_ctx.runner.called("kubectl apply -f -")
