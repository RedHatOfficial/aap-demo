"""A bad configuration must name the problem and leave the way to repair it."""

from __future__ import annotations

from pathlib import Path
from typing import Dict, Sequence

import pytest
import yaml

from aap_demo.cli.main import main, run
from aap_demo.core import config as config_mod
from aap_demo.core.errors import ConfigError
from aap_demo.exec.runner import CompletedCommand, FakeRunner

BAD_FILES = {
    "syntax": "crc: [\n",
    "top-level list": "- a list\n",
    "bad value": "crc:\n  cpus: lots\n",
}


@pytest.fixture(params=sorted(BAD_FILES))
def bad_config(request: pytest.FixtureRequest, tmp_path: Path) -> Path:
    path = tmp_path / "config.yaml"
    path.write_text(BAD_FILES[request.param], encoding="utf-8")
    return path


def _env(tmp_path: Path, **extra: str) -> Dict[str, str]:
    return {"AAP_DEMO_DIR": str(tmp_path), "AAP_DEMO_SKIP_MIGRATION": "1", **extra}


def _run(argv: Sequence[str], path: Path, runner: FakeRunner, **extra: str) -> int:
    return run(["--config", str(path), *argv], env=_env(path.parent, **extra), runner=runner)


@pytest.mark.parametrize("flag", ["--help", "--version"])
def test_help_and_version_flags_still_work(bad_config: Path, flag: str) -> None:
    with pytest.raises(SystemExit) as excinfo:
        _run([flag], bad_config, FakeRunner())
    assert excinfo.value.code == 0


def test_config_path_prints_the_file_and_reports_the_problem(
    bad_config: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert _run(["config", "path"], bad_config, FakeRunner()) == 0
    captured = capsys.readouterr()
    assert captured.out.strip() == str(bad_config)
    assert str(bad_config) in captured.err


def test_config_edit_opens_the_bad_file_without_rewriting_it(bad_config: Path) -> None:
    before = bad_config.read_text(encoding="utf-8")
    runner = FakeRunner()
    runner.register(["vi"], CompletedCommand(("vi",), 0))
    assert _run(["config", "edit"], bad_config, runner, EDITOR="vi") == 0
    assert runner.calls[-1].argv == ("vi", str(bad_config))
    assert bad_config.read_text(encoding="utf-8") == before


@pytest.mark.parametrize("argv", [["status"], ["deploy"], ["config", "set", "crc.cpus", "8"]])
def test_other_commands_are_refused_before_running_anything(
    bad_config: Path, argv: Sequence[str]
) -> None:
    runner = FakeRunner()
    before = bad_config.read_text(encoding="utf-8")
    with pytest.raises(ConfigError) as excinfo:
        _run(argv, bad_config, runner)
    assert "aap-demo config edit" in str(excinfo.value.hint)
    assert not runner.calls
    assert bad_config.read_text(encoding="utf-8") == before


def test_yaml_error_names_the_file_and_position(tmp_path: Path) -> None:
    path = tmp_path / "config.yaml"
    path.write_text(BAD_FILES["syntax"], encoding="utf-8")
    with pytest.raises(ConfigError) as excinfo:
        config_mod.read_yaml(path)
    message = excinfo.value.message
    assert str(path) in message
    assert "invalid YAML" in message
    assert "line 2" in message
    assert "\n" not in message


def test_undecodable_file_is_a_config_error(tmp_path: Path) -> None:
    path = tmp_path / "config.yaml"
    path.write_bytes(b"\xff\xfe\x00")
    with pytest.raises(ConfigError, match="not UTF-8"):
        config_mod.read_yaml(path)


def test_main_exits_two_without_a_traceback(
    bad_config: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv("AAP_DEMO_DIR", str(bad_config.parent))
    monkeypatch.setenv("AAP_DEMO_SKIP_MIGRATION", "1")
    assert main(["--config", str(bad_config), "status"], runner=FakeRunner()) == 2
    captured = capsys.readouterr()
    assert "Traceback" not in captured.err
    assert "aap-demo config edit" in captured.err


def test_a_bad_environment_value_does_not_block_help(tmp_path: Path) -> None:
    with pytest.raises(SystemExit) as excinfo:
        run(["--help"], env=_env(tmp_path, CRC_CPUS="lots"), runner=FakeRunner())
    assert excinfo.value.code == 0


def test_a_good_config_still_applies(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    path = tmp_path / "config.yaml"
    path.write_text("crc:\n  cpus: 9\n", encoding="utf-8")
    assert _run(["config", "get", "crc.cpus"], path, FakeRunner()) == 0
    assert capsys.readouterr().out.strip() == "9"


def test_config_set_writes_the_selected_file(tmp_path: Path) -> None:
    selected = tmp_path / "selected.yaml"
    selected.write_text("crc:\n  cpus: 9\n")
    assert _run(["config", "set", "crc.memory_mb", "26624"], selected, FakeRunner()) == 0
    saved = yaml.safe_load(selected.read_text())
    assert saved["crc"]["memory_mb"] == 26624
    assert saved["crc"]["cpus"] == 9
    assert not (tmp_path / "aap-demo" / "config.yaml").exists()
