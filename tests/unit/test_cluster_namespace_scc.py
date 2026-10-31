"""``setup_namespace`` and ``_grant_sccs`` — order and both grant paths (§14 R3).

R3's mitigation names this file's job: assert the exact call order via
``FakeRunner``, in both SCC branches. The order assertions use
``FakeRunner.index_of`` so they fail with the offending sequence rather than a
bare boolean.
"""

from __future__ import annotations

from typing import Optional

import pytest

from aap_demo.cluster import namespace as ns_mod
from aap_demo.cluster import pull_secret, scc
from aap_demo.exec.runner import CompletedCommand, FakeRunner

NS = "aap-operator"


def _which(*present: str):
    def which(name: str) -> Optional[str]:
        return f"/usr/bin/{name}" if name in present else None

    return which


def _base_runner() -> FakeRunner:
    runner = FakeRunner()
    runner.ok("kubectl get namespace")
    runner.ok("kubectl create namespace")
    runner.ok("kubectl label namespace")
    runner.ok("kubectl delete secret")
    runner.ok("kubectl create secret")
    runner.ok("kubectl get serviceaccount")
    runner.ok("kubectl patch serviceaccount")
    return runner


# ---------------------------------------------------------------------------
# SCC grants
# ---------------------------------------------------------------------------


def test_oc_path_grants_both_sccs_to_the_namespace_group(app_ctx) -> None:
    runner = FakeRunner().ok("oc adm policy add-scc-to-group")
    app_ctx.runner = runner

    assert scc.grant_namespace_sccs(app_ctx, NS, which=_which("oc")) is True
    assert runner.commands == [
        f"oc adm policy add-scc-to-group anyuid system:serviceaccounts:{NS}",
        f"oc adm policy add-scc-to-group privileged system:serviceaccounts:{NS}",
    ]


def test_oc_path_reports_each_failure_and_still_tries_the_second(app_ctx) -> None:
    """Bash sets ``_rc=1`` and keeps going; it never returns after the first."""

    def result(argv):
        code = 1 if "anyuid" in argv else 0
        return CompletedCommand(argv=argv, returncode=code, stderr="forbidden")

    runner = FakeRunner().register("oc adm policy add-scc-to-group", result)
    app_ctx.runner = runner

    assert scc.grant_namespace_sccs(app_ctx, NS, which=_which("oc")) is False
    assert runner.called("oc adm policy add-scc-to-group privileged")
    stderr = app_ctx.console.stderr
    assert "Failed to grant anyuid SCC" in stderr
    assert "forbidden" in app_ctx.console.stdout
    assert "oc adm policy add-scc-to-group anyuid" in app_ctx.console.stdout


def test_kubectl_fallback_creates_the_two_clusterrolebindings(app_ctx) -> None:
    """The fallback leaves *different objects* behind — that is why it is kept."""
    runner = FakeRunner()
    runner.fail("kubectl get clusterrolebinding")
    runner.ok("kubectl create clusterrolebinding")
    app_ctx.runner = runner

    assert scc.grant_namespace_sccs(app_ctx, NS, which=_which()) is True
    assert runner.commands[1] == (
        f"kubectl create clusterrolebinding system:openshift:scc:anyuid:{NS} "
        f"--clusterrole=system:openshift:scc:anyuid --group=system:serviceaccounts:{NS}"
    )
    assert "'oc' not found" in app_ctx.console.stdout


def test_kubectl_fallback_is_idempotent(app_ctx) -> None:
    runner = FakeRunner().ok("kubectl get clusterrolebinding")
    app_ctx.runner = runner

    assert scc.grant_namespace_sccs(app_ctx, NS, which=_which()) is True
    assert not runner.called("kubectl create clusterrolebinding")


def test_kubectl_fallback_reports_a_failed_binding(app_ctx) -> None:
    runner = FakeRunner()
    runner.fail("kubectl get clusterrolebinding")
    runner.fail("kubectl create clusterrolebinding", stderr="forbidden")
    app_ctx.runner = runner

    assert scc.grant_namespace_sccs(app_ctx, NS, which=_which()) is False
    assert "Failed to create ClusterRoleBinding for anyuid" in app_ctx.console.stderr


def test_binding_name_is_the_shape_diagnose_looks_for() -> None:
    assert scc.binding_name("privileged", "ns") == "system:openshift:scc:privileged:ns"


