"""``cluster/aap.py`` — CR creation, the gateway patch, readiness, teardown."""

from __future__ import annotations

import base64
import json
from typing import Optional

import pytest

from aap_demo.cluster import aap as aap_mod
from aap_demo.core.errors import UsageError
from aap_demo.exec.runner import CompletedCommand, FakeRunner

NS = "aap-operator"


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


def _which(*present: str):
    def which(name: str) -> Optional[str]:
        return f"/usr/bin/{name}" if name in present else None

    return which


# ---------------------------------------------------------------------------
# CR selection
# ---------------------------------------------------------------------------


def test_available_crs_are_the_bundled_names() -> None:
    assert set(aap_mod.available_crs()) == {
        "minimal",
        "controller",
        "controller-eda",
        "minimal-rwx",
        "minimal-noingress",
    }


def test_unknown_cr_lists_the_alternatives_like_bash_did() -> None:
    with pytest.raises(UsageError) as excinfo:
        aap_mod.load_cr("does-not-exist")
    assert "aap-does-not-exist.yaml" in excinfo.value.message
    assert "controller" in (excinfo.value.hint or "")


def test_cr_metadata_name_defaults_to_aap() -> None:
    assert aap_mod.cr_metadata_name({"metadata": {"name": "myaap"}}) == "myaap"
    assert aap_mod.cr_metadata_name({}) == "aap"


def test_noingress_public_url_is_auto_constructed_from_the_pod_env(app_ctx) -> None:
    app_ctx.env = {
        "POD_NAME": "engkube-runner",
        "POD_NAMESPACE": "engkube",
        "BASE_DOMAIN": "apps.ocp.example.com",
    }
    assert aap_mod.public_url_for(app_ctx) == (
        "https://aap-engkube-runner-engkube.apps.ocp.example.com"
    )


def test_explicit_public_url_wins_over_the_components(app_ctx) -> None:
    app_ctx.config.set("deploy.public_url", "https://explicit.example.com")
    app_ctx.env = {"POD_NAME": "a", "POD_NAMESPACE": "b", "BASE_DOMAIN": "c"}
    assert aap_mod.public_url_for(app_ctx) == "https://explicit.example.com"


def test_noingress_without_a_public_url_is_a_usage_error(app_ctx) -> None:
    app_ctx.runner = FakeRunner().fail("kubectl get sc")
    with pytest.raises(UsageError) as excinfo:
        aap_mod.create_instance(app_ctx, cr_name="minimal-noingress", namespace=NS)
    assert "PUBLIC_URL required" in excinfo.value.message


# ---------------------------------------------------------------------------
# create_instance
# ---------------------------------------------------------------------------


def _create_runner(*, has_rwx=True, gateway=True) -> FakeRunner:
    runner = FakeRunner()
    if has_rwx:
        runner.ok("kubectl get sc nfs-local-rwx")
    else:
        runner.fail("kubectl get sc nfs-local-rwx")
    runner.ok("kubectl apply -f -")
    runner.ok("kubectl get aap", stdout="aap")
    if gateway:
        runner.ok("kubectl get deployment")
    else:
        runner.fail("kubectl get deployment")
    runner.ok("kubectl patch deployment")
    return runner


def test_create_instance_applies_the_pvcs_before_the_cr(app_ctx) -> None:
    """The operator would otherwise create them against the cluster default class."""
    runner = _create_runner()
    app_ctx.runner = runner

    assert (
        aap_mod.create_instance(app_ctx, cr_name="minimal", namespace=NS, sleep=lambda _s: None)
        == "aap"
    )

    applies = [c for c in runner.calls if c.argv[:2] == ("kubectl", "apply")]
    assert "kind: PersistentVolumeClaim" in (applies[0].input or "")
    assert "kind: AnsibleAutomationPlatform" in (applies[1].input or "")


def test_create_instance_skips_the_pvcs_without_the_rwx_class(app_ctx) -> None:
    runner = _create_runner(has_rwx=False)
    app_ctx.runner = runner
    aap_mod.create_instance(app_ctx, cr_name="controller", namespace=NS, sleep=lambda _s: None)
    applies = [c for c in runner.calls if c.argv[:2] == ("kubectl", "apply")]
    assert len(applies) == 1


def test_create_instance_applies_into_the_namespace(app_ctx) -> None:
    runner = _create_runner()
    app_ctx.runner = runner
    aap_mod.create_instance(app_ctx, cr_name="controller", namespace="other", sleep=lambda _s: None)
    cr_apply = [c for c in runner.calls if "kind: AnsibleAutomationPlatform" in (c.input or "")][0]
    assert cr_apply.argv == ("kubectl", "apply", "-f", "-", "-n", "other")


