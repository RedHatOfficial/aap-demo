"""Catalog readiness, TRANSIENT_FAILURE recovery, and the MicroShift 4.22+ policy.

The failure shapes exercised here are the ones ``.claude/CLAUDE.md`` lists as
recurring in the field: a CatalogSource stuck in TRANSIENT_FAILURE, a catalog
pod in ImagePullBackOff, and a pod failing GPG signature validation.
"""

from __future__ import annotations

import pytest

from aap_demo.cluster import catalog_signature as cs
from aap_demo.exec.runner import CompletedCommand, FakeRunner

NS = "aap-operator"


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


@pytest.fixture
def ssh_key(app_ctx, tmp_path):
    machines = tmp_path / ".crc" / "machines" / "crc"
    machines.mkdir(parents=True)
    (machines / "id_ecdsa").write_text("key")
    app_ctx.env = {"HOME": str(tmp_path)}
    return machines / "id_ecdsa"


# ---------------------------------------------------------------------------
# Version gating
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("version", "expected"),
    [
        ("4.22", True),
        ("4.23", True),
        ("5.0", True),
        ("4.21", False),
        ("4.20", False),
        ("3.11", False),
    ],
)
def test_needs_relaxation_gates_on_4_22(version: str, expected: bool) -> None:
    assert cs.needs_relaxation(version) is expected


def test_needs_relaxation_tolerates_garbage() -> None:
    assert cs.needs_relaxation("not-a-version") is False


def test_resolve_ocp_version_prefers_the_env_var(app_ctx) -> None:
    app_ctx.env = {"AAP_OCP_VERSION": "4.19"}
    assert cs.resolve_ocp_version(app_ctx) == "4.19"


def test_resolve_ocp_version_falls_back_through_crc_then_cluster_then_default(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok("crc status -o json", stdout='{"openshiftVersion": "4.22.3"}')
    app_ctx.runner = runner
    assert cs.resolve_ocp_version(app_ctx) == "4.22"

    runner = FakeRunner()
    runner.fail("crc status -o json")
    runner.ok("kubectl get clusterversion", stdout="4.21.7")
    app_ctx.runner = runner
    assert cs.resolve_ocp_version(app_ctx) == "4.21"

    runner = FakeRunner()
    runner.fail("crc status -o json")
    runner.fail("kubectl get clusterversion")
    app_ctx.runner = runner
    assert cs.resolve_ocp_version(app_ctx) == cs.DEFAULT_OCP_VERSION


# ---------------------------------------------------------------------------
# Policy relaxation
# ---------------------------------------------------------------------------


def test_relaxation_is_skipped_below_4_22(app_ctx) -> None:
    app_ctx.env = {"AAP_OCP_VERSION": "4.20"}
    runner = FakeRunner()
    app_ctx.runner = runner
    assert cs.relax_signature_policy(app_ctx) is True
    assert runner.calls == []


def test_relaxation_writes_the_policy_and_reloads_crio(app_ctx, ssh_key) -> None:
    app_ctx.env = {**app_ctx.env, "AAP_OCP_VERSION": "4.22"}
    runner = FakeRunner()
    runner.ok(["ssh", "*", "*", "*"], stdout="CHANGED")
    app_ctx.runner = runner

    assert cs.relax_signature_policy(app_ctx) is True
    joined = " ".join(runner.commands)
    assert "insecureAcceptAnything" in joined
    assert "systemctl reload crio" in joined


def test_already_relaxed_does_not_reload_crio_unless_forced(app_ctx, ssh_key) -> None:
    app_ctx.env = {**app_ctx.env, "AAP_OCP_VERSION": "4.22"}
    runner = FakeRunner().ok(["ssh"], stdout="UNCHANGED")
    app_ctx.runner = runner

    assert cs.relax_signature_policy(app_ctx) is True
    assert "systemctl reload crio" not in " ".join(runner.commands)

    runner = FakeRunner().ok(["ssh"], stdout="UNCHANGED")
    app_ctx.runner = runner
    assert cs.relax_signature_policy(app_ctx, force_crio_reload=True) is True
    assert "systemctl reload crio" in " ".join(runner.commands)


def test_relaxation_without_an_ssh_key_reports_the_fix(app_ctx, tmp_path) -> None:
    app_ctx.env = {"HOME": str(tmp_path), "AAP_OCP_VERSION": "4.22"}
    app_ctx.runner = FakeRunner()
    assert cs.relax_signature_policy(app_ctx) is False
    assert "MicroShift 4.22+ blocks unsigned" in app_ctx.console.stderr
    assert "aap-demo ssh" in app_ctx.console.stderr


def test_unexpected_ssh_output_is_treated_as_failure(app_ctx, ssh_key) -> None:
    app_ctx.env = {**app_ctx.env, "AAP_OCP_VERSION": "4.22"}
    app_ctx.runner = FakeRunner().ok(["ssh"], stdout="???")
    assert cs.relax_signature_policy(app_ctx) is False
    assert "Unexpected signature policy response" in app_ctx.console.stderr


# ---------------------------------------------------------------------------
# Pod inspection
# ---------------------------------------------------------------------------


def test_image_pull_backoff_is_detected_from_the_container_state(app_ctx) -> None:
    """The pod *phase* stays Pending while the container reports the backoff."""
    runner = FakeRunner()
    runner.ok(
        [
            "kubectl",
            "get",
            "pods",
            "-n",
            NS,
            "-l",
            cs.CATALOG_SELECTOR,
            "-o",
            "jsonpath={.items[0].status.phase}",
        ],
        stdout="Pending",
    )
    runner.ok("kubectl get pods", stdout="ImagePullBackOff: back-off pulling image")
    app_ctx.runner = runner
    assert cs.has_image_pull_backoff(app_ctx, NS) is True


def test_healthy_catalog_pod_is_not_a_pull_failure(app_ctx) -> None:
    runner = FakeRunner().ok("kubectl get pods", stdout="Running")
    app_ctx.runner = runner
    assert cs.has_image_pull_backoff(app_ctx, NS) is False


def test_signature_failure_is_found_in_the_events_when_not_in_the_waiting_state(app_ctx) -> None:
    calls = iter(["catalog-pod-1", "", "Pending", "ImagePullBackOff: x", ""])
    runner = FakeRunner()
    runner.register(
        "kubectl get pods",
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=next(calls, "")),
    )
    runner.ok("kubectl get events", stdout="SignatureValidationFailed for image")
    app_ctx.runner = runner
    assert cs.has_signature_failure(app_ctx, NS) is True


