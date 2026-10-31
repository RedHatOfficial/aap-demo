"""``cli/ops.py``: ``ssh`` and ``kubeconfig`` command bodies (design §3.3 phase 1).

``ssh`` replaces the process on success (design §14 R10), so these tests only
exercise it through ``exec/ssh.py::interactive_shell``'s injectable seams —
never the real ``os.execvp`` default — to avoid actually spawning ssh.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, List

import pytest

from aap_demo.cli import ops
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, ClusterUnreachableError
from aap_demo.exec.runner import FakeRunner

SAMPLE_KUBECONFIG = """\
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: QQ==
    server: https://127.0.0.1:6443
  name: microshift
contexts:
- context: {cluster: microshift, namespace: default, user: user}
  name: microshift
current-context: microshift
users:
- name: user
  user: {client-certificate-data: QQ==, client-key-data: QQ==}
"""


# -- ssh ----------------------------------------------------------------


def test_ssh_raises_when_no_key_found(app_ctx: AppContext, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(ops.ssh_mod, "detect_ssh_key", lambda _dir: None)
    with pytest.raises(ClusterUnreachableError, match="No CRC SSH key found"):
        ops.ssh(app_ctx, argparse_namespace())


def test_ssh_hands_off_to_interactive_shell(
    app_ctx: AppContext, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    key = tmp_path / "id_ed25519"
    key.write_text("fake")
    monkeypatch.setattr(ops.ssh_mod, "detect_ssh_key", lambda _dir: key)

    calls: List[Path] = []
    monkeypatch.setattr(ops.ssh_mod, "interactive_shell", lambda k, **kw: calls.append(k))

    rc = ops.ssh(app_ctx, argparse_namespace())

    assert rc == 0
    assert calls == [key]


# -- kubeconfig -----------------------------------------------------------


def argparse_namespace(**kwargs: Any) -> Any:
    import argparse

    return argparse.Namespace(**kwargs)


def test_kubeconfig_raises_when_cluster_not_running(
    app_ctx: AppContext, fake_runner: FakeRunner
) -> None:
    fake_runner.fail("crc status -o json")
    with pytest.raises(ClusterUnreachableError, match="Cluster not running"):
        ops.kubeconfig(app_ctx, argparse_namespace())
    # Must fail before ever reaching for an SSH key or touching the network.
    assert not fake_runner.called("ssh")


def test_kubeconfig_raises_when_no_ssh_key(
    app_ctx: AppContext, fake_runner: FakeRunner, monkeypatch: pytest.MonkeyPatch
) -> None:
    fake_runner.ok("crc status -o json", stdout='{"crcStatus": "Running"}')
    monkeypatch.setattr(ops.ssh_mod, "detect_ssh_key", lambda _dir: None)
    with pytest.raises(ClusterUnreachableError, match="No CRC SSH key found"):
        ops.kubeconfig(app_ctx, argparse_namespace())


def test_kubeconfig_happy_path_writes_and_reports_the_destination(
    app_ctx: AppContext,
    fake_runner: FakeRunner,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    key = tmp_path / "id_ed25519"
    key.write_text("fake")
    monkeypatch.setattr(ops.ssh_mod, "detect_ssh_key", lambda _dir: key)

    fake_runner.ok("crc status -o json", stdout='{"crcStatus": "Running"}')
    fake_runner.ok("ssh -p 2222", stdout=SAMPLE_KUBECONFIG)
    fake_runner.ok("kubectl config view", stdout=SAMPLE_KUBECONFIG)

    app_ctx.env = {"HOME": str(tmp_path)}
    rc = ops.kubeconfig(app_ctx, argparse_namespace())

    assert rc == 0
    destination = app_ctx.kubeconfig
    assert destination.is_file()
    activated = tmp_path / ".kube" / "config"
    assert activated.is_file()
    loaded = __import__("yaml").safe_load(activated.read_text())
    assert loaded["current-context"] == "aap-demo"
    assert "Current context is aap-demo" in app_ctx.console.stdout
    assert "KUBECONFIG=~/state/kubeconfig.microshift oc cluster-info" in app_ctx.console.stdout
    assert "Saved to ~/state/kubeconfig.microshift" in app_ctx.console.stdout


def test_oc_uses_the_state_file_even_when_kubeconfig_is_set(
    app_ctx: AppContext, monkeypatch: pytest.MonkeyPatch
) -> None:
    app_ctx.paths.state_dir.mkdir(parents=True, exist_ok=True)
    app_ctx.paths.kubeconfig.write_text("apiVersion: v1\nkind: Config\n")
    app_ctx.env = {"PATH": "/usr/bin", "HOME": "/tmp", "KUBECONFIG": "/elsewhere/config"}
    seen: dict = {}

    def exec_func(kubeconfig: Path, args: list, *, env: dict, **_kwargs: object) -> None:
        seen["kubeconfig"] = kubeconfig
        seen["args"] = list(args)
        seen["env"] = env["KUBECONFIG"]

    monkeypatch.setattr(ops.oc_mod, "exec_oc", exec_func)
    assert ops.oc(app_ctx, argparse_namespace(oc_args=["get", "pods", "-n", "aap"])) == 0
    assert seen["kubeconfig"] == app_ctx.paths.kubeconfig
    assert seen["args"] == ["get", "pods", "-n", "aap"]


def test_oc_exec_sets_kubeconfig_and_hides_the_home_directory(tmp_path: Path) -> None:
    from aap_demo.exec import oc as oc_mod

    secret = tmp_path / "home" / ".local" / "state" / "aap-demo" / "kubeconfig.microshift"
    secret.parent.mkdir(parents=True)
    secret.write_text("apiVersion: v1\n")
    seen: dict = {}

    def exec_func(file: str, argv: list, env: dict) -> None:
        seen["argv"] = list(argv)
        seen["kubeconfig"] = env["KUBECONFIG"]

    oc_mod.exec_oc(
        secret,
        ["cluster-info"],
        env={"HOME": str(tmp_path / "home"), "PATH": "/usr/bin"},
        exec_func=exec_func,
        is_windows=False,
    )
    assert seen["argv"] == ["oc", "cluster-info"]
    assert seen["kubeconfig"] == str(secret)

    missing = tmp_path / "missing"
    with pytest.raises(AapDemoError, match="~/missing"):
        oc_mod.exec_oc(missing, ["cluster-info"], env={"HOME": str(tmp_path)}, exec_func=exec_func)


# -- config edit / secrets migrate: no direct subprocess, no private imports --


def test_config_edit_goes_through_the_runner(app_ctx: AppContext, fake_runner: FakeRunner) -> None:
    """Only ``exec/runner.py`` may call subprocess (design §2.2)."""
    app_ctx.env = {"EDITOR": "vi"}
    fake_runner.ok(["vi"])

    rc = ops.config(app_ctx, argparse_namespace(config_action="edit"))

    assert rc == 0
    assert fake_runner.calls[-1].argv == ("vi", str(app_ctx.paths.config_file))


def test_config_secrets_migrate_uses_the_public_migration_api(
    app_ctx: AppContext, tmp_path: Path
) -> None:
    from aap_demo.core import migration

    assert not hasattr(migration, "_import_secret")
    app_ctx.paths.legacy_dir.mkdir(parents=True, exist_ok=True)
    app_ctx.paths.legacy_config_file.write_text("NAMESPACE=aap-operator\n")
    (app_ctx.paths.legacy_dir / "galaxy-token").write_text("s3cret")

    rc = ops.config(app_ctx, argparse_namespace(config_action="secrets", secrets_action="migrate"))

    assert rc == 0
    assert app_ctx.secrets.get("galaxy-token") == "s3cret"


def test_config_set_pull_secret_stores_the_path_the_user_gave(app_ctx: AppContext) -> None:
    rc = ops.config(
        app_ctx,
        argparse_namespace(
            config_action="set",
            key="pull-secret",
            value="~/secrets/pull-secret.txt",
        ),
    )
    assert rc == 0
    text = app_ctx.paths.config_file.read_text(encoding="utf-8")
    assert "pull-secret.txt" in text
    assert "pull-secret =" in app_ctx.console.stdout