# ---------------------------------------------------------------------------
# setup_namespace ordering
# ---------------------------------------------------------------------------


def test_setup_namespace_order_is_bashs(app_ctx, tmp_path) -> None:
    """create → SCCs → PSA labels → pull secret. R3's single most important assertion."""
    secret = tmp_path / "pull-secret.json"
    secret.write_text("{}")
    app_ctx.config.set("deploy.pull_secret_path", str(secret))

    runner = _base_runner()
    runner.ok("oc adm policy add-scc-to-group")
    app_ctx.runner = runner

    ns_mod.ensure(app_ctx, NS, which=_which("oc", "kubectl"), sleep=lambda _s: None)

    create = runner.index_of("kubectl create namespace")
    grant = runner.index_of("oc adm policy add-scc-to-group anyuid")
    labelled = runner.index_of("kubectl label namespace")
    secret_created = runner.index_of("kubectl create secret")
    assert create < grant < labelled < secret_created


def test_setup_namespace_grants_sccs_before_anything_can_create_a_pod(app_ctx) -> None:
    """No pod-creating call may precede the grants — the R3 failure mode."""
    runner = _base_runner()
    runner.ok("oc adm policy add-scc-to-group")
    app_ctx.runner = runner

    ns_mod.ensure(app_ctx, NS, which=_which("oc", "kubectl"), sleep=lambda _s: None)

    grant = runner.index_of("oc adm policy add-scc-to-group privileged")
    for i, call in enumerate(runner.calls):
        if i < grant:
            assert call.argv[:2] != ("kubectl", "apply")


def test_setup_namespace_labels_psa_privileged_with_overwrite(app_ctx) -> None:
    runner = _base_runner()
    runner.ok("oc adm policy add-scc-to-group")
    app_ctx.runner = runner

    ns_mod.ensure(app_ctx, NS, which=_which("oc", "kubectl"), sleep=lambda _s: None)

    labelled = runner.calls[runner.index_of("kubectl label namespace")].argv
    assert "pod-security.kubernetes.io/enforce=privileged" in labelled
    assert labelled[-1] == "--overwrite"


def test_terminating_namespace_is_waited_out_then_force_cleared(app_ctx) -> None:
    phases = iter(["Terminating"] * 20)
    runner = FakeRunner()
    # Registered first so it wins over the jsonpath rule below.
    runner.ok(
        ["kubectl", "get", "namespace", NS, "-o", "json"],
        stdout='{"spec": {"finalizers": ["kubernetes"]}}',
    )
    runner.register(
        "kubectl get namespace",
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=next(phases, "")),
    )
    runner.ok("kubectl replace --raw")
    app_ctx.runner = runner

    slept = []
    ns_mod.clear_terminating(app_ctx, NS, sleep=slept.append)

    assert runner.called("kubectl replace --raw")
    # 15 poll sleeps at 2s plus the 2s after the force-clear.
    assert slept == [2] * ns_mod.TERMINATING_ATTEMPTS + [2]
    assert "Force-clearing stuck namespace" in app_ctx.console.stdout


def test_terminating_namespace_that_clears_on_its_own_is_not_force_cleared(app_ctx) -> None:
    phases = iter(["Terminating", "Terminating", ""])
    runner = FakeRunner()
    runner.register(
        "kubectl get namespace",
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=next(phases, "")),
    )
    app_ctx.runner = runner

    ns_mod.clear_terminating(app_ctx, NS, sleep=lambda _s: None)
    assert not runner.called("kubectl replace --raw")


def test_crc_oc_is_put_on_path_when_the_host_has_none(app_ctx) -> None:
    runner = _base_runner()
    runner.ok("crc oc-env", stdout='export PATH="/opt/crc/bin/oc:$PATH"\n')
    runner.fail("kubectl get clusterrolebinding")
    runner.ok("kubectl create clusterrolebinding")
    app_ctx.runner = runner
    app_ctx.env = {"PATH": "/usr/bin"}

    ns_mod.ensure(app_ctx, NS, which=_which("kubectl", "crc"), sleep=lambda _s: None)

    assert app_ctx.env["PATH"].startswith("/opt/crc/bin/oc:")


