"""Bash v1 launcher detection, rename, and uninstall."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

from aap_demo.core import bash_v1

REPO_ROOT = Path(__file__).resolve().parents[2]


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


@pytest.mark.skipif(sys.platform == "win32", reason="aap-demo.sh is the Unix launcher")
def test_bash_help_labels_fleet_as_legacy_qemu_and_points_to_v2() -> None:
    result = subprocess.run(
        ["bash", str(REPO_ROOT / "aap-demo.sh"), "help"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )

    assert result.returncode == 0
    assert "(legacy Bash v1; local QEMU VMs only)" in result.stdout
    assert "Kubernetes-native fleet: aap-demo fleet list" in result.stdout
    assert "v2 [args...]" in result.stdout


def test_bash_status_has_a_python_v2_fleet_report() -> None:
    # cmd_status lives in includes/cmd-status.sh (extracted from aap-demo.sh).
    source = (REPO_ROOT / "includes" / "cmd-status.sh").read_text(encoding="utf-8")

    assert "Kubernetes-native Fleet:" in source
    assert "Kubernetes-native Fleet: kubectl failed" in source
    assert "get pods -A" in source
    assert "|| _fleet_v2_rc=$?" in source
    assert "app.kubernetes.io/name=fleet-node" in source
    assert '--kubeconfig "$KUBECTL_KUBECONFIG"' in source
    assert '--context "$KUBECTL_CONTEXT"' in source


def test_bash_fleet_source_has_explicit_backend_delegation() -> None:
    source = (REPO_ROOT / "aap-demo.sh").read_text(encoding="utf-8")
    # show_help lives in includes/help.sh (extracted from aap-demo.sh).
    help_source = (REPO_ROOT / "includes" / "help.sh").read_text(encoding="utf-8")

    assert "--backend qemu|kube-native|all" in help_source
    assert "_fleet_delegate_v2" in source
    assert "_fleet_delegate_kube_native" in source
    assert ".venv/bin/python" in source
    assert "import yaml" in source
    assert '--kubeconfig "$KUBECTL_KUBECONFIG"' in source
    assert '--context "$KUBECTL_CONTEXT"' in source


@pytest.mark.skipif(sys.platform == "win32", reason="aap-demo.sh requires a POSIX Bash environment")
def test_bash_can_dispatch_the_python_v2_cli() -> None:
    env = {"AAP_DEMO_PYTHON": sys.executable, "CI": "true"}
    result = subprocess.run(
        ["bash", str(REPO_ROOT / "aap-demo.sh"), "v2", "--help"],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )

    assert result.returncode == 0
    assert "usage: aap-demo" in result.stdout
    assert "fleet" in result.stdout


@pytest.mark.skipif(sys.platform == "win32", reason="aap-demo.sh requires a POSIX Bash environment")
def test_bash_v2_can_enable_fleet() -> None:
    env = {"AAP_DEMO_PYTHON": sys.executable, "CI": "true"}
    result = subprocess.run(
        ["bash", str(REPO_ROOT / "aap-demo.sh"), "v2", "enable", "fleet", "--help"],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )

    assert result.returncode == 0
    assert "usage: aap-demo enable" in result.stdout


@pytest.mark.skipif(sys.platform == "win32", reason="aap-demo.sh requires a POSIX Bash environment")
def test_bash_enable_fleet_can_select_kube_native_backend() -> None:
    env = {"AAP_DEMO_PYTHON": sys.executable, "CI": "true"}
    result = subprocess.run(
        [
            "bash",
            str(REPO_ROOT / "aap-demo.sh"),
            "enable",
            "fleet",
            "--backend",
            "kube-native",
            "--help",
        ],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )

    assert result.returncode == 0
    assert "usage: aap-demo enable" in result.stdout


def _bash_delegation_env(tmp_path: Path) -> tuple[dict[str, str], Path]:
    """Stub kubectl and the Python CLI so fleet delegation can be observed."""
    bindir = tmp_path / "bin"
    home = tmp_path / "home"
    bindir.mkdir()
    home.mkdir()
    kubectl = bindir / "kubectl"
    kubectl.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    kubectl.chmod(0o755)
    record = tmp_path / "python-args.txt"
    wrapper = tmp_path / "python-wrapper"
    wrapper.write_text(
        "#!/usr/bin/env python3\n"
        "import os\n"
        "import sys\n"
        "from pathlib import Path\n"
        "if len(sys.argv) > 1 and sys.argv[1] == '-c':\n"
        "    raise SystemExit(0)\n"
        "Path(os.environ['AAP_DEMO_RECORD']).write_text('\\n'.join(sys.argv[1:]) + '\\n')\n"
        "raise SystemExit(0)\n",
        encoding="utf-8",
    )
    wrapper.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = f"{bindir}{os.pathsep}{env.get('PATH', '')}"
    env["HOME"] = str(home)
    env["AAP_DEMO_DIR"] = str(home / ".aap-demo")
    env["AAP_DEMO_PYTHON"] = str(wrapper)
    env["AAP_DEMO_RECORD"] = str(record)
    env["CI"] = "true"
    env["QUIET"] = "true"
    return env, record


def _recorded_python_args(record: Path) -> list[str]:
    if not record.exists():
        return []
    return [line for line in record.read_text(encoding="utf-8").splitlines() if line]


@pytest.mark.skipif(sys.platform == "win32", reason="aap-demo.sh requires a POSIX Bash environment")
def test_bash_disable_fleet_kube_native_delegates_to_python(tmp_path: Path) -> None:
    env, record = _bash_delegation_env(tmp_path)
    result = subprocess.run(
        [
            "bash",
            str(REPO_ROOT / "aap-demo.sh"),
            "disable",
            "fleet",
            "--backend",
            "kube-native",
        ],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    assert _recorded_python_args(record) == ["-m", "aap_demo", "disable", "fleet"]
    assert "Removing Fleet addon" not in result.stdout
    assert "Disabling addon: fleet" not in result.stdout


@pytest.mark.skipif(sys.platform == "win32", reason="aap-demo.sh requires a POSIX Bash environment")
def test_bash_enable_fleet_kube_native_forwards_no_import(tmp_path: Path) -> None:
    env, record = _bash_delegation_env(tmp_path)
    result = subprocess.run(
        [
            "bash",
            str(REPO_ROOT / "aap-demo.sh"),
            "enable",
            "fleet",
            "--backend",
            "kube-native",
            "--no-import",
        ],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    assert _recorded_python_args(record) == ["-m", "aap_demo", "enable", "fleet", "--no-import"]
    assert "Unknown argument" not in result.stderr
    assert "Unknown argument" not in result.stdout


@pytest.mark.skipif(sys.platform == "win32", reason="aap-demo.sh requires a POSIX Bash environment")
def test_bash_enable_fleet_accepts_no_import_before_backend(tmp_path: Path) -> None:
    env, record = _bash_delegation_env(tmp_path)
    result = subprocess.run(
        [
            "bash",
            str(REPO_ROOT / "aap-demo.sh"),
            "enable",
            "fleet",
            "--no-import",
            "--backend",
            "kube-native",
        ],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    assert _recorded_python_args(record) == ["-m", "aap_demo", "enable", "fleet", "--no-import"]


def test_bash_fleet_default_backend_stays_qemu() -> None:
    source = (REPO_ROOT / "aap-demo.sh").read_text(encoding="utf-8")

    assert 'FLEET_BACKEND="${FLEET_BACKEND:-qemu}"' in source
    disable = source.split("cmd_disable()", 1)[1].split("_check_for_updates()", 1)[0]
    assert 'case "${FLEET_BACKEND:-qemu}" in' in disable
    assert '_fleet_delegate_v2 disable fleet "$@"' in disable
    qemu = disable.split("qemu)", 1)[1].split("all)", 1)[0]
    assert "_fleet_delegate_v2" not in qemu


def test_maybe_offer_skips_a_non_tty(tmp_path: Path, monkeypatch) -> None:
    launcher = tmp_path / "bin" / "aap-demo"
    launcher.parent.mkdir()
    _bash_script(launcher)
    monkeypatch.setattr(bash_v1.sys.stdin, "isatty", lambda: False)
    called = []
    monkeypatch.setattr(bash_v1, "offer_cleanup", lambda *args, **kwargs: called.append(args))

    bash_v1.maybe_offer({"PATH": str(launcher.parent), "HOME": str(tmp_path)})

    assert called == []


def _bare_checkout(tmp_path: Path) -> Path:
    """aap-demo.sh with its includes but no .venv and no src/, like an installed bash tree."""
    import shutil

    root = tmp_path / "checkout"
    root.mkdir()
    shutil.copy2(REPO_ROOT / "aap-demo.sh", root / "aap-demo.sh")
    shutil.copytree(REPO_ROOT / "includes", root / "includes")
    if (REPO_ROOT / "VERSION").exists():
        shutil.copy2(REPO_ROOT / "VERSION", root / "VERSION")
    return root


def _fake_aap_demo(bindir: Path, shebang: str) -> None:
    launcher = bindir / "aap-demo"
    launcher.write_text(
        f'{shebang}\nprintf "%s\\n" "$@" > "$AAP_DEMO_RECORD"\n',
        encoding="utf-8",
    )
    launcher.chmod(0o755)


@pytest.mark.skipif(sys.platform == "win32", reason="aap-demo.sh requires a POSIX Bash environment")
@pytest.mark.parametrize(
    ("shebang", "used"),
    [("#!/bin/sh", False), ("#!/usr/bin/env python3", True)],
)
def test_bash_fleet_prefers_an_installed_python_aap_demo(
    tmp_path: Path, shebang: str, used: bool
) -> None:
    env, record = _bash_delegation_env(tmp_path)
    del env["AAP_DEMO_PYTHON"]
    bindir = tmp_path / "bin"
    _fake_aap_demo(bindir, shebang)
    # The stand-in body is shell: a python3 shim on PATH runs it with sh, so
    # only the first line decides whether bash treats it as the Python CLI.
    shim = bindir / "python3"
    shim.write_text('#!/bin/sh\nexec /bin/sh "$@"\n', encoding="utf-8")
    shim.chmod(0o755)
    root = _bare_checkout(tmp_path)
    result = subprocess.run(
        ["bash", str(root / "aap-demo.sh"), "disable", "fleet", "--backend", "kube-native"],
        cwd=root,
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )

    if used:
        assert result.returncode == 0, result.stderr
        assert _recorded_python_args(record) == ["disable", "fleet"]
    else:
        assert _recorded_python_args(record) == []
        assert result.returncode != 0


@pytest.mark.skipif(sys.platform == "win32", reason="aap-demo.sh requires a POSIX Bash environment")
def test_bash_fleet_uses_pips_sh_wrapper_entry_point(tmp_path: Path) -> None:
    # pip writes this wrapper when the interpreter path has a space, which is
    # where pipx installs on macOS ("Application Support").
    env, record = _bash_delegation_env(tmp_path)
    del env["AAP_DEMO_PYTHON"]
    venv = tmp_path / "Application Support" / "venv" / "bin"
    venv.mkdir(parents=True)
    python = venv / "python"
    python.write_text(
        '#!/bin/sh\nshift\nprintf "%s\\n" "$@" > "$AAP_DEMO_RECORD"\n',
        encoding="utf-8",
    )
    python.chmod(0o755)
    launcher = tmp_path / "bin" / "aap-demo"
    launcher.write_text(
        "#!/bin/sh\n" + "'''exec' " + f'"{python}" "$0" "$@"\n' + "' '''\n",
        encoding="utf-8",
    )
    launcher.chmod(0o755)
    root = _bare_checkout(tmp_path)
    result = subprocess.run(
        ["bash", str(root / "aap-demo.sh"), "disable", "fleet", "--backend", "kube-native"],
        cwd=root,
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    assert _recorded_python_args(record) == ["disable", "fleet"]


def test_bash_qemu_fleet_warns_that_no_import_is_ignored() -> None:
    source = (REPO_ROOT / "aap-demo.sh").read_text(encoding="utf-8")
    qemu = source.split('_fleet_delegate_v2 enable fleet "$@"', 1)[1].split("all)", 1)[0]
    assert "--no-import is ignored for the qemu backend" in qemu
    assert '"--no-import" ]' in qemu


def test_bash_fleet_delegation_tries_the_installed_cli_before_the_checkout_venv() -> None:
    source = (REPO_ROOT / "aap-demo.sh").read_text(encoding="utf-8")
    body = source.split("_fleet_delegate_v2() {", 1)[1].split("\n}\n", 1)[0]
    assert body.index("_fleet_is_python_entry_point") < body.index(".venv/bin/python")
    assert "grep -qi bash" not in body
