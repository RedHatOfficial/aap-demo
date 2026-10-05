"""``core/console.py``: the stdout/stderr split (design §2.2).

``report()`` is report *content* — always stdout, whatever the severity glyph.
``failure()``/``warn()`` stay stderr-only, for actual error conditions.
"""

from __future__ import annotations

from aap_demo.core.console import Console, RecordingConsole


def test_report_lines_always_go_to_stdout() -> None:
    console = RecordingConsole()
    console.report("passed", status="ok")
    console.report("broken", status="fail")
    console.report("iffy", status="warn")
    console.report("fyi", status="info")
    console.report("bare")

    assert console.stderr == ""
    assert console.stdout_lines == [
        "[ok] passed",
        "[x] broken",
        "[!] iffy",
        "- fyi",
        "bare",
    ]


def test_report_indent_matches_bash_check_lines() -> None:
    console = RecordingConsole()
    console.report("all good", status="ok", indent=2)
    assert console.stdout_lines == ["  [ok] all good"]


def test_quiet_writes_nothing() -> None:
    console = RecordingConsole(quiet=True)
    console.step("Installing CRC")
    console.progress("still going")
    console.success("ready")
    console.failure("boom")
    console.out("hello")
    assert console.stdout == ""
    assert console.stderr == ""


def test_crc_log_lines_keep_the_message_and_drop_the_oc_banner() -> None:
    console = RecordingConsole()
    console.subprocess_line('level=info msg="Checking if vfkit is installed"')
    console.subprocess_line('level=info msg="Using bundle path /tmp/bundle.crcbundle"')
    console.subprocess_line('level=info msg="Creating CRC VM for MicroShift 4.22.13..."')
    console.subprocess_line('level=error msg="Error running post start: exit status 1"')
    console.subprocess_line("Started the MicroShift cluster.")
    console.subprocess_line("$ eval $(crc oc-env)")
    assert console.stdout_lines == ["Creating CRC VM for MicroShift 4.22.13..."]
    assert console.stderr_lines == ["[!] Error running post start: exit status 1"]


def test_warn_during_live_status_prints_above_the_spinner() -> None:
    console = RecordingConsole()
    printed: list = []

    class _Rich:
        def print(self, text: str, **_kwargs: object) -> None:
            printed.append(text)

    console._status = object()
    console._rich = _Rich()
    console.warn("Error running post start: exit status 1")
    assert console.stderr == ""
    assert printed == ["[!] Error running post start: exit status 1"]


def test_basic_step_is_a_plain_line() -> None:
    console = RecordingConsole()
    console.step("aap-demo create")
    assert console.stdout_lines == ["aap-demo create"]


def test_failure_and_warn_stay_on_stderr() -> None:
    console = RecordingConsole()
    console.failure("boom")
    console.warn("careful")
    assert console.stdout == ""
    assert "boom" in console.stderr
    assert "careful" in console.stderr


def test_paint_colors_only_the_fragment() -> None:
    console = Console(color=True, env={})
    painted = console.paint("running", "green")
    assert painted.startswith("\033[0;32m")
    assert painted.endswith("\033[0m")
    assert "running" in painted


def test_paint_is_a_no_op_without_color() -> None:
    console = Console(color=False, env={})
    assert console.paint("running", "green") == "running"