def test_crc_oc_env_is_not_consulted_when_oc_exists(app_ctx) -> None:
    runner = _base_runner()
    runner.ok("oc adm policy add-scc-to-group")
    app_ctx.runner = runner

    ns_mod.ensure(app_ctx, NS, which=_which("oc", "crc", "kubectl"), sleep=lambda _s: None)
    assert not runner.called("crc oc-env")


# ---------------------------------------------------------------------------
# Pull secret
# ---------------------------------------------------------------------------


def test_pull_secret_is_recreated_then_merged_into_the_default_sa(app_ctx, tmp_path) -> None:
    secret = tmp_path / "pull-secret.json"
    secret.write_text("{}")
    app_ctx.config.set("deploy.pull_secret_path", str(secret))

    runner = FakeRunner()
    runner.ok("kubectl delete secret")
    runner.ok("kubectl create secret")
    runner.ok("kubectl get serviceaccount default", stdout="existing-secret")
    runner.ok("kubectl patch serviceaccount")
    app_ctx.runner = runner

    pull_secret.ensure(app_ctx, NS)

    assert runner.index_of("kubectl delete secret") < runner.index_of("kubectl create secret")
    patch = runner.calls[runner.index_of("kubectl patch serviceaccount")].argv
    # New secret first, existing entries after — kubelet tries them in order.
    assert patch[-1] == (
        '{"imagePullSecrets": [{"name": "redhat-operators-pull-secret"}, '
        '{"name": "existing-secret"}]}'
    )


def test_pull_secret_already_attached_is_left_alone(app_ctx, tmp_path) -> None:
    secret = tmp_path / "pull-secret.json"
    secret.write_text("{}")
    app_ctx.config.set("deploy.pull_secret_path", str(secret))

    runner = FakeRunner()
    runner.ok("kubectl delete secret")
    runner.ok("kubectl create secret")
    runner.ok("kubectl get serviceaccount default", stdout="redhat-operators-pull-secret")
    app_ctx.runner = runner

    pull_secret.ensure(app_ctx, NS)
    assert not runner.called("kubectl patch serviceaccount")
    assert "already attached" in app_ctx.console.stdout


def test_missing_pull_secret_warns_and_creates_nothing(app_ctx) -> None:
    runner = FakeRunner()
    app_ctx.runner = runner

    assert pull_secret.ensure(app_ctx, NS) is None
    assert "WARNING: Pull secret is not set" in app_ctx.console.stdout
    assert "config set pull-secret" in app_ctx.console.stdout
    assert "pull-secret.txt" in app_ctx.console.stdout
    assert runner.calls == []


def test_reconcile_restarts_only_pods_stuck_pulling(app_ctx, tmp_path) -> None:
    secret = tmp_path / "pull-secret.json"
    secret.write_text("{}\n")
    app_ctx.config.set("deploy.pull_secret_path", str(secret))
    runner = FakeRunner()
    runner.ok(
        ["kubectl", "get", "aap", "aap", "-n", NS, "-o", "jsonpath={.spec.image_pull_secrets}"],
        stdout='["redhat-operators-pull-secret"]',
    )
    runner.ok(
        "kubectl get serviceaccount",
        stdout="default\tredhat-operators-pull-secret\naap-controller\t\n",
    )
    runner.ok("kubectl patch serviceaccount")
    runner.ok(
        ["kubectl", "get", "pods", "-n", NS, "-o", "json"],
        stdout=(
            '{"items":[{"metadata":{"name":"web"},"status":{"containerStatuses":'
            '[{"state":{"waiting":{"reason":"ImagePullBackOff"}}}]}},'
            '{"metadata":{"name":"api"},"status":{"initContainerStatuses":'
            '[{"state":{"waiting":{"reason":"ErrImagePull"}}}]}},'
            '{"metadata":{"name":"db"},"status":{"containerStatuses":'
            '[{"state":{"running":{}}}]}}]}'
        ),
    )
    runner.ok("kubectl delete pod")
    app_ctx.runner = runner

    pull_secret.reconcile(app_ctx, NS, "aap")

    patched = [
        c.argv[3] for c in runner.calls if c.argv[:3] == ("kubectl", "patch", "serviceaccount")
    ]
    assert patched == ["aap-controller"]
    deleted = next(c for c in runner.calls if c.argv[:3] == ("kubectl", "delete", "pod"))
    assert deleted.argv[6:] == ("web", "api")
    assert "2 service accounts" not in app_ctx.console.stdout
    assert "restarting 2 pods" in app_ctx.console.stdout


