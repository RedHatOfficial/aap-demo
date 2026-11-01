"""The remote cluster check in ``cluster/preflight.py``, a port of ``kubeconfig-guard.sh``."""

from __future__ import annotations

from pathlib import Path
from typing import List

import pytest

from aap_demo.cli import main as main_mod
from aap_demo.cluster import preflight
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError
from aap_demo.exec.runner import FakeRunner

REMOTE = "https://api.prod.example.com:6443"


def _no_crc(name: str) -> str | None:
    return None if name == "crc" else f"/usr/bin/{name}"


@pytest.fixture
def kubeconfig(app_ctx: AppContext, tmp_path: Path) -> Path:
    path = tmp_path / "mine.yaml"
    path.write_text("apiVersion: v1\n")
    app_ctx.kubeconfig_override = path
    app_ctx.env = {"HOME": str(tmp_path)}
    return path


def _runner(app_ctx: AppContext, server: str) -> FakeRunner:
    runner = FakeRunner()
    runner.ok("kubectl --kubeconfig", stdout=server)
    app_ctx.runner = runner
    return runner


@pytest.mark.parametrize(
    ("server", "host"),
    [
        ("https://127.0.0.1:6443", "127.0.0.1"),
        ("https://API.CRC.testing:6443/path", "api.crc.testing"),
        ("https://[::1]:6443", "::1"),
        ("api.example.com:6443", "api.example.com"),
        ("https://[bad", ""),
    ],
)
def test_server_host(server: str, host: str) -> None:
    assert preflight._server_host(server) == host


@pytest.mark.parametrize("server", ["https://127.0.0.1:6443", "https://api.crc.testing:6443", ""])
def test_local_or_unset_server_passes(app_ctx: AppContext, kubeconfig: Path, server: str) -> None:
    _runner(app_ctx, server)
    assert preflight.setup_kubeconfig(app_ctx, which=_no_crc) == kubeconfig


def test_remote_server_is_refused_and_names_the_fix(app_ctx: AppContext, kubeconfig: Path) -> None:
    _runner(app_ctx, REMOTE)
    with pytest.raises(AapDemoError, match="remote cluster") as caught:
        preflight.setup_kubeconfig(app_ctx, which=_no_crc)
    assert REMOTE in (caught.value.hint or "")
    assert "AAP_DEMO_ALLOW_REMOTE_KUBECONFIG=true" in (caught.value.hint or "")
    assert "aap-demo kubeconfig" in (caught.value.hint or "")


def test_refusal_suggests_a_context_that_is_still_local(
    app_ctx: AppContext, kubeconfig: Path
) -> None:
    path = str(kubeconfig)
    runner = FakeRunner()
    runner.ok(["kubectl", "--kubeconfig", path, "config", "view", "--minify"], stdout=REMOTE)
    runner.ok(
        ["kubectl", "--kubeconfig", path, "config", "view", "--context=microshift"],
        stdout="https://127.0.0.1:6443",
    )
    runner.ok(["kubectl", "--kubeconfig", path, "config", "current-context"], stdout="prod")
    runner.ok(
        ["kubectl", "--kubeconfig", path, "config", "get-contexts"], stdout="prod\nmicroshift"
    )
    app_ctx.runner = runner
    with pytest.raises(AapDemoError) as caught:
        preflight.setup_kubeconfig(app_ctx, which=_no_crc)
    assert "kubectl config use-context microshift" in (caught.value.hint or "")
    assert "Current context: prod" in (caught.value.hint or "")


@pytest.mark.parametrize("value", ["1", "true", "TRUE", "yes", "YES"])
def test_explicit_opt_in_skips_the_check(app_ctx: AppContext, kubeconfig: Path, value: str) -> None:
    runner = FakeRunner()
    app_ctx.runner = runner
    app_ctx.env = {**app_ctx.env, preflight.ALLOW_REMOTE_ENV: value}
    assert preflight.setup_kubeconfig(app_ctx, which=_no_crc) == kubeconfig
    assert not runner.called("kubectl --kubeconfig")


def test_the_crc_vm_address_is_local(app_ctx: AppContext, kubeconfig: Path) -> None:
    runner = _runner(app_ctx, "https://192.168.127.2:6443")
    runner.ok("crc ip", stdout="192.168.127.2\n")
    preflight.setup_kubeconfig(app_ctx, which=lambda name: f"/usr/bin/{name}")
    assert runner.called("crc ip")


