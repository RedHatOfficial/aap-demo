"""``exec/ssh.py``: key detection, remote exec, and the R10 process-replacement
bypass (design §2.2, §14 R10).
"""

from __future__ import annotations

import shlex
from pathlib import Path
from typing import Any, List, Tuple

from aap_demo.exec import ssh as ssh_mod
from aap_demo.exec.runner import FakeRunner


def test_crc_machines_dir_is_derived_from_home() -> None:
    assert ssh_mod.crc_machines_dir({"HOME": "/home/demo"}) == Path("/home/demo/.crc/machines/crc")


def test_detect_ssh_key_prefers_ed25519(tmp_path: Path) -> None:
    (tmp_path / "id_ed25519").write_text("key")
    (tmp_path / "id_ecdsa").write_text("key")
    assert ssh_mod.detect_ssh_key(tmp_path) == tmp_path / "id_ed25519"


def test_detect_ssh_key_falls_back_to_ecdsa(tmp_path: Path) -> None:
    (tmp_path / "id_ecdsa").write_text("key")
    assert ssh_mod.detect_ssh_key(tmp_path) == tmp_path / "id_ecdsa"


def test_detect_ssh_key_returns_none_when_neither_exists(tmp_path: Path) -> None:
    assert ssh_mod.detect_ssh_key(tmp_path) is None


def test_ssh_options_matches_bash_crc_ssh_opts(tmp_path: Path) -> None:
    key = tmp_path / "id_ed25519"
    options = ssh_mod.ssh_options(key)
    assert options == [
        "-i",
        str(key),
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "LogLevel=ERROR",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "BatchMode=yes",
    ]


def test_interactive_ssh_options_are_not_the_non_interactive_set(tmp_path: Path) -> None:
    """Bash's ``cmd_ssh`` passes exactly these — no BatchMode (which would kill
    passphrase prompting), no LogLevel=ERROR (which would hide the connection
    diagnostics), no ConnectTimeout, no IdentitiesOnly."""
    key = tmp_path / "id_ed25519"
    assert ssh_mod.interactive_ssh_options(key) == [
        "-i",
        str(key),
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
    ]


def test_ssh_options_connect_timeout_is_overridable(tmp_path: Path) -> None:
    assert "ConnectTimeout=2" in ssh_mod.ssh_options(tmp_path / "id_ed25519", connect_timeout=2)


def test_remote_argv_defaults_to_sudo(tmp_path: Path) -> None:
    key = tmp_path / "id_ed25519"
    argv = ssh_mod.remote_argv(key, "cat", "/etc/hostname")
    assert argv[0] == "ssh"
    assert argv[1:3] == ["-p", "2222"]
    # One argv element: ssh joins everything after the host itself, so the
    # remote command has to arrive already quoted.
    assert argv[-1] == "sudo cat /etc/hostname"


def test_remote_argv_quotes_a_script_so_the_remote_shell_cannot_split_it(
    tmp_path: Path,
) -> None:
    """The phase-3 live-deploy bug: an unquoted ``python3 -c`` died on ``(``."""
    key = tmp_path / "id_ed25519"
    script = 'import json\nprint("hi")'
    argv = ssh_mod.remote_argv(key, "python3", "-c", script)
    assert argv[-1] == "sudo python3 -c " + shlex.quote(script)
    assert shlex.split(argv[-1]) == ["sudo", "python3", "-c", script]


def test_remote_argv_without_sudo(tmp_path: Path) -> None:
    key = tmp_path / "id_ed25519"
    argv = ssh_mod.remote_argv(key, "true", sudo=False)
    assert argv[-1] == "true"
    assert "sudo" not in argv


def test_exec_remote_goes_through_the_runner(fake_runner: FakeRunner, tmp_path: Path) -> None:
    key = tmp_path / "id_ed25519"
    fake_runner.ok("ssh -p 2222", stdout="hello\n")
    result = ssh_mod.exec_remote(fake_runner, key, "echo", "hello")
    assert result.ok
    assert result.stdout == "hello\n"
    assert fake_runner.called("ssh -p 2222")


# -- interactive_shell: the R10 process-replacement bypass -------------------


def test_interactive_shell_execs_on_posix(tmp_path: Path) -> None:
    key = tmp_path / "id_ed25519"
    calls: List[Tuple[str, List[str]]] = []

    def fake_execvp(program: str, argv: List[str]) -> None:
        calls.append((program, argv))

    ssh_mod.interactive_shell(key, exec_func=fake_execvp, is_windows=False)

    assert len(calls) == 1
    program, argv = calls[0]
    assert program == "ssh"
    # Byte-for-byte bash's ``exec ssh -p 2222 -i KEY -o StrictHostKeyChecking=no
    # -o UserKnownHostsFile=/dev/null core@127.0.0.1`` (aap-demo.sh:1603) —
    # notably *not* CRC_SSH_OPTS, whose BatchMode=yes would make a
    # passphrase-protected key unusable in an interactive session.
    assert argv == [
        "ssh",
        "-p",
        "2222",
        "-i",
        str(key),
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "core@127.0.0.1",
    ]
    assert "BatchMode=yes" not in argv
    assert "LogLevel=ERROR" not in argv


def test_interactive_shell_runs_inherited_stdio_child_on_windows(tmp_path: Path) -> None:
    key = tmp_path / "id_ed25519"
    run_calls: List[List[str]] = []
    exit_calls: List[int] = []

    class _Completed:
        returncode = 7

    def fake_run(argv: List[str]) -> Any:
        run_calls.append(argv)
        return _Completed()

    def fake_exit(code: int) -> None:
        exit_calls.append(code)

    ssh_mod.interactive_shell(key, run_func=fake_run, exit_func=fake_exit, is_windows=True)

    assert len(run_calls) == 1
    assert run_calls[0][0] == "ssh"
    assert exit_calls == [7]


def test_interactive_shell_never_calls_execvp_on_windows(tmp_path: Path) -> None:
    key = tmp_path / "id_ed25519"

    def fail_execvp(*_args: Any) -> None:
        raise AssertionError("execvp must not be used on Windows")

    class _Completed:
        returncode = 0

    ssh_mod.interactive_shell(
        key,
        exec_func=fail_execvp,
        run_func=lambda argv: _Completed(),
        exit_func=lambda code: None,
        is_windows=True,
    )
