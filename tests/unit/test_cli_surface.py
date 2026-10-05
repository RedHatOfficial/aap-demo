"""CLI surface parity with the bash tool (design §12.4 phase-0 exit criterion).

``BASH_COMMANDS`` is transcribed from ``show_help`` in ``aap-demo.sh`` (the
COMMANDS blocks at lines 424-504). The exit criterion is that ``--help``
matches that content: the same commands, the same grouping, the same trailer.
"""

from __future__ import annotations

import io
from typing import List

import pytest

from aap_demo.cli.main import build_parser, run
from aap_demo.core.console import RecordingConsole

#: Command names from bash ``show_help`` that this CLI owns.
#: ``test`` was removed upstream (#184). ``fleet`` and ``wire`` stay bash-only
#: until the Python addon platform replaces them.
BASH_COMMANDS = [
    # "COMMANDS (all infrastructure types)"
    "deploy",
    "status",
    "clean",
    "watch",
    "redeploy",
    "idle",
    "diagnose",
    "must-gather",
    "enable",
    "disable",
    "redhat-status",
    "config",
    "update",
    "version",
    "help",
    # "COMMANDS"
    "create",
    "destroy",
    "stop",
    "start",
    "ssh",
    "repair",
    "setup",
    "kubeconfig",
    "redeploy-all",
]

#: Aliases the bash dispatch case accepts (aap-demo.sh:2876-2972).
BASH_ALIASES = {"rh-status": "redhat-status", "deploy-all": "deploy"}

#: New in the rewrite (§3.3 "New commands").
NEW_COMMANDS = ["addon", "playbooks", "gui", "completion", "oc"]


@pytest.fixture(scope="module")
def help_text() -> str:
    return build_parser().format_help()


@pytest.fixture(scope="module")
def subcommands() -> List[str]:
    import argparse

    parser = build_parser()
    for action in parser._actions:
        if isinstance(action, argparse._SubParsersAction):
            return list(action.choices)
    raise AssertionError("the root parser has no subparsers")


@pytest.mark.parametrize("command", BASH_COMMANDS)
def test_every_bash_command_exists(command: str, subcommands: List[str]) -> None:
    assert command in subcommands


@pytest.mark.parametrize("command", BASH_COMMANDS)
def test_every_bash_command_is_listed_in_help(command: str, help_text: str) -> None:
    assert command in help_text


@pytest.mark.parametrize("alias,target", sorted(BASH_ALIASES.items()))
def test_aliases_resolve(alias: str, target: str, subcommands: List[str]) -> None:
    assert alias in subcommands


@pytest.mark.parametrize("command", NEW_COMMANDS)
def test_new_commands_exist(command: str, subcommands: List[str]) -> None:
    assert command in subcommands


def test_help_carries_the_bash_trailer_sections(help_text: str) -> None:
    for block in ("ENVIRONMENT:", "EXAMPLES:", "REQUIREMENTS:"):
        assert block in help_text


def test_help_keeps_the_bash_examples(help_text: str) -> None:
    for example in (
        "aap-demo create",
        "aap-demo deploy",
        "aap-demo status",
        "aap-demo stop",
        "aap-demo start",
        "aap-demo ssh",
        "aap-demo oc cluster-info",
    ):
        assert example in help_text


def test_help_keeps_the_bash_requirements(help_text: str) -> None:
    assert "OpenShift Local" in help_text
    assert "libvirt-daemon" in help_text
    assert "kubectl" in help_text
    assert "pull-secret" in help_text
    assert "~/.local/state/aap-demo/pull-secret.txt" in help_text
    assert "used automatically" in help_text


def test_help_title_matches_bash(help_text: str) -> None:
    assert "aap-demo - Deploy AAP 2.7 to OpenShift Local" in help_text


# -- global option parity (§3.2) -------------------------------------------


@pytest.mark.parametrize(
    "argv",
    [
        ["--context=foo", "version"],
        ["--context", "foo", "version"],
        ["--kubeconfig=/tmp/kc", "version"],
        ["--kubeconfig", "/tmp/kc", "version"],
        ["-n", "other", "version"],
        ["--namespace=other", "version"],
    ],
)
def test_both_equals_and_space_forms_parse(argv: List[str]) -> None:
    build_parser().parse_args(argv)