def test_cr_defaults_to_minimal_when_config_is_empty(app_ctx) -> None:
    app_ctx.config.set("deploy.cr", "")
    runner = _create_runner()
    app_ctx.runner = runner
    aap_mod.create_instance(app_ctx, namespace=NS, sleep=lambda _s: None)
    assert "Using CR: minimal" in app_ctx.console.stdout


def test_cr_comes_from_config_when_set(app_ctx) -> None:
    app_ctx.config.set("deploy.cr", "controller")
    runner = _create_runner()
    app_ctx.runner = runner
    aap_mod.create_instance(app_ctx, namespace=NS, sleep=lambda _s: None)
    assert "Using CR: controller" in app_ctx.console.stdout


# ---------------------------------------------------------------------------
# Gateway patch
# ---------------------------------------------------------------------------


def test_gateway_replicas_are_forced_to_one_before_the_capability_patch(app_ctx) -> None:
    """Two replicas racing the same schema migration is a worse failure than EACCES."""
    runner = FakeRunner()
    runner.ok("kubectl get aap", stdout="aap")
    runner.ok("kubectl get deployment aap-gateway", stdout="3")
    runner.ok("kubectl patch deployment")
    app_ctx.runner = runner

    clock = Clock()
    assert (
        aap_mod.patch_gateway_capability(app_ctx, namespace=NS, sleep=clock.sleep, clock=clock)
        is True
    )

    patches = [c.argv[-1] for c in runner.calls if c.argv[:3] == ("kubectl", "patch", "deployment")]
    assert '"replicas":1' in patches[0]
    assert "NET_BIND_SERVICE" in patches[1]


def test_gateway_already_patched_is_left_alone(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok("kubectl get aap", stdout="aap")
    runner.ok(
        [
            "kubectl",
            "get",
            "deployment",
            "aap-gateway",
            "-n",
            NS,
            "-o",
            "jsonpath={.spec.replicas}",
        ],
        stdout="1",
    )
    runner.ok(
        ["kubectl", "get", "deployment", "aap-gateway", "-n", NS, "-o"],
        stdout='["NET_BIND_SERVICE"]',
    )
    runner.ok("kubectl get deployment aap-gateway")
    app_ctx.runner = runner
    clock = Clock()
    assert (
        aap_mod.patch_gateway_capability(app_ctx, namespace=NS, sleep=clock.sleep, clock=clock)
        is True
    )
    assert not runner.called("kubectl patch")


def test_gateway_that_never_appears_is_a_warning_not_a_failed_deploy(app_ctx) -> None:
    """Bash returns 0 here — the operator may still reconcile it later."""
    runner = FakeRunner()
    runner.ok("kubectl get aap", stdout="aap")
    runner.fail("kubectl get deployment")
    app_ctx.runner = runner
    clock = Clock()

    assert (
        aap_mod.patch_gateway_capability(app_ctx, namespace=NS, sleep=clock.sleep, clock=clock)
        is False
    )
    assert "not found after 5 minutes" in app_ctx.console.stdout


def test_no_aap_cr_means_no_gateway_work(app_ctx) -> None:
    runner = FakeRunner().ok("kubectl get aap", stdout="")
    app_ctx.runner = runner
    assert aap_mod.patch_gateway_capability(app_ctx, namespace=NS) is False


# ---------------------------------------------------------------------------
# Readiness
# ---------------------------------------------------------------------------


def _readiness_runner(
    conditions,
    password="s3cret",
    *,
    deploys="aap-controller 0/1 1 0 6m\naap-gateway 1/1 1 1 6m\n",
    controller_ready=False,
) -> FakeRunner:
    it = iter(conditions)
    runner = FakeRunner()
    runner.register(
        [
            "kubectl",
            "get",
            "aap",
            "-n",
            NS,
            "-o",
            'jsonpath={.items[0].status.conditions[?(@.type=="Successful")].status}',
        ],
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=next(it, conditions[-1])),
    )
    runner.ok(
        ["kubectl", "get", "deploy", "-n", NS, "--no-headers"],
        stdout=deploys,
    )
    runner.ok(
        ["kubectl", "get", "aap", "-n", NS, "-o", "json"],
        stdout=json.dumps(
            {
                "items": [
                    {
                        "spec": {"controller": {"disabled": False}},
                        "status": {
                            "conditions": [
                                {
                                    "type": "Running",
                                    "status": "True",
                                    "reason": "Running",
                                    "message": "Running reconciliation",
                                }
                            ]
                        },
                    }
                ]
            }
        ),
    )
    controller_condition = (
        {
            "type": "Successful",
            "status": "True",
            "reason": "Successful",
            "message": "Last reconciliation succeeded",
        }
        if controller_ready
        else {
            "type": "Running",
            "status": "True",
            "reason": "Running",
            "message": "Running reconciliation",
        }
    )
    runner.ok(
        ["kubectl", "get", "automationcontroller", "-n", NS, "-o", "json"],
        stdout=json.dumps({"items": [{"status": {"conditions": [controller_condition]}}]}),
    )
    runner.ok(
        [
            "kubectl",
            "get",
            "aap",
            "-n",
            NS,
            "-o",
            "jsonpath={.items[0].metadata.name}",
        ],
        stdout="aap",
    )
    runner.ok(
        [
            "kubectl",
            "get",
            "aap",
            "-n",
            NS,
            "-o",
            "jsonpath={.items[0].status.version}",
        ],
        stdout="2.7.0",
    )
    runner.ok(
        [
            "kubectl",
            "get",
            "aap",
            "-n",
            NS,
            "-o",
            "jsonpath={.items[0].status.conditions}",
        ],
        stdout=json.dumps(
            [
                {
                    "lastTransitionTime": "2026-10-04T18:53:07Z",
                    "message": "Running reconciliation",
                    "reason": "Running",
                    "status": "True",
                    "type": "Running",
                }
            ]
        ),
    )
    runner.ok(
        [
            "kubectl",
            "get",
            "aap",
            "-n",
            NS,
            "-o",
            "jsonpath={.items[0].status.adminPasswordSecret}",
        ],
        stdout="aap-admin-password",
    )
    runner.ok(
        "kubectl get secret",
        stdout=base64.b64encode(password.encode()).decode(),
    )
    runner.ok("kubectl get route", stdout="aap-aap-operator.apps.127.0.0.1.nip.io")
    runner.ok("kubectl get csv", stdout="aap-operator.v2.7.0")
    return runner


