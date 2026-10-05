"""``cluster/preflight.py`` and its wiring into ``cli/main.py::run`` — the port
of bash's ``setup_kubeconfig``/``verify_cluster_type`` (aap-demo.sh:264-320,
2861-2874).

The bug these cover: the preflight existed nowhere, so ``--kubeconfig`` and
``--context`` were parsed and then silently ignored, and every ``kubectl``
call inherited whatever ``KUBECONFIG`` happened to be in the ambient
environment.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from aap_demo.cli import main as main_mod
from aap_demo.cluster import preflight
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, PrerequisiteError
from aap_demo.exec.runner import FakeRunner


@pytest.fixture
def have_kubectl(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(preflight.shutil, "which", lambda name: f"/usr/bin/{name}")


# -- setup_kubeconfig -------------------------------------------------------


def test_missing_kubectl_is_a_prerequisite_error(app_ctx: AppContext) -> None:
    with pytest.raises(PrerequisiteError, match="kubectl not found"):
        preflight.setup_kubeconfig(app_ctx, which=lambda name: None)


def test_explicit_kubeconfig_must_exist(app_ctx: AppContext, tmp_path: Path) -> None:
    app_ctx.kubeconfig_override = tmp_path / "nope.yaml"
    with pytest.raises(AapDemoError, match="Kubeconfig file not found"):
        preflight.setup_kubeconfig(app_ctx, which=lambda name: "/usr/bin/kubectl")


def test_explicit_kubeconfig_is_exported_to_every_later_call(
    app_ctx: AppContext, fake_runner: FakeRunner, tmp_path: Path
) -> None:
    override = tmp_path / "mine.yaml"
    override.write_text("apiVersion: v1\n")
    app_ctx.kubeconfig_override = override

    preflight.setup_kubeconfig(app_ctx, which=lambda name: "/usr/bin/kubectl")

    # No connectivity probe and no refresh for an explicit --kubeconfig
    # (bash takes the override branch and skips both).
    assert fake_runner.calls == []

    fake_runner.ok("kubectl get ns")
    app_ctx.runner.run(["kubectl", "get", "ns"])
    assert fake_runner.calls[-1].env["KUBECONFIG"] == str(override)


def test_default_kubeconfig_is_exported_and_probed(
    app_ctx: AppContext, fake_runner: FakeRunner, have_kubectl: None
) -> None:
    fake_runner.ok("kubectl cluster-info", stdout="ok")

    path = preflight.setup_kubeconfig(app_ctx)

    assert path == app_ctx.paths.kubeconfig
    assert fake_runner.calls[0].argv == ("kubectl", "cluster-info")
    assert fake_runner.calls[0].env["KUBECONFIG"] == str(path)


def test_unreachable_cluster_refreshes_the_kubeconfig_over_ssh(
    app_ctx: AppContext,
    fake_runner: FakeRunner,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    have_kubectl: None,
) -> None:
    key = tmp_path / "id_ed25519"
    key.write_text("fake")
    monkeypatch.setattr(preflight.ssh_mod, "detect_ssh_key", lambda _dir: key)

    fake_runner.fail("kubectl cluster-info")
    fake_runner.ok("ssh -p 2222", stdout="apiVersion: v1\nkind: Config\n")

    path = preflight.setup_kubeconfig(app_ctx)

    assert path.read_text() == "apiVersion: v1\nkind: Config\n"
    ssh_call = next(c for c in fake_runner.calls if c.argv[0] == "ssh")
    # Bash's refresh uses a 2-second connect timeout, not CRC_SSH_OPTS' 10.
    assert "ConnectTimeout=2" in ssh_call.argv


def test_refresh_failure_leaves_the_existing_kubeconfig_alone(
    app_ctx: AppContext,
    fake_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
    have_kubectl: None,
) -> None:
    monkeypatch.setattr(preflight.ssh_mod, "detect_ssh_key", lambda _dir: None)
    fake_runner.fail("kubectl cluster-info")

    path = preflight.setup_kubeconfig(app_ctx)

    assert not path.exists()


# -- --context --------------------------------------------------------------


def test_context_is_applied(
    app_ctx: AppContext, fake_runner: FakeRunner, have_kubectl: None
) -> None:
    app_ctx.kube_context = "mine"
    fake_runner.ok("kubectl cluster-info", stdout="ok")
    fake_runner.ok("kubectl config use-context mine")

    preflight.setup_kubeconfig(app_ctx)

    assert fake_runner.called("kubectl config use-context mine")


def test_unknown_context_errors_with_the_available_contexts(
    app_ctx: AppContext, fake_runner: FakeRunner, have_kubectl: None
) -> None:
    app_ctx.kube_context = "nope"
    fake_runner.ok("kubectl cluster-info", stdout="ok")
    fake_runner.fail("kubectl config use-context nope")
    fake_runner.ok("kubectl config get-contexts", stdout="aap-demo\nother\n")

    with pytest.raises(AapDemoError) as excinfo:
        preflight.setup_kubeconfig(app_ctx)

    assert "Context 'nope' not found" in excinfo.value.message
    assert excinfo.value.hint == "Available contexts:\n  aap-demo\n  other"


def test_unknown_context_with_no_contexts_at_all(
    app_ctx: AppContext, fake_runner: FakeRunner, have_kubectl: None
) -> None:
    app_ctx.kube_context = "nope"
    fake_runner.ok("kubectl cluster-info", stdout="ok")
    fake_runner.fail("kubectl config use-context nope")
    fake_runner.fail("kubectl config get-contexts")

    with pytest.raises(AapDemoError) as excinfo:
        preflight.setup_kubeconfig(app_ctx)

    assert excinfo.value.hint == "Available contexts:\n  (none)"


# -- verify_cluster_type ----------------------------------------------------


@pytest.mark.parametrize(
    "status_json,expected",
    [
        ("", "WARNING: No cluster exists"),
        ('{"crcStatus": "Stopped"}', "WARNING: Cluster exists but is stopped"),
    ],
)
def test_cluster_state_warning(
    app_ctx: AppContext, fake_runner: FakeRunner, status_json: str, expected: str
) -> None:
    fake_runner.ok("crc status -o json", stdout=status_json)
    preflight.warn_cluster_state(app_ctx)
    assert expected in app_ctx.console.stdout


def test_no_warning_when_the_cluster_is_running(
    app_ctx: AppContext, fake_runner: FakeRunner
) -> None:
    fake_runner.ok("crc status -o json", stdout='{"crcStatus": "Running"}')
    preflight.warn_cluster_state(app_ctx)
    assert app_ctx.console.stdout == ""


# -- wiring into cli/main.py::run ------------------------------------------


def test_run_exports_the_kubeconfig_override_to_kubectl(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture
) -> None:
    monkeypatch.setattr(preflight.shutil, "which", lambda name: f"/usr/bin/{name}")
    kubeconfig = tmp_path / "mine.yaml"
    kubeconfig.write_text("apiVersion: v1\n")

    runner = FakeRunner()
    runner.ok("curl -s --connect-timeout 5", stdout="<rss></rss>")
    runner.ok("crc status -o json", stdout='{"crcStatus": "Running"}')

    rc = main_mod.run(
        ["--kubeconfig", str(kubeconfig), "redhat-status"],
        env={"AAP_DEMO_DIR": str(tmp_path / "home"), "QUIET": "1"},
        runner=runner,
    )

    assert rc == 0
    # Every command the run issued — not just kubectl — carries KUBECONFIG.
    assert runner.calls, "the command issued no subprocesses at all"
    for call in runner.calls:
        assert call.env is not None and call.env["KUBECONFIG"] == str(kubeconfig)


def test_run_rejects_an_unknown_context(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture
) -> None:
    monkeypatch.setattr(preflight.shutil, "which", lambda name: f"/usr/bin/{name}")
    monkeypatch.setenv("AAP_DEMO_DIR", str(tmp_path / "home"))
    monkeypatch.delenv("KUBECONFIG", raising=False)

    runner = FakeRunner()
    runner.ok("kubectl cluster-info", stdout="ok")
    runner.fail("kubectl config use-context nope")
    runner.ok("kubectl config get-contexts", stdout="aap-demo\n")

    rc = main_mod.main(
        ["--context", "nope", "--config", str(tmp_path / "c.yaml"), "status"],
        runner=runner,
    )

    assert rc == 1
    err = capsys.readouterr().err
    assert "Context 'nope' not found" in err
    assert "aap-demo" in err
    # The command body never ran.
    assert not runner.called("kubectl get ns")


def test_run_warns_when_no_cluster_exists_for_redhat_status(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture
) -> None:
    """bash's ``verify_cluster_type`` covers redhat-status too (the ``*`` branch)."""
    monkeypatch.setattr(preflight.shutil, "which", lambda name: f"/usr/bin/{name}")
    monkeypatch.setattr(preflight.ssh_mod, "detect_ssh_key", lambda _dir: None)

    runner = FakeRunner()
    runner.fail("kubectl cluster-info")
    runner.fail("crc status -o json")
    runner.ok("curl -s --connect-timeout 5", stdout="<rss></rss>")

    rc = main_mod.run(
        ["redhat-status"],
        env={"AAP_DEMO_DIR": str(tmp_path / "home")},
        runner=runner,
    )

    assert rc == 0
    out = capsys.readouterr().out
    assert "WARNING: No cluster exists" in out
    assert "Run 'aap-demo create' first" in out


def test_unported_commands_skip_the_preflight(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture
) -> None:
    """A stub must still say "not yet implemented", not fail on kubectl."""
    monkeypatch.setattr(preflight.shutil, "which", lambda name: None)
    monkeypatch.setenv("AAP_DEMO_DIR", str(tmp_path / "home"))
    rc = main_mod.main(["enable", "--config", str(tmp_path / "c.yaml")], runner=FakeRunner())
    assert rc == 1
    assert "not yet implemented" in capsys.readouterr().err
