"""The CommandRunner seam and its FakeRunner double (design §7.2)."""

from __future__ import annotations

import sys

import pytest

from aap_demo.core.errors import PrerequisiteError
from aap_demo.core.events import EventEmitter, ListSink
from aap_demo.exec.runner import (
    CommandFailed,
    CompletedCommand,
    FakeRunner,
    SubprocessRunner,
)

# -- FakeRunner -------------------------------------------------------------


def test_registered_prefix_matches() -> None:
    runner = FakeRunner().ok("kubectl get pods", stdout="no resources")
    result = runner.run(["kubectl", "get", "pods", "-n", "aap-operator"])
    assert result.ok and result.stdout == "no resources"


def test_unregistered_invocation_fails_the_test() -> None:
    runner = FakeRunner().ok("kubectl get pods")
    with pytest.raises(AssertionError, match="unregistered command"):
        runner.run(["oc", "adm", "policy", "add-scc-to-group"])


def test_wildcard_token_matches_anything() -> None:
    runner = FakeRunner().ok(["oc", "adm", "policy", "add-scc-to-group", "*", "*"])
    assert runner.run(
        ["oc", "adm", "policy", "add-scc-to-group", "anyuid", "system:serviceaccounts:aap-operator"]
    ).ok


def test_regex_token_matches() -> None:
    runner = FakeRunner().ok(["kubectl", "get", "~^(pods|pvc)$"])
    assert runner.run(["kubectl", "get", "pvc"]).ok


def test_callable_result_sees_the_argv() -> None:
    runner = FakeRunner().register(
        "kubectl get", lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=argv[-1])
    )
    assert runner.run(["kubectl", "get", "aap"]).stdout == "aap"


def test_exception_result_is_raised() -> None:
    runner = FakeRunner().register("crc start", PrerequisiteError("crc not found"))
    with pytest.raises(PrerequisiteError):
        runner.run(["crc", "start"])


def test_ordering_is_assertable() -> None:
    """The SCC-grant-timing class of bug ADR-010 flagged as a drift risk."""
    runner = FakeRunner().ok("oc adm policy").ok("kubectl apply")
    runner.run(["oc", "adm", "policy", "add-scc-to-group", "anyuid", "g"])
    runner.run(["kubectl", "apply", "-f", "-"])
    assert runner.index_of("oc adm policy") < runner.index_of("kubectl apply")


def test_never_called_is_an_explicit_failure() -> None:
    with pytest.raises(AssertionError, match="never called"):
        FakeRunner().index_of("crc stop")


def test_check_raises_command_failed() -> None:
    runner = FakeRunner().fail("crc start", returncode=3, stderr="boom")
    with pytest.raises(CommandFailed) as excinfo:
        runner.run(["crc", "start"], check=True)
    assert excinfo.value.exit_code == 1
    assert "boom" in (excinfo.value.hint or "")


def test_input_and_env_are_recorded() -> None:
    runner = FakeRunner().ok("kubectl apply")
    runner.run(["kubectl", "apply", "-f", "-"], input="manifest", env={"KUBECONFIG": "/kc"})
    call = runner.calls[0]
    assert call.input == "manifest"
    assert call.env == {"KUBECONFIG": "/kc"}


def test_streaming_mode_emits_log_events() -> None:
    sink = ListSink()
    emitter = EventEmitter(sink=sink)
    runner = FakeRunner().ok("crc start", stdout="line one\nline two")
    runner.run(["crc", "start"], sink=emitter)
    assert sink.texts("log") == ["line one", "line two"]
    assert [e.seq for e in sink.events] == [0, 1]


# -- SubprocessRunner -------------------------------------------------------


def test_real_runner_captures_output() -> None:
    result = SubprocessRunner().run([sys.executable, "-c", "print('hello')"])
    assert result.ok and result.stdout.strip() == "hello"


def test_real_runner_reports_a_non_zero_exit() -> None:
    result = SubprocessRunner().run([sys.executable, "-c", "raise SystemExit(4)"])
    assert result.returncode == 4 and not result.ok


def test_missing_binary_is_a_prerequisite_error() -> None:
    with pytest.raises(PrerequisiteError) as excinfo:
        SubprocessRunner().run(["definitely-not-a-real-binary-xyz"])
    assert excinfo.value.exit_code == 3


def test_real_runner_streams_lines_as_events() -> None:
    sink = ListSink()
    runner = SubprocessRunner()
    runner.run([sys.executable, "-c", "print('a'); print('b')"], sink=EventEmitter(sink=sink))
    assert sink.texts("log") == ["a", "b"]


def test_env_override_is_merged_not_replaced() -> None:
    result = SubprocessRunner().run(
        [sys.executable, "-c", "import os; print(os.environ['AAP_DEMO_PROBE'])"],
        env={"AAP_DEMO_PROBE": "value"},
    )
    assert result.stdout.strip() == "value"


def test_runner_never_uses_shell() -> None:
    """shell=True would reintroduce per-platform quoting divergence (§6.1)."""
    import ast
    import inspect

    from aap_demo.exec import runner as runner_mod

    tree = ast.parse(inspect.getsource(runner_mod))
    for node in ast.walk(tree):
        if isinstance(node, ast.keyword) and node.arg == "shell":
            pytest.fail("exec/runner.py passes shell= to subprocess")
