"""``aap-demo diagnose --ai`` backends.

Ports the bash multi-backend analysis: Cursor Agent (embedded), Cursor CLI,
and Claude CLI. Selection is automatic unless ``AAP_DIAGNOSE_AI_BACKEND``
forces one of ``auto`` / ``embedded`` / ``cursor`` / ``claude``.
"""

from __future__ import annotations

import re
import shutil
from pathlib import Path
from typing import Any, Callable, Mapping, Optional, Sequence

from aap_demo.core.errors import PrerequisiteError
from aap_demo.diagnostics.checks import DiagnoseReport

PROMPT = (
    "You are an AAP Demo troubleshooting assistant. Analyze the diagnostic "
    "output below and:\n"
    "1. Identify the root cause of any issues\n"
    "2. Provide specific fix commands the user can run\n"
    "3. If the issue appears to be a bug in aap-demo itself, suggest filing a "
    "GitHub issue at https://github.com/RedHatOfficial/aap-demo/issues\n"
    "\n"
    "Be concise and actionable. Focus on what the user needs to do next."
)

_PROBLEM_RE = re.compile(r"CrashLoopBackOff|Error|ImagePullBackOff|Pending")
Which = Callable[[str], Optional[str]]


def resolve_backend(
    env: Mapping[str, str],
    *,
    which: Which = shutil.which,
) -> str:
    """Pick ``embedded``, ``cursor``, ``claude``, or ``none``."""
    requested = (env.get("AAP_DIAGNOSE_AI_BACKEND") or "auto").strip().lower()
    if requested in {"embedded", "cursor", "claude"}:
        return requested
    if requested != "auto":
        return "none"
    if env.get("CURSOR_AGENT") == "1":
        return "embedded"
    if which("cursor"):
        return "cursor"
    if which("claude"):
        return "claude"
    return "none"


def _kubectl_text(runner: Any, argv: Sequence[str], *, fallback: str) -> str:
    result = runner.run(["kubectl", *argv])
    if not result.ok:
        return fallback
    text = (result.stdout or "").rstrip("\n")
    return text if text else fallback


def _problem_pod_names(pod_output: str) -> list[str]:
    names: list[str] = []
    for line in pod_output.splitlines():
        if not _PROBLEM_RE.search(line):
            continue
        parts = line.split()
        if parts:
            names.append(parts[0])
    return names


def _aap_status_excerpt(aap_yaml: str) -> str:
    """Keep the status block compact the way bash's ``grep -A20`` did."""
    lines = aap_yaml.splitlines()
    for index, line in enumerate(lines):
        if line == "status:" or line.startswith("status:"):
            return "\n".join(lines[index : index + 21]).rstrip()
    return aap_yaml


def build_context(
    runner: Any,
    namespace: str,
    report: DiagnoseReport,
) -> str:
    """Collect kubectl context for the AI prompt."""
    pod_output = _kubectl_text(
        runner,
        ["get", "pods", "-n", namespace, "-o", "wide", "--no-headers"],
        fallback="No pods",
    )
    problem_lines = [line for line in pod_output.splitlines() if _PROBLEM_RE.search(line)] or [
        "None"
    ]

    log_chunks: list[str] = []
    for pod in _problem_pod_names(pod_output):
        logs = _kubectl_text(
            runner,
            ["logs", pod, "-n", namespace, "--tail=20"],
            fallback="",
        )
        log_chunks.append(f"--- {pod} ---\n{logs}".rstrip())
    problem_logs = "\n".join(log_chunks) if log_chunks else "None"

    aap_yaml = _kubectl_text(
        runner,
        ["get", "aap", "-n", namespace, "-o", "yaml"],
        fallback="No AAP CR",
    )
    aap_status = _aap_status_excerpt(aap_yaml) if aap_yaml != "No AAP CR" else aap_yaml

    events = _kubectl_text(
        runner,
        ["get", "events", "-n", namespace, "--sort-by=.lastTimestamp"],
        fallback="No events",
    )
    if events != "No events":
        event_lines = events.splitlines()
        events = "\n".join(event_lines[-20:]) if event_lines else "No events"

    return (
        "AAP Demo Diagnose Results:\n"
        f"Issues: {report.issues}, Warnings: {report.warnings}\n"
        "Infra: OpenShift Local (CRC)\n"
        f"Namespace: {namespace}\n"
        "\n"
        "Cluster State:\n"
        f"{pod_output}\n"
        "\n"
        "PVC State:\n"
        f"{_kubectl_text(runner, ['get', 'pvc', '-n', namespace], fallback='No PVCs')}\n"
        "\n"
        "Storage Classes:\n"
        f"{_kubectl_text(runner, ['get', 'sc'], fallback='No storage classes')}\n"
        "\n"
        "AAP CR Status:\n"
        f"{aap_status}\n"
        "\n"
        "Recent Events:\n"
        f"{events}\n"
        "\n"
        "Problem Pods:\n"
        f"{chr(10).join(problem_lines)}\n"
        "\n"
        "Problem Pod Logs:\n"
        f"{problem_logs}"
    )


