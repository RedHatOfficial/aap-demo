"""The SELinux boolean that lets Fleet nodes run systemd as PID 1."""

from __future__ import annotations

import pytest

from aap_demo.addons.fleet import node
from aap_demo.core.errors import AapDemoError, PrerequisiteError
from aap_demo.exec.runner import CompletedCommand, FakeRunner


@pytest.fixture
def crc_home(app_ctx, tmp_path):
    machines = tmp_path / "home" / ".crc" / "machines" / "crc"
    machines.mkdir(parents=True)
    (machines / "id_ecdsa").write_text("KEY\n", encoding="utf-8")
    app_ctx.env = {"HOME": str(tmp_path / "home")}
    return app_ctx


def _vm(getsebool: str, *, set_ok: bool = True) -> FakeRunner:
    runner = FakeRunner()

    def remote(argv):
        command = argv[-1]
        if command.startswith("sudo getsebool"):
            return CompletedCommand(argv=tuple(argv), returncode=0, stdout=getsebool)
        if command.startswith("sudo setsebool"):
            return CompletedCommand(argv=tuple(argv), returncode=0 if set_ok else 1)
        raise AssertionError(command)

    runner.register(["ssh"], remote)
    return runner


def _remote_commands(runner: FakeRunner) -> list:
    return [call.argv[-1] for call in runner.calls]


def test_an_enabled_boolean_is_left_alone(crc_home) -> None:
    crc_home.runner = _vm("container_manage_cgroup --> on\n")

    node.allow_systemd(crc_home)

    assert _remote_commands(crc_home.runner) == ["sudo getsebool container_manage_cgroup"]


def test_a_disabled_boolean_is_turned_on_persistently(crc_home) -> None:
    crc_home.runner = _vm("container_manage_cgroup --> off\n")

    node.allow_systemd(crc_home)

    assert _remote_commands(crc_home.runner)[-1] == ("sudo setsebool -P container_manage_cgroup on")
    assert "container_manage_cgroup" in crc_home.console.stdout


def test_a_failed_setsebool_stops_enable(crc_home) -> None:
    crc_home.runner = _vm("container_manage_cgroup --> off\n", set_ok=False)

    with pytest.raises(AapDemoError, match="container_manage_cgroup"):
        node.allow_systemd(crc_home)


def test_a_missing_crc_key_is_a_prerequisite_error(app_ctx, tmp_path) -> None:
    app_ctx.env = {"HOME": str(tmp_path / "empty-home")}
    app_ctx.runner = FakeRunner()

    with pytest.raises(PrerequisiteError, match="CRC SSH key"):
        node.allow_systemd(app_ctx)

    assert app_ctx.runner.calls == []