def test_branch_flag_is_gone() -> None:
    parser = build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(["--branch", "main", "version"])


def test_oc_forwards_its_flags_instead_of_treating_them_as_aap_demo_options() -> None:
    args = build_parser().parse_args(["oc", "get", "pods", "-n", "aap", "--context", "other"])
    assert args.command == "oc"
    assert args.oc_args == ["get", "pods", "-n", "aap", "--context", "other"]


def test_unknown_command_is_a_usage_error() -> None:
    with pytest.raises(SystemExit) as excinfo:
        build_parser().parse_args(["nonesuch"])
    assert excinfo.value.code == 2


# -- dispatch ---------------------------------------------------------------


def test_no_args_shows_the_welcome_banner(tmp_path, capsys) -> None:
    rc = run([], env={"AAP_DEMO_DIR": str(tmp_path), "QUIET": ""})
    out = capsys.readouterr().out
    assert rc == 0
    assert "aap-demo - Deploy AAP 2.7 to OpenShift Local" in out
    assert "aap-demo create" in out
    assert "pull-secret.txt" in out
    assert "config set pull-secret" in out


def test_welcome_names_the_xdg_pull_secret(tmp_path, capsys) -> None:
    home = tmp_path / "home"
    home.mkdir()
    rc = run([], env={"HOME": str(home), "QUIET": ""})
    out = capsys.readouterr().out
    assert rc == 0
    assert "~/.local/state/aap-demo/pull-secret.txt" in out
    assert "config set pull-secret" in out


def test_welcome_skips_the_pull_secret_hint_when_the_file_is_already_there(
    tmp_path, capsys
) -> None:
    (tmp_path / "pull-secret.txt").write_text("{}\n")
    rc = run([], env={"AAP_DEMO_DIR": str(tmp_path), "HOME": str(tmp_path), "QUIET": ""})
    out = capsys.readouterr().out
    assert rc == 0
    assert "Save it as" not in out


def test_quiet_silences_the_welcome_banner(tmp_path, capsys) -> None:
    rc = run([], env={"AAP_DEMO_DIR": str(tmp_path), "QUIET": "1"})
    captured = capsys.readouterr()
    assert rc == 0
    assert captured.out == ""
    assert captured.err == ""


def test_help_command_prints_help(tmp_path, capsys) -> None:
    rc = run(["help"], env={"AAP_DEMO_DIR": str(tmp_path)})
    assert rc == 0
    assert "<COMMAND>" in capsys.readouterr().out


def test_version_command_reports_the_package_version(tmp_path, capsys) -> None:
    from aap_demo import __version__

    rc = run(["version"], env={"AAP_DEMO_DIR": str(tmp_path)})
    assert rc == 0
    assert __version__ in capsys.readouterr().out


def test_version_command_supports_json(tmp_path, capsys) -> None:
    import json

    rc = run(["--output", "json", "version"], env={"AAP_DEMO_DIR": str(tmp_path)})
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["version"]


@pytest.mark.parametrize(
    "command",
    # deploy/redeploy/clean/setup left this list in phase 3; they now reach a
    # real cluster and are covered by tests/unit/test_cluster_deploy.py.
    ["enable", "gui"],
)
def test_unported_commands_fail_cleanly(command: str, tmp_path, capsys) -> None:
    """A skeleton command must say so, not pretend to succeed."""
    from aap_demo.cli.main import main

    rc = main([command, "--config", str(tmp_path / "c.yaml")])
    assert rc == 1
    assert "not yet implemented" in capsys.readouterr().err


def test_set_requires_key_value(tmp_path, capsys) -> None:
    from aap_demo.cli.main import main

    rc = main(["--set", "BROKEN", "version"])
    assert rc == 2
    assert "KEY=VALUE" in capsys.readouterr().err


def test_console_ascii_fallback_when_the_stream_cannot_encode() -> None:
    from aap_demo.core.console import ASCII_GLYPHS, Console

    stream = io.TextIOWrapper(io.BytesIO(), encoding="ascii")
    console = Console(stdout=stream, env={})
    assert console.glyphs == ASCII_GLYPHS


def test_recording_console_captures_streams() -> None:
    console = RecordingConsole()
    console.success("done")
    console.warn("careful")
    assert "done" in console.stdout
    assert "careful" in console.stderr