def test_every_service_account_receives_the_pull_secret(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok(
        "kubectl get serviceaccount",
        stdout="default\tredhat-operators-pull-secret\naap-gateway\t\n",
    )
    runner.ok("kubectl patch serviceaccount")
    app_ctx.runner = runner

    pull_secret.attach_to_all_service_accounts(app_ctx, NS)

    prefix = ("kubectl", "patch", "serviceaccount")
    patched = [c.argv[3] for c in runner.calls if c.argv[:3] == prefix]
    assert patched == ["aap-gateway"]


def test_operator_service_accounts_are_filtered_the_way_grep_did(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok(
        "kubectl get serviceaccount",
        stdout=(
            "serviceaccount/default\n"
            "serviceaccount/aap-operator-controller-manager\n"
            "serviceaccount/awx-operator\n"
            "serviceaccount/postgres\n"
        ),
    )
    runner.ok("kubectl patch serviceaccount")
    app_ctx.runner = runner

    pull_secret.patch_service_accounts(app_ctx, NS, sleep=lambda _s: None)

    prefix = ("kubectl", "patch", "serviceaccount")
    patched = [c.argv[3] for c in runner.calls if c.argv[:3] == prefix]
    assert patched == ["aap-operator-controller-manager", "awx-operator"]


@pytest.mark.parametrize("phase_value", ["Active", ""])
def test_non_terminating_namespace_skips_the_wait(app_ctx, phase_value) -> None:
    runner = FakeRunner().ok("kubectl get namespace", stdout=phase_value)
    app_ctx.runner = runner
    ns_mod.clear_terminating(app_ctx, NS, sleep=lambda _s: pytest.fail("should not sleep"))


# ---------------------------------------------------------------------------
# Grant detection — all three shapes
# ---------------------------------------------------------------------------


def test_grant_detected_from_the_scc_groups_list(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok(
        "kubectl get scc", stdout=f'["system:cluster-admins","system:serviceaccounts:{NS}"]'
    )
    assert scc.grant_present(app_ctx, "anyuid", NS) is True


def test_grant_detected_from_the_per_namespace_binding(app_ctx) -> None:
    """The shape bash's kubectl fallback leaves behind."""
    runner = FakeRunner()
    runner.ok("kubectl get scc", stdout="[]")
    runner.ok(["kubectl", "get", "clusterrolebinding", scc.binding_name("anyuid", NS)])
    app_ctx.runner = runner
    assert scc.grant_present(app_ctx, "anyuid", NS) is True


def test_grant_detected_from_the_shared_binding_a_modern_oc_writes(app_ctx) -> None:
    """The shape observed on live MicroShift 4.22 — see scc.shared_binding_name."""
    runner = FakeRunner()
    runner.ok("kubectl get scc", stdout="[]")
    runner.fail(["kubectl", "get", "clusterrolebinding", scc.binding_name("anyuid", NS)])
    runner.ok(
        ["kubectl", "get", "clusterrolebinding", "system:openshift:scc:anyuid", "-o", "json"],
        stdout='{"subjects": [{"kind": "Group", "name": "system:serviceaccounts:' + NS + '"}]}',
    )
    app_ctx.runner = runner
    assert scc.grant_present(app_ctx, "anyuid", NS) is True


def test_no_grant_at_all_is_reported_as_missing(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok("kubectl get scc", stdout="[]")
    runner.fail("kubectl get clusterrolebinding")
    app_ctx.runner = runner
    assert scc.grant_present(app_ctx, "anyuid", NS) is False


def test_a_shared_binding_for_another_namespace_is_not_our_grant(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok("kubectl get scc", stdout="[]")
    runner.fail(["kubectl", "get", "clusterrolebinding", scc.binding_name("anyuid", NS)])
    runner.ok(
        ["kubectl", "get", "clusterrolebinding", "system:openshift:scc:anyuid", "-o", "json"],
        stdout='{"subjects": [{"name": "system:serviceaccounts:other-ns"}]}',
    )
    app_ctx.runner = runner
    assert scc.grant_present(app_ctx, "anyuid", NS) is False
