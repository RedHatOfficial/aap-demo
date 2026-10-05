"""Renders a ``DiagnoseReport`` to the terminal (design §2.2).

Kept separate from ``checks.py`` per the design's mapping table
(``cmd_diagnose`` → ``diagnostics/checks.py`` + ``report.py`` + ``ai.py``),
even though phase 1 has no ``ai.py`` — ``--ai`` is out of scope here and is
rejected at the CLI layer (``cli/observe.py::diagnose``).
"""

from __future__ import annotations

from typing import Any

from aap_demo.diagnostics.checks import DiagnoseReport

#: Check level → the glyph key ``Console.report`` prefixes. Every one of these
#: lines is report *content*, so it goes to stdout regardless of severity, the
#: way bash's ``_check_pass``/``_check_fail``/… all did (aap-demo.sh:1020-1028).
_STATUS_BY_LEVEL = {
    "pass": "ok",
    "fail": "fail",
    "warn": "warn",
    "info": "info",
}

#: Bash indents every check line two spaces under its section header
#: (``printf "  \033[32m✓\033[0m %s\n"``); summary lines are not indented.
CHECK_INDENT = 2


def render_text(console: Any, report: DiagnoseReport) -> None:
    """Ports the section/summary printing in ``cmd_diagnose`` (aap-demo.sh:1012-1300)."""
    console.out("")
    console.step("aap-demo diagnose - Checking environment health...")
    console.out("")

    for section in report.sections:
        console.out(f"{section.name}:")
        for check in section.checks:
            console.report(check.message, status=_STATUS_BY_LEVEL[check.level], indent=CHECK_INDENT)
        console.out("")

    if not report.cluster_reachable:
        console.out("Cannot proceed without cluster connectivity.")
        return

    console.out("─────────────────────────────────────")
    if report.issues == 0 and report.warnings == 0:
        console.report("All checks passed — environment is healthy", status="ok")
    elif report.issues == 0:
        console.report(f"{report.warnings} warning(s), no critical issues", status="warn")
    else:
        console.report(f"{report.issues} issue(s), {report.warnings} warning(s)", status="fail")
        console.out("")
        console.out("For detailed diagnostics: aap-demo must-gather")
        console.out("For AI-assisted analysis:  aap-demo diagnose --ai")