def test_a_host_from_crcs_own_kubeconfig_is_local(
    app_ctx: AppContext, kubeconfig: Path, tmp_path: Path
) -> None:
    crc_config = tmp_path / ".crc" / "machines" / "crc" / "kubeconfig"
    crc_config.parent.mkdir(parents=True)
    crc_config.write_text("apiVersion: v1\n")
    runner = FakeRunner()
    runner.ok(
        ["kubectl", "--kubeconfig", str(crc_config)],
        stdout="https://vm.crc.local:6443\n",
    )
    runner.ok(["kubectl", "--kubeconfig", str(kubeconfig)], stdout="https://vm.crc.local:6443")
    app_ctx.runner = runner
    assert preflight.setup_kubeconfig(app_ctx, which=_no_crc) == kubeconfig


def test_a_missing_kubeconfig_is_not_checked(app_ctx: AppContext) -> None:
    runner = FakeRunner().ok("kubectl cluster-info")
    app_ctx.runner = runner
    preflight.setup_kubeconfig(app_ctx, which=_no_crc)
    assert not runner.called("kubectl --kubeconfig")


def test_default_kubeconfig_is_refused_before_cluster_info(
    app_ctx: AppContext, tmp_path: Path
) -> None:
    app_ctx.env = {"HOME": str(tmp_path)}
    app_ctx.kubeconfig.parent.mkdir(parents=True, exist_ok=True)
    app_ctx.kubeconfig.write_text("apiVersion: v1\n")
    runner = _runner(app_ctx, REMOTE)
    with pytest.raises(AapDemoError, match="remote cluster"):
        preflight.setup_kubeconfig(app_ctx, which=_no_crc)
    assert not runner.called("kubectl cluster-info")


def test_guard_false_skips_the_check(app_ctx: AppContext, kubeconfig: Path) -> None:
    runner = FakeRunner()
    app_ctx.runner = runner
    preflight.setup_kubeconfig(app_ctx, which=_no_crc, guard=False)
    assert not runner.called("kubectl --kubeconfig")


@pytest.mark.parametrize(
    ("command", "guard"),
    [("status", True), ("clean", True), ("stop", False), ("ssh", False), ("kubeconfig", False)],
)
def test_preflight_guards_commands_that_use_the_api(
    app_ctx: AppContext, monkeypatch: pytest.MonkeyPatch, command: str, guard: bool
) -> None:
    seen: List[bool] = []
    monkeypatch.setattr(
        main_mod.preflight, "setup_kubeconfig", lambda ctx, guard=True: seen.append(guard)
    )
    monkeypatch.setattr(main_mod.preflight, "warn_cluster_state", lambda ctx: None)
    monkeypatch.setattr(main_mod, "_fleet_needs_cluster", lambda command, args: False)
    main_mod._preflight(app_ctx, command, None)  # type: ignore[arg-type]
    assert seen == [guard]


def test_a_hung_crc_ip_counts_as_not_local(app_ctx: AppContext, kubeconfig: Path) -> None:
    runner = _runner(app_ctx, REMOTE)
    real_run = runner.run

    def hang(argv, **kwargs):  # type: ignore[no-untyped-def]
        if list(argv)[:2] == ["crc", "ip"]:
            raise AapDemoError("command timed out after 2s: crc ip")
        return real_run(argv, **kwargs)

    runner.run = hang  # type: ignore[method-assign]
    with pytest.raises(AapDemoError, match="remote cluster"):
        preflight.setup_kubeconfig(app_ctx, which=lambda name: f"/usr/bin/{name}")


def test_a_refreshed_kubeconfig_is_checked_again(
    app_ctx: AppContext, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    app_ctx.env = {"HOME": str(tmp_path)}
    key = tmp_path / "id_ed25519"
    key.write_text("fake")
    monkeypatch.setattr(preflight.ssh_mod, "detect_ssh_key", lambda _dir: key)
    runner = FakeRunner().fail("kubectl cluster-info")
    runner.ok("ssh -p 2222", stdout="apiVersion: v1\n")
    runner.ok("kubectl --kubeconfig", stdout=REMOTE)
    app_ctx.runner = runner
    with pytest.raises(AapDemoError, match="remote cluster"):
        preflight.setup_kubeconfig(app_ctx, which=_no_crc)