def test_a_terminal_reconcile_checks_off_even_when_successful_is_false() -> None:
    rows = aap_mod.build_component_rows(
        {"controller": {"disabled": False}, "hub": {"disabled": True}},
        [
            {
                "type": "Successful",
                "status": "False",
                "reason": "Successful",
                "message": "Last reconciliation succeeded",
            },
            {
                "type": "Running",
                "status": "True",
                "reason": "Running",
                "message": "Running reconciliation",
            },
            {"type": "Failure", "status": "False"},
        ],
        {
            "controller": [
                {
                    "type": "Successful",
                    "status": "False",
                    "reason": "Successful",
                    "message": "Last reconciliation succeeded",
                },
                {"type": "Running", "status": "True", "message": "Running reconciliation"},
                {"type": "Failure", "status": "False"},
            ]
        },
        "aap-controller-task 1/1 1 1 6m\naap-gateway 1/1 1 1 6m\n",
    )
    assert rows == [("gateway", "done", ""), ("controller", "done", "")]


def test_condition_line_uses_the_newest_condition() -> None:
    older = {
        "type": "Successful",
        "status": "False",
        "reason": "Pending",
        "message": "Not ready",
        "lastTransitionTime": "2026-10-04T18:00:00Z",
    }
    newer = {
        "type": "Running",
        "status": "True",
        "reason": "Running",
        "message": "Running reconciliation",
        "lastTransitionTime": "2026-10-04T18:53:07Z",
    }
    assert aap_mod.condition_line([older, newer]) == "Running: Running reconciliation"
    assert aap_mod.condition_line([]) == ""


def test_deployment_line_names_workloads_that_are_not_ready() -> None:
    table = "aap-controller 0/1 1 0 6m\naap-gateway 1/1 1 1 6m\naap-web 0/2 2 0 6m\n"
    assert aap_mod.deployment_line(table) == "controller 0/1, web 0/2"
    assert aap_mod.deployment_line("aap-gateway 1/1 1 1 6m\n") == "1/1 deployments ready"
    assert aap_mod.deployment_line("") == ""
    assert (
        aap_mod.wait_status("22/22 deployments ready", "Running reconciliation")
        == "Status: Running reconciliation (22/22 deployments ready)"
    )


