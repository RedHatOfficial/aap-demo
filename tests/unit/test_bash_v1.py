"""Bash v1 launcher detection, rename, and uninstall."""

from __future__ import annotations

from pathlib import Path

from aap_demo.core import bash_v1


def _bash_script(path: Path) -> None:
    path.write_text("#!/usr/bin/env bash\n# aap-demo v1\n", encoding="utf-8")


def test_symlink_to_aap_demo_sh_is_v1(tmp_path: Path) -> None:
    script = tmp_path / "repo" / "aap-demo.sh"
    script.parent.mkdir()
    script.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    launcher = tmp_path / "bin" / "aap-demo"
    launcher.parent.mkdir()
    launcher.symlink_to(script)

    found = bash_v1.bash_launchers({"PATH": str(launcher.parent)})

    assert found == [launcher]


def test_python_entry_point_is_not_v1(tmp_path: Path) -> None:
    launcher = tmp_path / "bin" / "aap-demo"
    launcher.parent.mkdir()
    launcher.write_text("#!/usr/bin/env python3\nimport aap_demo\n", encoding="utf-8")

    assert bash_v1.bash_launchers({"PATH": str(launcher.parent)}) == []


def test_the_command_now_running_is_skipped(tmp_path: Path) -> None:
    script = tmp_path / "aap-demo.sh"
    _bash_script(script)
    launcher = tmp_path / "bin" / "aap-demo"
    launcher.parent.mkdir()
    launcher.symlink_to(script)

    assert bash_v1.bash_launchers({"PATH": str(launcher.parent)}, our=launcher) == []


def test_rename_keeps_the_symlink_target(tmp_path: Path) -> None:
    script = tmp_path / "aap-demo.sh"
    _bash_script(script)
    launcher = tmp_path / "bin" / "aap-demo"
    launcher.parent.mkdir()
    launcher.symlink_to(script)

    destination = bash_v1.rename_launcher(launcher)

    assert destination.name == "aap-demo-v1"
    assert destination.resolve() == script.resolve()
    assert not launcher.exists()


def test_uninstall_removes_the_launcher_and_completions(tmp_path: Path) -> None:
    launcher = tmp_path / ".local" / "bin" / "aap-demo"
    launcher.parent.mkdir(parents=True)
    _bash_script(launcher)
    zsh = tmp_path / ".zsh" / "completions" / "_aap-demo"
    bash = tmp_path / ".local" / "share" / "bash-completion" / "completions" / "aap-demo"
    zsh.parent.mkdir(parents=True)
    bash.parent.mkdir(parents=True)
    zsh.write_text("compdef\n", encoding="utf-8")
    bash.write_text("complete\n", encoding="utf-8")

    removed = bash_v1.uninstall_launcher(launcher, tmp_path)

    assert launcher not in removed or not launcher.exists()
    assert not launcher.exists()
    assert not zsh.exists()
    assert not bash.exists()
    assert (tmp_path / ".local" / "state").exists() is False


def test_offer_rename_and_keep(tmp_path: Path) -> None:
    bindir = tmp_path / "bin"
    bindir.mkdir()
    first = bindir / "aap-demo"
    _bash_script(first)
    answers = iter(["r"])
    output = []

    class Stream:
        def write(self, text: str) -> None:
            output.append(text)

        def flush(self) -> None:
            return None

    log = bash_v1.offer_cleanup(
        [first],
        tmp_path,
        input_func=lambda _prompt: next(answers),
        output=Stream(),
    )

    assert (bindir / "aap-demo-v1").is_file()
    assert not first.exists()
    assert log == [f"renamed {bindir / 'aap-demo-v1'}"]
    assert any("aap-demo-v1" in line for line in output)


def test_keep_is_remembered_and_not_asked_again(tmp_path: Path, monkeypatch) -> None:
    launcher = tmp_path / "bin" / "aap-demo"
    launcher.parent.mkdir()
    _bash_script(launcher)
    monkeypatch.setattr(bash_v1.sys.stdin, "isatty", lambda: True)
    monkeypatch.setattr(bash_v1.sys.stdout, "isatty", lambda: True)
    calls = {"n": 0}
    real = bash_v1.offer_cleanup

    def counting(*args, **kwargs):
        calls["n"] += 1
        return real(*args, **kwargs)

    monkeypatch.setattr(bash_v1, "offer_cleanup", counting)
    env = {"PATH": str(launcher.parent), "HOME": str(tmp_path)}
    bash_v1.maybe_offer(env, input_func=lambda _prompt: "k")
    bash_v1.maybe_offer(env, input_func=lambda _prompt: "k")

    assert calls["n"] == 1
    assert bash_v1.keep_marker(env).is_file()
    assert launcher.is_file()


def test_help_and_quiet_do_not_offer_to_remove_bash_v1(tmp_path: Path, monkeypatch) -> None:
    from aap_demo.cli.main import run

    called = []
    monkeypatch.setattr(
        "aap_demo.cli.main.bash_v1.maybe_offer", lambda *args, **kwargs: called.append(1)
    )
    env = {"HOME": str(tmp_path), "AAP_DEMO_DIR": str(tmp_path)}
    assert run(["help"], env=env) == 0
    assert run(["--quiet", "version"], env=env) == 0
    assert called == []


def test_maybe_offer_skips_a_non_tty(tmp_path: Path, monkeypatch) -> None:
    launcher = tmp_path / "bin" / "aap-demo"
    launcher.parent.mkdir()
    _bash_script(launcher)
    monkeypatch.setattr(bash_v1.sys.stdin, "isatty", lambda: False)
    called = []
    monkeypatch.setattr(bash_v1, "offer_cleanup", lambda *args, **kwargs: called.append(args))

    bash_v1.maybe_offer({"PATH": str(launcher.parent), "HOME": str(tmp_path)})

    assert called == []
