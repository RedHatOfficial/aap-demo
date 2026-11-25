"""Windows Python installer behavior."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest.mock import patch

import pytest


def test_python_setup_module_is_available() -> None:
    assert importlib.util.find_spec("aap_demo.setup") is not None


def _manager(
    tmp_path: Path,
    *,
    run=None,
    which=None,
    user_path: str = "C:\\Existing",
    set_user_path=None,
    pipx_scripts_dir: Path | None = None,
) -> Any:
    setup = pytest.importorskip("aap_demo.setup")
    home = tmp_path / "home"
    repo = tmp_path / "repo"
    home.mkdir()
    repo.mkdir()
    (repo / "aap-demo.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    with patch.dict(os.environ, {"PIPX_BIN_DIR": str(home / ".local" / "bin")}):
        return setup.SetupManager(
            repo_root=repo,
            home=home,
            python="python.exe",
            run=run,
            which=which,
            get_user_path=lambda: user_path,
            set_user_path=set_user_path or (lambda _value: None),
            pipx_scripts_dir=pipx_scripts_dir,
        )


def test_install_uses_pipx_for_aap_demo_and_registers_v1(tmp_path: Path) -> None:
    calls = []
    path_values = []

    def run(argv, **_kwargs):
        calls.append(list(argv))
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    def which(name):
        return {"crc": "C:/crc.exe", "oc": "C:/oc.exe"}.get(name)

    manager = _manager(tmp_path, run=run, which=which, set_user_path=path_values.append)

    manager.install()

    assert calls == [
        ["python.exe", "-m", "pip", "install", "--user", "pipx", "--disable-pip-version-check"],
        ["python.exe", "-m", "pipx", "environment", "--value", "PIPX_BIN_DIR"],
        ["python.exe", "-m", "pipx", "list", "--json"],
        [
            "python.exe",
            "-m",
            "pipx",
            "install",
            "--python",
            "python.exe",
            "aap-demo",
        ],
    ]
    assert (manager.bin_dir / "aap-demo-v1.cmd").is_file()
    assert (manager.config_dir / "repo-path").read_text(encoding="utf-8") == str(manager.repo_root)
    assert (manager.config_dir / "local-bin-path-added").exists()
    expected_paths = [str(manager.bin_dir)]
    if manager.pipx_scripts_dir is not None:
        expected_paths.append(str(manager.pipx_scripts_dir.resolve()))
    assert path_values == [";".join(["C:\\Existing", *expected_paths])]


def test_install_stops_before_pipx_when_crc_is_missing(tmp_path: Path) -> None:
    setup = pytest.importorskip("aap_demo.setup")
    calls = []

    def run(argv, **_kwargs):
        calls.append(list(argv))
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    manager = _manager(
        tmp_path,
        run=run,
        which=lambda name: "C:/oc.exe" if name == "oc" else None,
    )

    with pytest.raises(setup.SetupError, match="crc"):
        manager.install()

    assert calls == []


def test_install_upgrades_existing_python_package_through_pipx(tmp_path: Path) -> None:
    calls = []

    def run(argv, **_kwargs):
        calls.append(list(argv))
        output = ""
        if argv[-2:] == ["list", "--json"]:
            output = '{"venvs":{"aap-demo":{"metadata":{"main_package":{"package":"aap-demo"}}}}}'
        return SimpleNamespace(returncode=0, stdout=output, stderr="")

    manager = _manager(
        tmp_path,
        run=run,
        which=lambda name: {
            "crc": "C:/crc.exe",
            "oc": "C:/oc.exe",
            "pipx": "C:/pipx.exe",
        }.get(name),
    )
    manager.bin_dir.mkdir(parents=True)
    (manager.bin_dir / "aap-demo.exe").write_text("pipx shim", encoding="utf-8")

    manager.install()

    assert calls == [
        ["C:/pipx.exe", "environment", "--value", "PIPX_BIN_DIR"],
        ["C:/pipx.exe", "list", "--json"],
        ["C:/pipx.exe", "upgrade", "aap-demo"],
    ]


def test_suffixed_pipx_environment_is_not_the_managed_cli(tmp_path: Path) -> None:
    def run(argv, **_kwargs):
        output = (
            '{"venvs":{"aap-demo-dev":{"metadata":{"main_package":{"package":"aap-demo"}}}}}'
            if argv[-2:] == ["list", "--json"]
            else ""
        )
        return SimpleNamespace(returncode=0, stdout=output, stderr="")

    manager = _manager(
        tmp_path, run=run, which=lambda name: "C:/pipx.exe" if name == "pipx" else None
    )

    assert manager._pipx_has_aap_demo() is False


def test_install_refreshes_path_after_winget_installs_oc(tmp_path: Path) -> None:
    calls = []
    state = {"oc_available": False, "refreshed": False}

    def run(argv, **_kwargs):
        calls.append(list(argv))
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    def which(name):
        if name == "crc":
            return "C:/crc.exe"
        if name == "winget":
            return "C:/winget.exe"
        if name == "oc" and state["oc_available"]:
            return "C:/oc.exe"
        return None

    manager = _manager(tmp_path, run=run, which=which)

    def refresh_path():
        state["refreshed"] = True
        state["oc_available"] = True

    manager._refresh_path = refresh_path
    manager.install()

    assert state["refreshed"]
    assert calls[0][0:2] == ["C:/winget.exe", "install"]
    assert calls[-1] == [
        "python.exe",
        "-m",
        "pipx",
        "install",
        "--python",
        "python.exe",
        "aap-demo",
    ]


def test_uninstall_preserves_pull_secret_and_removes_only_owned_path(tmp_path: Path) -> None:
    calls = []
    bin_entry = str(tmp_path / "home" / ".local" / "bin")
    user_paths = ["C:\\Existing", bin_entry]

    def run(argv, **_kwargs):
        calls.append(list(argv))
        output = ""
        if argv[-2:] == ["list", "--json"]:
            output = '{"venvs":{"aap-demo":{"metadata":{"main_package":{"package":"aap-demo"}}}}}'
        if argv[-2:] == ["uninstall", "aap-demo"]:
            (manager.bin_dir / "aap-demo.exe").unlink()
        return SimpleNamespace(returncode=0, stdout=output, stderr="")

    manager = _manager(
        tmp_path,
        run=run,
        which=lambda name: "C:/pipx.exe" if name == "pipx" else None,
        user_path=";".join(user_paths),
        set_user_path=lambda value: user_paths.__setitem__(slice(None), value.split(";")),
    )
    manager.bin_dir.mkdir(parents=True)
    manager.config_dir.mkdir(parents=True)
    pull_secret = manager.config_dir / "pull-secret.txt"
    pull_secret.write_text("preserve", encoding="utf-8")
    (manager.config_dir / "local-bin-path-added").write_text("added", encoding="ascii")
    for name in ("aap-demo.exe", "aap-demo-v1.cmd", "aap-demo.ps1", "aap-demo.cmd"):
        (manager.bin_dir / name).write_text("launcher", encoding="utf-8")

    manager.uninstall()

    assert calls == [
        ["C:/pipx.exe", "environment", "--value", "PIPX_BIN_DIR"],
        ["C:/pipx.exe", "list", "--json"],
        ["C:/pipx.exe", "uninstall", "aap-demo"],
    ]
    assert user_paths == ["C:\\Existing"]
    assert pull_secret.read_text(encoding="utf-8") == "preserve"
    assert not (manager.bin_dir / "aap-demo-v1.cmd").exists()
    assert not (manager.config_dir / "local-bin-path-added").exists()


def test_uninstall_is_idempotent_when_pipx_has_no_app(tmp_path: Path) -> None:
    calls = []

    def run(argv, **_kwargs):
        calls.append(list(argv))
        output = '{"venvs":{}}' if argv[-2:] == ["list", "--json"] else ""
        return SimpleNamespace(returncode=0, stdout=output, stderr="")

    manager = _manager(
        tmp_path,
        run=run,
        which=lambda name: "C:/pipx.exe" if name == "pipx" else None,
    )

    manager._uninstall_python_cli()

    assert calls == [
        ["C:/pipx.exe", "environment", "--value", "PIPX_BIN_DIR"],
        ["C:/pipx.exe", "list", "--json"],
    ]


def test_uninstall_removes_the_path_entry_owned_by_the_previous_pipx_location(
    tmp_path: Path,
) -> None:
    old_bin = tmp_path / "old-pipx-bin"
    current_bin = tmp_path / "new-pipx-bin"
    user_paths = [str(old_bin), str(current_bin), "C:\\Existing"]
    manager = _manager(
        tmp_path,
        user_path=";".join(user_paths),
        set_user_path=lambda value: user_paths.__setitem__(slice(None), value.split(";")),
    )
    manager.bin_dir = current_bin
    manager.config_dir.mkdir(parents=True)
    manager.path_entry_marker.write_text(str(old_bin), encoding="utf-8")

    manager._remove_launcher_path()

    assert user_paths == [str(current_bin), "C:\\Existing"]


def test_rollback_installs_v1_default_before_uninstalling_python(tmp_path: Path) -> None:
    calls = []

    def run(argv, **_kwargs):
        calls.append(list(argv))
        output = ""
        if argv[-2:] == ["list", "--json"]:
            output = '{"venvs":{"aap-demo":{"metadata":{"main_package":{"package":"aap-demo"}}}}}'
        if argv[-2:] == ["uninstall", "aap-demo"]:
            default = (manager.bin_dir / "aap-demo.cmd").read_text(encoding="ascii")
            assert 'call "%~dp0aap-demo-v1.cmd" %*' in default
            (manager.bin_dir / "aap-demo.exe").unlink()
        return SimpleNamespace(returncode=0, stdout=output, stderr="")

    manager = _manager(
        tmp_path,
        run=run,
        which=lambda name: "C:/pipx.exe" if name == "pipx" else None,
        set_user_path=lambda _value: None,
    )
    manager.bin_dir.mkdir(parents=True)
    manager.config_dir.mkdir(parents=True)
    (manager.config_dir / "repo-path").write_text(str(manager.repo_root), encoding="utf-8")
    (manager.bin_dir / "aap-demo.exe").write_text("pipx shim", encoding="utf-8")

    manager.rollback_to_v1()

    assert calls == [
        ["C:/pipx.exe", "environment", "--value", "PIPX_BIN_DIR"],
        ["C:/pipx.exe", "list", "--json"],
        ["C:/pipx.exe", "uninstall", "aap-demo"],
    ]
    assert (manager.bin_dir / "aap-demo-v1.cmd").is_file()
    assert (manager.bin_dir / "aap-demo.cmd").is_file()
    assert not (manager.bin_dir / "aap-demo.exe").exists()


def test_install_uses_pipx_reported_bin_directory(tmp_path: Path) -> None:
    custom_bin = tmp_path / "custom pipx bin"
    calls = []

    def run(argv, **_kwargs):
        calls.append(list(argv))
        output = str(custom_bin) if argv[-3:] == ["environment", "--value", "PIPX_BIN_DIR"] else ""
        return SimpleNamespace(returncode=0, stdout=output, stderr="")

    manager = _manager(
        tmp_path,
        run=run,
        which=lambda name: {"crc": "C:/crc.exe", "oc": "C:/oc.exe", "pipx": "C:/pipx.exe"}.get(
            name
        ),
    )

    manager.install()

    assert manager.bin_dir == custom_bin.resolve()
    assert (custom_bin / "aap-demo-v1.cmd").is_file()
    assert (manager.home / ".aap-demo" / "repo-path").is_file()


def test_custom_pipx_bin_install_removes_old_default_wrappers(tmp_path: Path) -> None:
    custom_bin = tmp_path / "custom pipx bin"
    home = tmp_path / "home"
    home_bin = home / ".local" / "bin"
    manager = _manager(
        tmp_path,
        run=None,
        which=lambda name: {
            "crc": "C:/crc.exe",
            "oc": "C:/oc.exe",
            "pipx": "C:/pipx.exe",
        }.get(name),
        user_path=f"C:\\Existing;{home_bin}",
    )
    home_bin.mkdir(parents=True)
    old_launcher = home_bin / "aap-demo.cmd"
    old_launcher.write_text("legacy default", encoding="utf-8")
    (home_bin / "aap-demo.ps1").write_text("stale PowerShell shim", encoding="utf-8")

    def run(argv, **_kwargs):
        output = str(custom_bin) if argv[-3:] == ["environment", "--value", "PIPX_BIN_DIR"] else ""
        return SimpleNamespace(returncode=0, stdout=output, stderr="")

    manager.run = run

    manager.install()

    assert not old_launcher.exists()
    assert not (home_bin / "aap-demo.ps1").exists()
    assert (custom_bin / "aap-demo-v1.cmd").is_file()


def test_fresh_pipx_install_adds_python_scripts_path(tmp_path: Path) -> None:
    user_scripts = tmp_path / "Python Scripts"
    user_paths = []
    manager = _manager(
        tmp_path,
        run=lambda _argv, **_kwargs: SimpleNamespace(returncode=0, stdout="", stderr=""),
        which=lambda name: {"crc": "C:/crc.exe", "oc": "C:/oc.exe"}.get(name),
        set_user_path=user_paths.append,
        pipx_scripts_dir=user_scripts,
    )

    manager.install()

    assert user_paths == [f"C:\\Existing;{manager.bin_dir};{user_scripts.resolve()}"]


def test_repo_marker_preserves_non_ascii_checkout_path(tmp_path: Path) -> None:
    manager = _manager(tmp_path)
    manager.repo_root = (tmp_path / "checkout-演示").resolve()

    manager._write_repo_marker()

    assert manager.repo_marker.read_text(encoding="utf-8") == str(manager.repo_root)


def test_v1_shim_uses_git_bash_path_and_skips_system32(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("ProgramFiles", str(tmp_path / "Program Files"))
    monkeypatch.setenv("ProgramFiles(x86)", str(tmp_path / "Program Files (x86)"))
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "Local AppData"))
    manager = _manager(tmp_path)
    git_bash = tmp_path / "Git" / "bin" / "bash.exe"
    git_bash.parent.mkdir(parents=True)
    git_bash.write_text("", encoding="utf-8")
    git_exe = tmp_path / "Git" / "cmd" / "git.exe"
    git_exe.parent.mkdir(parents=True)
    git_exe.write_text("", encoding="utf-8")
    manager.which = lambda name: {
        "git": str(git_exe),
        "bash.exe": r"C:\Windows\System32\bash.exe",
        "bash": None,
    }.get(name)

    assert manager._find_git_bash(windows=True) == str(git_bash.resolve())
    manager._find_git_bash = lambda: str(git_bash.resolve())
    manager._write_v1_shim()
    shim = (manager.bin_dir / "aap-demo-v1.cmd").read_text(encoding="utf-8")
    assert f'set "AAP_DEMO_BASH={git_bash.resolve()}"' in shim
