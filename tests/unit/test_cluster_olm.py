"""``cluster/olm.py`` and ``exec/operator_sdk.py`` — install, idempotency, CSV waits."""

from __future__ import annotations

import os
from typing import Optional

import pytest

from aap_demo.cluster import olm
from aap_demo.core.errors import AapDemoError, PrerequisiteError
from aap_demo.exec import operator_sdk as sdk
from aap_demo.exec.runner import CompletedCommand, FakeRunner

NS = "aap-operator"


def _which(*present: str):
    def which(name: str) -> Optional[str]:
        return f"/usr/bin/{name}" if name in present else None

    return which


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


# ---------------------------------------------------------------------------
# ensure_installed
# ---------------------------------------------------------------------------


def test_already_installed_short_circuits_on_the_subscription_crd(app_ctx) -> None:
    """Bash's idempotency check is the CRD, not a namespace or a pod."""
    runner = FakeRunner()
    runner.ok("kubectl cluster-info")
    runner.ok(["kubectl", "get", "crd", olm.SUBSCRIPTION_CRD])
    runner.ok("operator-sdk olm status", stdout="  Version: v0.28.0\n")
    app_ctx.runner = runner

    assert olm.ensure_installed(app_ctx, which=_which("operator-sdk", "kubectl")) is True
    assert not runner.called("operator-sdk olm install")
    assert "already installed" in app_ctx.console.stdout


def test_fresh_install_removes_the_operatorhubio_catalog(app_ctx) -> None:
    """That CatalogSource cannot start on MicroShift, so bash deletes it every time."""
    runner = FakeRunner()
    runner.ok("kubectl cluster-info")
    runner.fail(["kubectl", "get", "crd", olm.SUBSCRIPTION_CRD])
    runner.ok("operator-sdk olm install")
    runner.ok("kubectl delete catsrc")
    app_ctx.runner = runner

    assert olm.ensure_installed(app_ctx, which=_which("operator-sdk", "kubectl")) is True
    assert runner.called("kubectl delete catsrc operatorhubio-catalog -n olm")


def test_install_reporting_failure_but_leaving_the_crds_is_treated_as_success(app_ctx) -> None:
    """``operator-sdk olm install`` times out aggressively on installs that worked."""
    crd_checks = iter([1, 0])
    runner = FakeRunner()
    runner.ok("kubectl cluster-info")
    runner.register(
        ["kubectl", "get", "crd", olm.SUBSCRIPTION_CRD],
        lambda argv: CompletedCommand(argv=argv, returncode=next(crd_checks, 0)),
    )
    runner.fail("operator-sdk olm install")
    runner.ok("kubectl delete catsrc")
    app_ctx.runner = runner

    assert olm.ensure_installed(app_ctx, which=_which("operator-sdk", "kubectl")) is True
    assert "likely succeeded despite timeout" in app_ctx.console.stdout


