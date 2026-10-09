"""Checklist rendering: boxes check off, and the active step uses Ansible teal."""

import time

from aap_demo.core.console import ANSIBLE_TEAL, RecordingConsole


def test_steps_check_off_in_order() -> None:
    console = RecordingConsole()
    console.tasks(["Starting CRC", "Waiting for CRC SSH", "Checking the CRI-O pull secret"])

    console.step("Starting CRC")
    console.checkpoint("CRC is running")
    console.step("Waiting for CRC SSH")

    assert console.task_states() == [
        ("Starting CRC", "done"),
        ("Waiting for CRC SSH", "active"),
        ("Checking the CRI-O pull secret", "pending"),
    ]
    assert "CRC is running" in console.stdout
    assert "Waiting for CRC SSH" in console.stdout


def test_a_new_step_checks_off_the_previous_one() -> None:
    console = RecordingConsole()
    console.tasks(["One", "Two"])
    console.step("One")
    console.step("Two")
    assert console.task_states() == [("One", "done"), ("Two", "active")]


def test_success_drops_steps_that_never_started() -> None:
    console = RecordingConsole()
    console.tasks(["Connecting to the cluster", "Installing OLM"])
    console.step("Connecting to the cluster")
    console.success("Already installed")
    assert console.task_states() == [("Connecting to the cluster", "done")]
    assert "Already installed" in console.stdout


def test_failure_marks_the_active_step() -> None:
    console = RecordingConsole()
    console.tasks(["Starting CRC"])
    console.step("Starting CRC")
    console.failure("crc start failed")
    assert console.task_states() == [("Starting CRC", "failed")]
    assert "crc start failed" in console.stderr


def test_crc_preflight_checks_are_not_logged_line_by_line() -> None:
    console = RecordingConsole()
    console.subprocess_line("Checking if running as non-root")
    console.subprocess_line('level=info msg="Checking if vfkit is installed"')
    console.subprocess_line('level=info msg="Using bundle path /tmp/bundle.crcbundle"')
    console.subprocess_line(
        "Your system is correctly setup for using CRC. Use 'crc start' to start the instance"
    )
    console.subprocess_line('level=info msg="Creating CRC VM for MicroShift 4.22.13..."')
    assert console.stdout_lines == ["Creating CRC VM for MicroShift 4.22.13..."]


def test_crc_start_narration_updates_the_active_step() -> None:
    console = RecordingConsole()
    console.tasks(["Starting CRC"])
    console.step("Starting CRC")
    console.subprocess_line(
        'level=info msg="Loading bundle: crc_microshift_vfkit_4.22.13_arm64..."'
    )
    console.subprocess_line(
        'level=info msg="Waiting for kube-apiserver availability... [takes around 2min]"'
    )
    console.subprocess_line('level=error msg="Error running post start: exit status 1"')
    assert "Loading bundle" not in console.stdout
    assert "kube-apiserver" not in console.stdout
    assert console._detail == "Waiting for the Kubernetes API"
    assert "Error running post start" in console.stderr


def test_a_live_checklist_does_not_copy_the_finished_step() -> None:
    console = RecordingConsole()

    class _Live:
        def refresh(self) -> None:
            return None

    console.tasks(["Starting CRC"])
    console.step("Starting CRC")
    before = list(console.stdout_lines)
    console._task_live = _Live()
    console.checkpoint("CRC is running")
    assert console.stdout_lines == before
    assert console._tasks[0].state == "done"
    assert console._tasks[0].note == "CRC is running"


def test_parent_task_checks_off_and_offers_next_steps() -> None:
    console = RecordingConsole()
    console.tasks(["Starting CRC"], title="Creating aap-demo crc cluster")
    console.step("Starting CRC")
    console.checkpoint("CRC is running")
    console.finish_checklist()
    console.next_steps((("aap-demo deploy", "Deploy AAP 2.7"),))
    assert console._title_done
    assert console._tasks == []
    assert "Creating aap-demo crc cluster" in console.stdout
    assert "Next:" in console.stdout
    assert "aap-demo deploy" in console.stdout
    assert "Deploy AAP 2.7" in console.stdout
    assert console.stdout_lines[-1] == ""


def test_spinners_advance_instead_of_restarting_each_frame() -> None:
    from aap_demo.core.console import _Task

    console = RecordingConsole()
    console._title = "Creating aap-demo crc cluster"
    console._tasks = [_Task("Starting CRC", state="active")]
    mark, label = console._parent_cells()
    assert label.plain == "Creating aap-demo crc cluster"
    assert "bold" not in str(label.style).lower()
    active = console._task_mark(console._tasks[0])[0]
    assert console._spinner("parent") is mark
    assert console._spinner("active") is active
    active.start_time = 0.0
    assert active.render(0.0).plain != active.render(0.5).plain


def test_a_traveling_letter_uses_the_requested_styles() -> None:
    from rich.console import Console as RichConsole

    from aap_demo.core.console import ANSIBLE_TEAL_DARK, _Travel

    travel = _Travel("NFS", base=ANSIBLE_TEAL_DARK, travel=f"bold {ANSIBLE_TEAL}", at=1)
    rendered = list(RichConsole(force_terminal=True, width=20).render(travel))
    letters = [seg for seg in rendered if seg.text.strip()]
    assert [seg.text for seg in letters] == ["N", "F", "S"]
    assert ANSIBLE_TEAL_DARK.lower() in str(letters[0].style).lower()
    assert ANSIBLE_TEAL.lower() in str(letters[1].style).lower()
    assert "bold" in str(letters[1].style).lower()


