"""``aap-demo update`` upgrades the pipx install after checking how it was installed."""

from __future__ import annotations

import json
import subprocess

import pytest

from aap_demo.core import self_update
from aap_demo.core.errors import AapDemoError, PrerequisiteError
from aap_demo.core.version import VersionInfo
from aap_demo.exec.runner import CompletedCommand, FakeRunner

PIPX = "/usr/bin/pipx"


def _info(mode: str = "package") -> VersionInfo:
    return VersionInfo(version="2.0.0.dev0", source="/tmp/aap-demo", install_mode=mode)


def _listing(spec: str = "aap-demo") -> str:
    return json.dumps(
        {
            "venvs": {
                "aap-demo": {
                    "metadata": {"main_package": {"package": "aap-demo", "package_or_url": spec}}
                }
            }
        }
    )


def _runner(spec: str = "aap-demo", *, upgrade: bool = True) -> FakeRunner:
    runner = FakeRunner()
    runner.ok([PIPX, "list", "--json"], stdout=_listing(spec))
    if upgrade:
        runner.ok([PIPX, "upgrade", "aap-demo"])
    return runner


def test_update_upgrades_a_pypi_pipx_install(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr(self_update.shutil, "which", lambda _name: PIPX)
    monkeypatch.setattr(self_update, "version_info", lambda _runner: _info())
    app_ctx.runner = _runner()

    assert self_update.run(app_ctx) == 0

    assert app_ctx.runner.called([PIPX, "upgrade", "aap-demo"])
    assert [call.timeout for call in app_ctx.runner.calls] == [
        self_update.LIST_TIMEOUT,
        self_update.UPGRADE_TIMEOUT,
        self_update.LIST_TIMEOUT,
    ]
    assert "Installed 2.0.0.dev0" in app_ctx.console.stdout
    assert "pipx upgrade finished" in app_ctx.console.stdout
    assert "aap-demo version" in app_ctx.console.stdout


def test_update_warns_when_pipx_tracks_a_git_url(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr(self_update.shutil, "which", lambda _name: PIPX)
    monkeypatch.setattr(self_update, "version_info", lambda _runner: _info())
    app_ctx.runner = _runner("git+https://github.com/RedHatOfficial/aap-demo.git@v2")

    assert self_update.run(app_ctx) == 0

    assert "tracks git+https://" in app_ctx.console.stderr
    assert "pipx install --force aap-demo" in app_ctx.console.stderr
    assert app_ctx.runner.called([PIPX, "upgrade", "aap-demo"])


def test_update_warns_for_a_relative_path_install(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr(self_update.shutil, "which", lambda _name: PIPX)
    monkeypatch.setattr(self_update, "version_info", lambda _runner: _info())
    app_ctx.runner = _runner("path/to/aap-demo")

    assert self_update.run(app_ctx) == 0

    assert "tracks path/to/aap-demo" in app_ctx.console.stderr
    assert "pipx install --force aap-demo" in app_ctx.console.stderr


def test_update_warns_when_pipx_omits_package_or_url(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr(self_update.shutil, "which", lambda _name: PIPX)
    monkeypatch.setattr(self_update, "version_info", lambda _runner: _info())
    payload = {"venvs": {"aap-demo": {"metadata": {"main_package": {"package": "aap-demo"}}}}}
    runner = FakeRunner()
    runner.ok([PIPX, "list", "--json"], stdout=json.dumps(payload))
    runner.ok([PIPX, "upgrade", "aap-demo"])
    app_ctx.runner = runner

    assert self_update.run(app_ctx) == 0

    assert "did not report package_or_url" in app_ctx.console.stderr
    assert "treated as the published release" in app_ctx.console.stderr
    assert runner.called([PIPX, "upgrade", "aap-demo"])


def test_update_says_when_this_command_is_a_checkout(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr(self_update.shutil, "which", lambda _name: PIPX)
    monkeypatch.setattr(self_update, "version_info", lambda _runner: _info("checkout"))
    app_ctx.runner = _runner()

    assert self_update.run(app_ctx) == 0

    assert "source checkout" in app_ctx.console.stderr


def test_update_requires_pipx(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr(self_update.shutil, "which", lambda _name: None)
    monkeypatch.setattr(self_update, "version_info", lambda _runner: _info())

    with pytest.raises(PrerequisiteError, match="pipx is not on PATH"):
        self_update.run(app_ctx)


def test_update_requires_a_pipx_install(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr(self_update.shutil, "which", lambda _name: PIPX)
    monkeypatch.setattr(self_update, "version_info", lambda _runner: _info())
    app_ctx.runner = FakeRunner().ok([PIPX, "list", "--json"], stdout='{"venvs": {}}')

    with pytest.raises(AapDemoError, match="not installed with pipx"):
        self_update.run(app_ctx)


def test_update_reports_a_pipx_list_timeout(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr(self_update.shutil, "which", lambda _name: PIPX)
    monkeypatch.setattr(self_update, "version_info", lambda _runner: _info())
    runner = FakeRunner()
    runner.register(
        [PIPX, "list", "--json"],
        AapDemoError("command timed out after 60s: /usr/bin/pipx list --json"),
    )
    app_ctx.runner = runner

    with pytest.raises(AapDemoError, match="pipx list timed out after 60s"):
        self_update.run(app_ctx)


def test_update_reports_a_pipx_upgrade_timeout(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr(self_update.shutil, "which", lambda _name: PIPX)
    monkeypatch.setattr(self_update, "version_info", lambda _runner: _info())
    runner = FakeRunner()
    runner.ok([PIPX, "list", "--json"], stdout=_listing())
    runner.register(
        [PIPX, "upgrade", "aap-demo"],
        subprocess.TimeoutExpired(cmd=[PIPX, "upgrade", "aap-demo"], timeout=600),
    )
    app_ctx.runner = runner

    with pytest.raises(AapDemoError, match="pipx upgrade timed out after 600s"):
        self_update.run(app_ctx)


def _upgrade_says(app_ctx, monkeypatch, text: str, *, stream: str = "stdout") -> None:
    monkeypatch.setattr(self_update.shutil, "which", lambda _name: PIPX)
    monkeypatch.setattr(self_update, "version_info", lambda _runner: _info())
    runner = FakeRunner()
    runner.ok([PIPX, "list", "--json"], stdout=_listing())
    runner.register(
        [PIPX, "upgrade", "aap-demo"],
        CompletedCommand(argv=(PIPX, "upgrade", "aap-demo"), returncode=0, **{stream: text}),
    )
    app_ctx.runner = runner


def test_update_names_both_versions_even_when_pipx_wraps_the_line(app_ctx, monkeypatch) -> None:
    _upgrade_says(
        app_ctx,
        monkeypatch,
        "upgrading aap-demo...\n"
        "upgraded package aap-demo from 2.0.0.dev1 to 2.0.0.dev2 (location:\n"
        "/Users/someone/.local/pipx/venvs/aap-demo)\n",
    )

    assert self_update.run(app_ctx) == 0

    assert "Updated 2.0.0.dev1 to 2.0.0.dev2" in app_ctx.console.stdout
    assert "location" not in app_ctx.console.stdout


def test_update_says_when_it_is_already_the_latest(app_ctx, monkeypatch) -> None:
    _upgrade_says(
        app_ctx,
        monkeypatch,
        "aap-demo is already at latest version 2.0.0.dev2 (location: /x)\n",
        stream="stderr",
    )

    assert self_update.run(app_ctx) == 0

    assert "Already up to date: 2.0.0.dev2" in app_ctx.console.stdout


def test_update_reports_a_failed_upgrade_with_pipx_output(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr(self_update.shutil, "which", lambda _name: PIPX)
    monkeypatch.setattr(self_update, "version_info", lambda _runner: _info())
    runner = FakeRunner()
    runner.ok([PIPX, "list", "--json"], stdout=_listing())
    runner.fail([PIPX, "upgrade", "aap-demo"], returncode=1, stderr="No space left on device")
    app_ctx.runner = runner

    with pytest.raises(AapDemoError, match="pipx upgrade exited 1") as caught:
        self_update.run(app_ctx)

    assert "No space left on device" in (caught.value.hint or "")


def _versioned(version: str, spec: str = "aap-demo") -> str:
    return json.dumps(
        {
            "venvs": {
                "aap-demo": {
                    "metadata": {
                        "main_package": {
                            "package": "aap-demo",
                            "package_or_url": spec,
                            "package_version": version,
                        }
                    }
                }
            }
        }
    )


def _pipx_versions(app_ctx, monkeypatch, before: str, after: str, spec: str = "aap-demo") -> None:
    monkeypatch.setattr(self_update.shutil, "which", lambda _name: PIPX)
    monkeypatch.setattr(self_update, "version_info", lambda _runner: _info())
    listings = iter([_versioned(before, spec), _versioned(after, spec)])
    runner = FakeRunner()
    runner.register(
        [PIPX, "list", "--json"],
        lambda argv: CompletedCommand(argv=tuple(argv), returncode=0, stdout=next(listings)),
    )
    runner.ok([PIPX, "upgrade", "aap-demo"], stdout="pipx says something new\n")
    app_ctx.runner = runner


def test_update_compares_the_versions_pipx_reports(app_ctx, monkeypatch) -> None:
    _pipx_versions(app_ctx, monkeypatch, "2.0.0.dev2", "2.0.0.dev3")

    assert self_update.run(app_ctx) == 0

    assert "Installed 2.0.0.dev2" in app_ctx.console.stdout
    assert "Updated 2.0.0.dev2 to 2.0.0.dev3" in app_ctx.console.stdout


def test_update_says_when_nothing_changed(app_ctx, monkeypatch) -> None:
    _pipx_versions(app_ctx, monkeypatch, "2.0.0.dev2", "2.0.0.dev2")

    assert self_update.run(app_ctx) == 0

    assert "Already up to date: 2.0.0.dev2" in app_ctx.console.stdout


def test_update_of_a_branch_install_says_it_was_reinstalled(app_ctx, monkeypatch) -> None:
    spec = "git+https://github.com/RedHatOfficial/aap-demo.git@feat/x"
    _pipx_versions(app_ctx, monkeypatch, "2.0.0.dev2", "2.0.0.dev2", spec)

    assert self_update.run(app_ctx) == 0

    assert f"Reinstalled 2.0.0.dev2 from {spec}" in app_ctx.console.stdout
    assert "To switch back: pipx install --force aap-demo" in app_ctx.console.stderr