def test_partial_install_is_cleaned_up_and_fatal(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok("kubectl cluster-info")
    runner.fail(["kubectl", "get", "crd", olm.SUBSCRIPTION_CRD])
    runner.fail("operator-sdk olm install")
    runner.ok("kubectl delete namespace")
    app_ctx.runner = runner

    with pytest.raises(AapDemoError) as excinfo:
        olm.ensure_installed(app_ctx, which=_which("operator-sdk", "kubectl"))
    assert "OLM installation failed" in excinfo.value.message
    assert runner.called("kubectl delete namespace olm")
    assert runner.called("kubectl delete namespace operators")


def test_unreachable_cluster_fails_before_touching_operator_sdk(app_ctx) -> None:
    runner = FakeRunner().fail("kubectl cluster-info")
    app_ctx.runner = runner
    with pytest.raises(AapDemoError) as excinfo:
        olm.ensure_installed(app_ctx, which=_which("kubectl"))
    assert "not connected to cluster" in excinfo.value.message
    assert not runner.called("operator-sdk")


# ---------------------------------------------------------------------------
# operator-sdk auto-install
# ---------------------------------------------------------------------------


def test_operator_sdk_already_on_path_is_not_downloaded(app_ctx) -> None:
    runner = FakeRunner()
    app_ctx.runner = runner
    assert sdk.ensure_available(app_ctx, which=_which("operator-sdk")).name == "operator-sdk"
    assert runner.calls == []


def _linux(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(sdk.platform, "system", lambda: "Linux")
    monkeypatch.setattr(sdk.platform, "machine", lambda: "x86_64")


def test_operator_sdk_is_downloaded_to_local_bin(app_ctx, tmp_path, monkeypatch) -> None:
    _linux(monkeypatch)
    app_ctx.env = {"HOME": str(tmp_path), "PATH": "/usr/bin"}
    runner = FakeRunner()
    runner.register(
        "curl",
        lambda argv: _write_and_ok(argv, tmp_path / ".local" / "bin" / "operator-sdk"),
    )
    runner.fail("sudo -n true")
    app_ctx.runner = runner

    path = sdk.ensure_available(app_ctx, which=_which())
    assert path == tmp_path / ".local" / "bin" / "operator-sdk"
    if os.name != "nt":
        assert path.stat().st_mode & 0o111
    assert sdk.SDK_VERSION in runner.commands[0]
    assert "Add to PATH" in app_ctx.console.stdout


def test_operator_sdk_download_failure_is_fatal_with_the_url(
    app_ctx, tmp_path, monkeypatch
) -> None:
    _linux(monkeypatch)
    app_ctx.env = {"HOME": str(tmp_path)}
    app_ctx.runner = FakeRunner().fail("curl")
    with pytest.raises(AapDemoError) as excinfo:
        sdk.ensure_available(app_ctx, which=_which())
    assert "operator-sdk" in (excinfo.value.hint or "")


def test_unsupported_platform_is_a_prerequisite_error() -> None:
    with pytest.raises(PrerequisiteError):
        sdk.platform_slug("Plan9", "x86_64")
    with pytest.raises(PrerequisiteError):
        sdk.platform_slug("Linux", "mips")


def test_download_url_shape() -> None:
    assert sdk.download_url("Darwin", "arm64").endswith(
        f"{sdk.SDK_VERSION}/operator-sdk_darwin_arm64"
    )


# ---------------------------------------------------------------------------
# CSV waits
# ---------------------------------------------------------------------------


def test_find_csv_picks_the_aap_operator_row(app_ctx) -> None:
    runner = FakeRunner().ok(
        "kubectl get csv",
        stdout=(
            "NAME                      DISPLAY  VERSION  PHASE\n"
            "other-operator.v1.0.0     Other    1.0.0    Succeeded\n"
            "aap-operator.v2.7.0-0.1   AAP      2.7.0    Installing\n"
        ),
    )
    app_ctx.runner = runner
    assert olm.find_csv(app_ctx, NS) == "aap-operator.v2.7.0-0.1"


def test_wait_for_csv_returns_empty_on_timeout(app_ctx) -> None:
    """Ten minutes of nothing must not read as success (R5)."""
    clock = Clock()
    app_ctx.runner = FakeRunner().ok("kubectl get csv", stdout="")
    assert (
        olm.wait_for_csv(app_ctx, NS, attempts=3, interval=1, sleep=clock.sleep, clock=clock) == ""
    )


def test_wait_for_csv_returns_the_name_once_it_appears(app_ctx) -> None:
    clock = Clock()
    rows = iter(["", "", "aap-operator.v2.7.0 AAP 2.7.0 Installing"])
    runner = FakeRunner()
    runner.register(
        "kubectl get csv",
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=next(rows, "")),
    )
    app_ctx.runner = runner
    assert (
        olm.wait_for_csv(app_ctx, NS, attempts=10, interval=1, sleep=clock.sleep, clock=clock)
        == "aap-operator.v2.7.0"
    )


def test_csv_succeeded_wait_reports_its_result_instead_of_swallowing_it(app_ctx) -> None:
    app_ctx.runner = FakeRunner().fail("kubectl wait")
    assert olm.wait_csv_succeeded(app_ctx, NS, "aap-operator.v2.7.0") is False
    app_ctx.runner = FakeRunner().ok("kubectl wait")
    assert olm.wait_csv_succeeded(app_ctx, NS, "aap-operator.v2.7.0") is True


def test_manifests_are_applied_on_stdin_not_from_a_temp_file(app_ctx) -> None:
    runner = FakeRunner().ok("kubectl apply -f -")
    app_ctx.runner = runner
    olm.apply_catalogsource(app_ctx, NS, "4.22")
    olm.apply_operatorgroup(app_ctx, NS)
    olm.apply_subscription(app_ctx, NS, "stable-2.7")
    assert [c.argv for c in runner.calls] == [("kubectl", "apply", "-f", "-")] * 3
    assert all("kind:" in (c.input or "") for c in runner.calls)


def _write_and_ok(argv, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text("#!/bin/sh\n")
    return CompletedCommand(argv=argv, returncode=0)