def test_finished_steps_are_primary_teal_and_the_active_step_is_bold() -> None:
    from aap_demo.core.console import _Task

    console = RecordingConsole()
    _mark, done = console._task_mark(_Task("One", state="done", note="Done"))
    _spin, active = console._task_mark(_Task("One", state="active"))
    assert "bold" not in str(done.style).lower()
    assert ANSIBLE_TEAL.lower() in str(done.style).lower()
    assert "bold" in str(active.style).lower()
    assert ANSIBLE_TEAL.lower() in str(active.style).lower()


def test_component_rows_check_off_and_then_collapse() -> None:
    console = RecordingConsole()
    console.tasks(["Waiting for AAP"])
    console.step("Waiting for AAP")
    console.set_children(
        [
            ("gateway", "done", ""),
            ("controller", "active", "Running reconciliation (task 0/1)"),
        ]
    )
    children = console._tasks[0].children
    assert [child.title for child in children] == ["gateway", "controller"]
    assert children[0].state == "done"
    assert children[1].state == "active"
    console.set_children([("gateway", "done", ""), ("controller", "done", "")])
    assert [child.state for child in console._tasks[0].children] == ["done", "done"]
    console.checkpoint("AAP deployment successful!")
    assert console._tasks[0].children == []


def test_wait_ticks_update_the_active_step_instead_of_scrolling() -> None:
    console = RecordingConsole()

    class _Live:
        def update(self, _renderable: object) -> None:
            return None

        def refresh(self) -> None:
            return None

    console.tasks(["Waiting for AAP"])
    console.step("Waiting for AAP")
    console._task_live = _Live()
    before = list(console.stdout_lines)
    console.progress("Becoming Successful (0m 00s)")
    console.progress("Becoming Successful (0m 10s)")
    console.progress("Becoming Successful (0m 10s)")
    assert console.stdout_lines == before
    assert console._detail == "Becoming Successful (0m 10s)"


def test_a_checklist_note_is_bulleted_under_the_step_title() -> None:
    console = RecordingConsole()
    console.note("podman --connection aap-demo build .")
    mark = console._child_mark()
    assert len(mark) == 2
    assert len(set(mark)) == 1
    assert console.stdout_lines == [f"       {mark} podman --connection aap-demo build ."]


def test_ansible_teal_is_the_spinner_color() -> None:
    assert ANSIBLE_TEAL == "#5BBDB5"


def test_nested_line_fades_across_three_different_characters() -> None:
    from aap_demo.core.console import _NEST_COLORS

    console = RecordingConsole()
    line = console._nested_line("Waiting for the NFS server")
    pieces = [span for span in line._spans if span.start != span.end]
    mark = console._child_mark()
    assert "".join(line.plain.split())[: len(mark)] == mark
    assert [str(span.style) for span in pieces[:2]] == list(_NEST_COLORS)


def _flash_styles(renderable: object) -> list:
    from rich.console import Console as RichConsole

    letters = [
        (seg.text, str(seg.style))
        for seg in RichConsole(force_terminal=True, width=40).render(renderable)
        if seg.text.strip()
    ]
    return letters


def test_one_highlight_starts_white_then_walks_the_ramp_and_the_words() -> None:
    from aap_demo.core.console import _TEAL_BOLD, _NestedFlash

    console = RecordingConsole()
    marks = console._nest_chars()
    at_flash = _flash_styles(_NestedFlash("NFS", marks, at=0))
    at_ramp = _flash_styles(_NestedFlash("NFS", marks, at=1))
    at_word = _flash_styles(_NestedFlash("NFS", marks, at=2))
    assert at_flash[0][0] == marks[0]
    assert "ffffff" in at_flash[0][1].lower()
    assert "ffffff" not in at_ramp[0][1].lower()
    assert at_ramp[1][0] == marks[1]
    assert _TEAL_BOLD.lower() in at_ramp[1][1].lower()
    assert at_word[2][0] == "N"
    assert _TEAL_BOLD.lower() in at_word[2][1].lower()
    assert "ffffff" not in at_word[0][1].lower()


def test_a_new_detail_starts_the_cycle_on_the_white_flash() -> None:
    import time

    from aap_demo.core.console import _NestedFlash

    console = RecordingConsole()
    marks = console._nest_chars()
    styles = _flash_styles(_NestedFlash("NFS", marks, started=time.monotonic()))
    assert styles[0][0] == marks[0]
    assert "ffffff" in styles[0][1].lower()


def test_nested_letter_travels_at_half_the_original_speed() -> None:
    from aap_demo.core.console import _TRAVEL_PER_SECOND

    assert _TRAVEL_PER_SECOND == 6


class _QuietLive:
    """Stand-in for Rich Live with its refresh thread already stopped."""

    def __init__(self) -> None:
        self.refreshes = 0
        self._started = True
        self.auto_refresh = False
        self._refresh_thread = None

    def refresh(self) -> None:
        self.refreshes += 1


def test_paint_while_keeps_refreshing_until_the_command_returns() -> None:
    console = RecordingConsole()
    live = _QuietLive()
    console._task_live = live

    def work() -> str:
        time.sleep(0.3)
        return "gone"

    assert console.paint_while(work) == "gone"
    assert live.refreshes >= 2


def test_paint_while_reraises_the_command_error() -> None:
    console = RecordingConsole()

    def work() -> None:
        raise RuntimeError("crc failed")

    try:
        console.paint_while(work)
    except RuntimeError as exc:
        assert str(exc) == "crc failed"
    else:
        raise AssertionError("paint_while must surface the command error")