def _print_section(console: Any, title: str) -> None:
    console.out("")
    console.out("─────────────────────────────────────")
    console.out(title)
    console.out("")


def _run_claude_print(console: Any, runner: Any, context: str) -> bool:
    try:
        result = runner.run(
            ["claude", "-p", f"{PROMPT}\n\nDiagnostic data:"],
            input=context,
            timeout=300,
        )
    except PrerequisiteError:
        console.warn("AI analysis failed. Install or log in to the Claude CLI.")
        return False
    text = (result.stdout or result.stderr or "").rstrip()
    if text:
        console.out(text)
    if not result.ok:
        console.warn(
            "AI analysis failed. The diagnostic data above should help with manual troubleshooting."
        )
        return False
    return True


def _run_cursor(console: Any, runner: Any, context: str, *, which: Which) -> bool:
    prompt = f"{PROMPT}\n\n{context}"
    try:
        result = runner.run(
            ["cursor", "agent", "--print", "--mode", "ask", prompt],
            timeout=300,
        )
    except PrerequisiteError:
        result = None
    if result is not None and result.ok:
        text = (result.stdout or "").rstrip()
        if text:
            console.out(text)
        return True

    console.warn("Cursor agent failed. Try: cursor agent login")
    if which("claude"):
        console.out("  Falling back to Claude CLI...")
        return _run_claude_print(console, runner, context)

    console.out("  Showing diagnostic context for manual analysis:")
    console.out("")
    console.out(context)
    return False


def _run_embedded(console: Any, context: str, state_dir: Path) -> None:
    console.out("Diagnostic context for the active Cursor agent:")
    console.out("")
    console.out(context)
    console.out("")
    console.out(PROMPT)
    state_dir.mkdir(parents=True, exist_ok=True)
    context_file = state_dir / "diagnose-ai-context.txt"
    context_file.write_text(context + "\n", encoding="utf-8")
    console.out("")
    console.out(f"Context saved to: {context_file}")


def run_analysis(
    *,
    console: Any,
    runner: Any,
    namespace: str,
    report: DiagnoseReport,
    env: Mapping[str, str],
    state_dir: Path,
    which: Which = shutil.which,
) -> int:
    """Run AI analysis after the health report. Returns 0 on success, 1 if unavailable."""
    backend = resolve_backend(env, which=which)
    context = build_context(runner, namespace, report)

    if backend == "embedded":
        _print_section(console, "AI Analysis (Cursor Agent)")
        _run_embedded(console, context, state_dir)
        return 0

    if backend == "cursor":
        _print_section(console, "AI Analysis (powered by Cursor)")
        console.out("(Diagnostic data is sent to Cursor for analysis)")
        console.out("")
        return 0 if _run_cursor(console, runner, context, which=which) else 1

    if backend == "claude":
        _print_section(console, "AI Analysis (powered by Claude)")
        console.out("(Diagnostic data is sent to the Claude API for analysis)")
        console.out("")
        return 0 if _run_claude_print(console, runner, context) else 1

    console.out("")
    console.out("─────────────────────────────────────")
    console.report("No AI backend available for diagnose --ai", status="fail")
    console.out("")
    console.out("  Options:")
    console.out("    • Run from Cursor Agent (CURSOR_AGENT=1) for embedded analysis")
    console.out("    • Install Cursor CLI: cursor agent login")
    console.out("    • Install Claude CLI: https://docs.anthropic.com/en/docs/claude-code")
    console.out("    • Set AAP_DIAGNOSE_AI_BACKEND=embedded|cursor|claude")
    return 1