def test_no_catalog_pod_is_not_a_signature_failure(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok("kubectl get pods", stdout="")
    assert cs.has_signature_failure(app_ctx, NS) is False


@pytest.mark.parametrize(
    ("state", "phase", "expected"),
    [
        ("TRANSIENT_FAILURE", "Pending", True),
        ("CONNECTING", "ContainerCreating", True),
        ("", "Running", True),
        ("READY", "Running", False),
        ("TRANSIENT_FAILURE", "CrashLoopBackOff", False),
    ],
)
def test_is_pulling_selects_the_progress_line(state, phase, expected) -> None:
    assert cs.is_pulling(state, phase) is expected


def test_timeout_seconds_honours_both_env_names(app_ctx) -> None:
    assert cs.timeout_seconds(app_ctx) == cs.DEFAULT_CATALOG_TIMEOUT
    app_ctx.env = {"AO_CATALOG_TIMEOUT": "120"}
    assert cs.timeout_seconds(app_ctx) == 120
    app_ctx.env = {"AAP_CATALOG_TIMEOUT": "60", "AO_CATALOG_TIMEOUT": "120"}
    assert cs.timeout_seconds(app_ctx) == 60
    app_ctx.env = {"AAP_CATALOG_TIMEOUT": "nonsense"}
    assert cs.timeout_seconds(app_ctx) == cs.DEFAULT_CATALOG_TIMEOUT


# ---------------------------------------------------------------------------
# The wait
# ---------------------------------------------------------------------------


def _catalog_runner(states, pod_phase="Running", waiting_text="", events_stdout=""):
    """A runner whose CatalogSource state walks ``states`` on each read."""
    it = iter(states)
    runner = FakeRunner()
    runner.register(
        "kubectl get catalogsource",
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=next(it, states[-1])),
    )
    runner.register(
        [
            "kubectl",
            "get",
            "pods",
            "-n",
            NS,
            "-l",
            cs.CATALOG_SELECTOR,
            "-o",
            "jsonpath={.items[0].status.phase}",
        ],
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=pod_phase),
    )
    runner.register(
        "kubectl get pods",
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=waiting_text),
    )
    runner.ok("kubectl get events", stdout=events_stdout)
    runner.ok("kubectl get pod", stdout="")
    return runner


def test_catalog_ready_immediately(app_ctx) -> None:
    clock = Clock()
    app_ctx.runner = _catalog_runner(["READY"])
    result = cs.wait_for_catalog_ready(app_ctx, NS, sleep=clock.sleep, clock=clock)
    assert result.ok and result.outcome == cs.READY


def test_catalog_transient_failure_then_ready(app_ctx) -> None:
    clock = Clock()
    app_ctx.runner = _catalog_runner(
        ["TRANSIENT_FAILURE", "TRANSIENT_FAILURE", "TRANSIENT_FAILURE", "READY"]
    )
    result = cs.wait_for_catalog_ready(
        app_ctx, NS, timeout=60, interval=5, sleep=clock.sleep, clock=clock
    )
    assert result.ok