def test_wait_ready_reports_the_live_condition(app_ctx) -> None:
    clock = Clock()
    app_ctx.runner = _readiness_runner(["False"])
    aap_mod.wait_ready(
        app_ctx, namespace=NS, timeout=20, interval=5, sleep=clock.sleep, clock=clock
    )
    reported = " ".join(app_ctx.events.sink.texts("progress"))
    assert "controller" in reported and "0/1" in reported
    assert "gateway" in reported


def test_wait_ready_returns_credentials_and_route_on_success(app_ctx) -> None:
    clock = Clock()
    app_ctx.runner = _readiness_runner(
        ["", "", "True"],
        deploys="aap-controller 1/1 1 1 6m\naap-gateway 1/1 1 1 6m\n",
        controller_ready=True,
    )
    result = aap_mod.wait_ready(
        app_ctx, namespace=NS, timeout=100, interval=5, sleep=clock.sleep, clock=clock
    )
    assert result.ready is True
    assert result.password == "s3cret"
    assert result.route == "aap-aap-operator.apps.127.0.0.1.nip.io"
    assert result.csv == "aap-operator.v2.7.0"


def test_wait_ready_timeout_is_not_a_success(app_ctx) -> None:
    clock = Clock()
    app_ctx.runner = _readiness_runner(["False"])
    result = aap_mod.wait_ready(
        app_ctx, namespace=NS, timeout=20, interval=5, sleep=clock.sleep, clock=clock
    )
    assert result.ready is False


def test_admin_password_falls_back_through_the_known_secret_names(app_ctx) -> None:
    seen = []

    def secret(argv):
        seen.append(argv[3])
        if argv[3] == "aap-controller-admin-password":
            pw = base64.b64encode(b"pw").decode()
            return CompletedCommand(argv=argv, returncode=0, stdout=pw)
        return CompletedCommand(argv=argv, returncode=0, stdout="")

    runner = FakeRunner()
    runner.ok("kubectl get aap", stdout="")
    runner.register("kubectl get secret", secret)
    app_ctx.runner = runner

    assert aap_mod.admin_password(app_ctx, NS) == "pw"
    assert seen[:2] == ["aap-admin-password", "aap-controller-admin-password"]


# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------


def test_teardown_strips_owner_references_before_deleting(app_ctx) -> None:
    """``blockOwnerDeletion: true`` deadlocks namespace termination otherwise."""
    runner = FakeRunner()
    runner.ok("kubectl get namespace")
    runner.ok("operator-sdk cleanup")
    runner.ok("kubectl scale deploy")
    runner.ok("kubectl get aap", stdout="ansibleautomationplatform.aap.ansible.com/aap\n")
    runner.ok("kubectl patch")
    runner.ok("kubectl delete")
    app_ctx.runner = runner

    assert (
        aap_mod.teardown(app_ctx, namespace=NS, which=_which("operator-sdk"), sleep=lambda _s: None)
        is True
    )

    patch = runner.index_of("kubectl patch")
    delete_cr = runner.index_of(
        ["kubectl", "delete", "ansibleautomationplatform.aap.ansible.com/aap"]
    )
    delete_ns = runner.index_of("kubectl delete namespace")
    assert patch < delete_cr < delete_ns
    assert "remove_owner_references_from_children" in runner.calls[patch].argv[-1]


def test_teardown_scales_olm_back_up_after_the_sdk_cleanup(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok("kubectl get namespace")
    runner.ok("operator-sdk cleanup")
    runner.ok("kubectl scale deploy")
    runner.ok("kubectl get aap", stdout="")
    runner.ok("kubectl delete namespace")
    app_ctx.runner = runner

    aap_mod.teardown(app_ctx, namespace=NS, which=_which("operator-sdk"), sleep=lambda _s: None)
    assert runner.called("kubectl scale deploy catalog-operator olm-operator -n olm --replicas=1")


def test_teardown_without_operator_sdk_skips_the_olm_cleanup(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok("kubectl get namespace")
    runner.ok("kubectl get aap", stdout="")
    runner.ok("kubectl delete namespace")
    app_ctx.runner = runner

    aap_mod.teardown(app_ctx, namespace=NS, which=_which(), sleep=lambda _s: None)
    assert not runner.called("operator-sdk")


def test_teardown_on_a_missing_namespace_is_a_no_op(app_ctx) -> None:
    runner = FakeRunner().fail("kubectl get namespace")
    app_ctx.runner = runner
    assert aap_mod.teardown(app_ctx, namespace=NS, which=_which()) is False
    assert "nothing to clean" in app_ctx.console.stdout
    assert not runner.called("kubectl delete")
