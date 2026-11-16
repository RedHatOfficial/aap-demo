"""``diagnostics/ai.py``: multi-backend ``diagnose --ai`` selection and context."""

from __future__ import annotations

from pathlib import Path

from aap_demo.core.console import RecordingConsole
from aap_demo.diagnostics import ai as diagnose_ai
from aap_demo.diagnostics.checks import DiagnoseReport
from aap_demo.exec.runner import FakeRunner


def test_resolve_backend_prefers_cursor_agent_env() -> None:
    assert (
        diagnose_ai.resolve_backend(
            {"CURSOR_AGENT": "1"},
            which=lambda name: "/usr/bin/claude" if name == "claude" else None,
        )
        == "embedded"
    )


def test_resolve_backend_auto_picks_cursor_then_claude() -> None:
    assert diagnose_ai.resolve_backend(
        {}, which=lambda name: "/c" if name == "cursor" else None
    ) == ("cursor")
    assert diagnose_ai.resolve_backend(
        {}, which=lambda name: "/c" if name == "claude" else None
    ) == ("claude")
    assert diagnose_ai.resolve_backend({}, which=lambda _name: None) == "none"


def test_resolve_backend_honors_explicit_override() -> None:
    assert (
        diagnose_ai.resolve_backend(
            {"AAP_DIAGNOSE_AI_BACKEND": "claude", "CURSOR_AGENT": "1"},
            which=lambda name: "/c" if name == "cursor" else None,
        )
        == "claude"
    )


def test_build_context_includes_problem_pod_logs() -> None:
    runner = FakeRunner()
    runner.ok(
        "kubectl get pods -n aap-operator -o wide --no-headers",
        "bad-pod 0/1 CrashLoopBackOff\nok-pod 1/1 Running\n",
    )
    runner.ok("kubectl logs bad-pod -n aap-operator --tail=20", "EACCES on socket\n")
    runner.ok("kubectl get pvc -n aap-operator", "NAME STATUS\n")
    runner.ok("kubectl get sc", "NAME PROVISIONER\n")
    runner.ok("kubectl get aap -n aap-operator -o yaml", "status:\n  phase: Failed\n")
    runner.ok("kubectl get events -n aap-operator --sort-by=.lastTimestamp", "event-1\n")

    text = diagnose_ai.build_context(runner, "aap-operator", DiagnoseReport(issues=1, warnings=0))
    assert "Issues: 1, Warnings: 0" in text
    assert "bad-pod" in text
    assert "EACCES on socket" in text
    assert "phase: Failed" in text


def test_embedded_analysis_writes_context_file(tmp_path: Path) -> None:
    console = RecordingConsole()
    runner = FakeRunner()
    runner.ok("kubectl get pods -n aap-operator -o wide --no-headers", "No pods")
    runner.ok("kubectl get pvc -n aap-operator", "No PVCs")
    runner.ok("kubectl get sc", "No storage classes")
    runner.ok("kubectl get aap -n aap-operator -o yaml", "No AAP CR")
    runner.ok("kubectl get events -n aap-operator --sort-by=.lastTimestamp", "No events")

    rc = diagnose_ai.run_analysis(
        console=console,
        runner=runner,
        namespace="aap-operator",
        report=DiagnoseReport(),
        env={"CURSOR_AGENT": "1"},
        state_dir=tmp_path,
        which=lambda _name: None,
    )
    assert rc == 0
    saved = tmp_path / "diagnose-ai-context.txt"
    assert saved.is_file()
    assert "AAP Demo Diagnose Results" in saved.read_text(encoding="utf-8")
    assert "Cursor Agent" in console.stdout
    assert str(saved) in console.stdout


def test_none_backend_returns_1() -> None:
    console = RecordingConsole()
    runner = FakeRunner()
    runner.ok("kubectl get pods -n aap-operator -o wide --no-headers", "")
    runner.ok("kubectl get pvc -n aap-operator", "")
    runner.ok("kubectl get sc", "")
    runner.ok("kubectl get aap -n aap-operator -o yaml", "")
    runner.ok("kubectl get events -n aap-operator --sort-by=.lastTimestamp", "")

    rc = diagnose_ai.run_analysis(
        console=console,
        runner=runner,
        namespace="aap-operator",
        report=DiagnoseReport(),
        env={},
        state_dir=Path("/tmp"),
        which=lambda _name: None,
    )
    assert rc == 1
    assert "No AI backend available" in console.stdout


def test_claude_backend_sends_context_on_stdin() -> None:
    console = RecordingConsole()
    runner = FakeRunner()
    runner.ok("kubectl get pods -n aap-operator -o wide --no-headers", "pod Running")
    runner.ok("kubectl get pvc -n aap-operator", "pvc")
    runner.ok("kubectl get sc", "sc")
    runner.ok("kubectl get aap -n aap-operator -o yaml", "status:\n  ok: true\n")
    runner.ok("kubectl get events -n aap-operator --sort-by=.lastTimestamp", "ev")
    runner.ok("claude -p", "root cause: missing SCC\n")

    rc = diagnose_ai.run_analysis(
        console=console,
        runner=runner,
        namespace="aap-operator",
        report=DiagnoseReport(issues=1),
        env={"AAP_DIAGNOSE_AI_BACKEND": "claude"},
        state_dir=Path("/tmp"),
        which=lambda name: "/usr/bin/claude" if name == "claude" else None,
    )
    assert rc == 0
    assert "root cause: missing SCC" in console.stdout
    assert runner.called("claude -p")
    assert any(call.input and "AAP Demo Diagnose Results" in call.input for call in runner.calls)