def test_catalog_stuck_in_transient_failure_times_out(app_ctx) -> None:
    """A timeout must surface as a timeout, not as a silent success (R5)."""
    clock = Clock()
    app_ctx.runner = _catalog_runner(["TRANSIENT_FAILURE"])
    result = cs.wait_for_catalog_ready(
        app_ctx, NS, timeout=20, interval=5, sleep=clock.sleep, clock=clock
    )
    assert result.ok is False
    assert result.outcome == cs.TIMEOUT


def test_signature_failure_is_fixed_once_then_reported(app_ctx, ssh_key) -> None:
    clock = Clock()
    app_ctx.env = {**app_ctx.env, "AAP_OCP_VERSION": "4.22"}
    runner = _catalog_runner(
        ["TRANSIENT_FAILURE"],
        pod_phase="Pending",
        waiting_text="SignatureValidationFailed: bad signature",
        events_stdout="SignatureValidationFailed",
    )
    # catalog_pod_name reads the same jsonpath family; give the SSH fix a hit.
    runner.ok(["ssh"], stdout="CHANGED")
    runner.ok("kubectl delete pod")
    app_ctx.runner = runner

    result = cs.wait_for_catalog_ready(
        app_ctx, NS, timeout=600, interval=5, sleep=clock.sleep, clock=clock
    )
    assert result.outcome == cs.SIGNATURE_FAILURE
    assert "Restarting catalog pod" in app_ctx.console.stdout
    # Recovery is attempted exactly once, not on every poll.
    assert len([c for c in runner.calls if c.argv[:3] == ("kubectl", "delete", "pod")]) == 1


def test_plain_pull_failure_restarts_the_pod_once_then_reports_detail(app_ctx) -> None:
    clock = Clock()
    runner = _catalog_runner(
        ["TRANSIENT_FAILURE"],
        pod_phase="Pending",
        waiting_text="ImagePullBackOff: quota exceeded",
        events_stdout="no signature trouble here",
    )
    runner.ok("kubectl delete pod")
    app_ctx.runner = runner

    result = cs.wait_for_catalog_ready(
        app_ctx, NS, timeout=600, interval=5, sleep=clock.sleep, clock=clock
    )
    assert result.outcome == cs.PULL_FAILURE
    assert result.detail  # the pod's waiting reason is carried to the caller


def test_report_signature_failure_names_the_demo_only_fix(app_ctx) -> None:
    cs.report_signature_failure(app_ctx)
    assert "SignatureValidationFailed" in app_ctx.console.stderr
    assert "MicroShift 4.22+" in app_ctx.console.stderr


def test_scc_admission_failure_stops_the_catalog_wait(app_ctx) -> None:
    clock = Clock()
    runner = _catalog_runner(
        ["TRANSIENT_FAILURE"],
        waiting_text="unable to validate against any security context constraint",
    )
    app_ctx.runner = runner

    result = cs.wait_for_catalog_ready(
        app_ctx, NS, timeout=60, interval=5, sleep=clock.sleep, clock=clock
    )
    assert result.outcome == cs.SCC_FAILURE
    assert "rejected by SCC admission" in app_ctx.console.stderr
    assert f"add-scc-to-user anyuid -z {cs.CATALOG_NAME} -n {NS}" in app_ctx.console.stderr
    assert not runner.called("kubectl delete pod")


def test_service_wait_succeeds_when_the_pod_and_endpoint_are_ready(app_ctx) -> None:
    clock = Clock()

    def pods(argv):
        text = "True" if "Ready" in " ".join(argv) else "Running"
        return CompletedCommand(argv=argv, returncode=0, stdout=text)

    runner = FakeRunner()
    runner.register("kubectl get pods", pods)
    runner.ok("kubectl get endpoints", stdout="10.128.0.4")
    app_ctx.runner = runner

    result = cs.wait_for_catalog_service_ready(
        app_ctx, NS, "community-operators", timeout=15, interval=5, sleep=clock.sleep, clock=clock
    )
    assert result.ok
    assert runner.called("kubectl get endpoints community-operators")


def test_service_wait_stops_on_scc_admission_failure(app_ctx) -> None:
    clock = Clock()
    runner = FakeRunner()
    runner.ok(
        "kubectl get pods",
        stdout="forbidden: unable to validate against any security context constraint",
    )
    runner.ok("kubectl get events", stdout="")
    runner.ok("kubectl get pod", stdout="redhat-operators")
    app_ctx.runner = runner

    result = cs.wait_for_catalog_service_ready(
        app_ctx, NS, timeout=30, interval=5, sleep=clock.sleep, clock=clock
    )
    assert result.outcome == cs.SCC_FAILURE
    assert "ServiceAccount: redhat-operators" in app_ctx.console.stderr
