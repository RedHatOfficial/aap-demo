"""All user-facing output.

No other module may write to stdout or stderr. ``--output rich`` (the default
on a terminal) keeps a live spinner on the current step and prints the log
above it. ``--output basic`` is a plain flushed log. ``--quiet`` writes
nothing. ``json`` and ``yaml`` are rendered by ``core/output.py`` through the
same console, so quiet silences those too.
"""

from __future__ import annotations

import os
import re
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import IO, Callable, List, Optional, Sequence, Tuple, TypeVar

from rich.console import Console as RichConsole
from rich.console import Group
from rich.live import Live
from rich.padding import Padding
from rich.spinner import Spinner
from rich.status import Status
from rich.table import Table
from rich.text import Text

# Ansible's brand teal, the same hue used in the upstream Ansible mark.
# The dark alternate is the same hue, held back so nested lines sit under it.
ANSIBLE_TEAL = "#5BBDB5"
ANSIBLE_TEAL_DARK = "#1A5C58"
_TEAL_BOLD = f"bold {ANSIBLE_TEAL}"
_FLASH_WHITE = "bold #FFFFFF"
# Two copies of one block. The left rests in primary teal and flashes white.
# The right rests in the same dark teal as the words.
_NEST_MARK = ("▓", "▓")
_NEST_MARK_ASCII = ("#", "#")
_NEST_COLORS = (ANSIBLE_TEAL, ANSIBLE_TEAL_DARK)
# Letters per second for the highlight on a nested line.
_TRAVEL_PER_SECOND = 6
_T = TypeVar("_T")
# Checklist sits in from the log lines above it. The permanent check lines
# use the same width so a finished step stays aligned with the live list.
_TASK_INDENT = "  "

UNICODE_GLYPHS = {"ok": "✓", "fail": "✗", "warn": "⚠", "info": "·"}
ASCII_GLYPHS = {"ok": "[ok]", "fail": "[x]", "warn": "[!]", "info": "-"}

_COLORS = {
    "red": "\033[0;31m",
    "green": "\033[0;32m",
    # Ansible teal (#5BBDB5). Success and completed checks use this, not green.
    "teal": "\033[38;2;91;189;181m",
    "teal_dim": "\033[38;2;26;92;88m",
    "yellow": "\033[0;33m",
    "blue": "\033[0;34m",
    "bold": "\033[1m",
    "dim": "\033[2m",
}
_RESET = "\033[0m"

# CRC's logrus lines and the shell snippet it prints after a successful start.
# The snippet tells the user to eval `crc oc-env`; aap-demo owns that hand-off.
_CRC_LOG = re.compile(r'^level=(?P<level>\w+)\s+msg="(?P<msg>.*)"\s*$')
_CRC_NOISE = {
    "Started the MicroShift cluster.",
    "Started the OpenShift cluster.",
    "Use the 'oc' command line interface:",
    "$ eval $(crc oc-env)",
    "$ oc COMMAND",
}
_CRC_NOISE_PREFIXES = (
    "The default lines below are for a sh/bash shell",
    "Your system is correctly setup",
    "Using bundle path ",
)
# CRC setup and start both dump the same "Checking ..." preflight list.
_CRC_CHECK = re.compile(r"^Checking\b")


def _crc_noise(message: str) -> bool:
    """True for CRC preflight lines that ``aap-demo`` already summarizes."""
    if not message or message in _CRC_NOISE:
        return True
    if message == "Use 'crc start' to start the instance":
        return True
    if _CRC_CHECK.match(message):
        return True
    return message.startswith(_CRC_NOISE_PREFIXES)


# CRC start narrates every phase. While a checklist step is active those lines
# update that step instead of staying in the scrollback.
_CRC_STATUS = (
    ("Loading bundle", "Loading the CRC bundle"),
    ("Creating CRC VM", "Creating the CRC VM"),
    ("Generating new SSH", "Generating an SSH key"),
    ("Starting CRC VM", "Starting the CRC VM"),
    ("CRC instance is running", "CRC VM is up"),
    ("CRC VM is running", "CRC VM is running"),
    ("A CRC VM", "CRC VM is already running"),
    ("Updating authorized keys", "Updating SSH keys"),
    ("Extending and resizing", "Resizing the root filesystem"),
    ("Resizing ", "Resizing the root filesystem"),
    ("Configuring shared directories", "Configuring shared directories"),
    ("Skipping hosts file", "Skipping hosts file changes"),
    ("Check internal", "Checking DNS"),
    ("Check DNS query", "Checking DNS from the host"),
    ("Starting Microshift", "Starting MicroShift"),
    ("Starting MicroShift", "Starting MicroShift"),
    ("Waiting for kube-apiserver", "Waiting for the Kubernetes API"),
    ("Adding microshift context", "Saving the kubeconfig context"),
    ("Adding MicroShift context", "Saving the kubeconfig context"),
)


def _crc_status(message: str) -> str:
    """One checklist status for a CRC info line."""
    for prefix, label in _CRC_STATUS:
        if message.startswith(prefix):
            return label
    return message


@dataclass
class _Child:
    title: str
    state: str = "pending"
    detail: str = ""
    started: float = 0.0


def format_elapsed(seconds: float) -> str:
    """Compact duration: ``12s``, ``4m 02s``, or ``1h 03m 04s``."""
    total = max(0, int(seconds))
    hours, rem = divmod(total, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f"{hours}h {minutes:02d}m {secs:02d}s"
    if minutes:
        return f"{minutes}m {secs:02d}s"
    return f"{secs}s"


@dataclass
class _Task:
    title: str
    state: str = "pending"
    note: str = ""
    notes: List[str] = field(default_factory=list)
    children: List[_Child] = field(default_factory=list)
    timed: bool = False
    started: float = 0.0
    elapsed: float = 0.0


class _Travel:
    """One character of ``travel`` moving through text drawn in ``base``.

    Rendered on each refresh, so a live display animates it without rebuilding
    the line on the main thread.
    """

    def __init__(self, text: str, *, base: str, travel: str, at: Optional[int] = None) -> None:
        self.text = text
        self.base = base
        self.travel = travel
        self.at = at

    def __rich_console__(self, _console: object, _options: object):
        slots = [i for i, ch in enumerate(self.text) if not ch.isspace()]
        if not slots:
            yield Text(self.text, style=self.base)
            return
        if self.at is None:
            index = slots[int(time.monotonic() * _TRAVEL_PER_SECOND) % len(slots)]
        else:
            index = slots[self.at % len(slots)]
        out = Text()
        for i, ch in enumerate(self.text):
            out.append(ch, style=self.travel if i == index else self.base)
        yield out


class _NestedFlash:
    """One highlight walking the ramp and then the words.

    The cycle is anchored to ``started``, the moment this detail appeared.
    Position 0 is the white flash on the leftmost shade character. It then
    walks the rest of the ramp and the letters, and the next lap begins at
    that white flash again.
    """

    def __init__(
        self,
        text: str,
        marks: Tuple[str, str],
        *,
        at: Optional[int] = None,
        started: float = 0.0,
    ) -> None:
        self.text = text
        self.marks = marks
        self.at = at
        self.started = started

    def __rich_console__(self, _console: object, _options: object):
        full = f"  {''.join(self.marks)} {self.text}"
        mark_at = 2
        slots = [i for i, ch in enumerate(full) if i >= mark_at and not ch.isspace()]
        index = -1
        if slots:
            if self.at is None:
                phase = int((time.monotonic() - self.started) * _TRAVEL_PER_SECOND)
                index = slots[phase % len(slots)]
            else:
                index = slots[self.at % len(slots)]
        out = Text()
        for i, ch in enumerate(full):
            if i == index and i == mark_at:
                style = _FLASH_WHITE
            elif i == index:
                style = _TEAL_BOLD
            elif mark_at <= i < mark_at + len(self.marks):
                style = _NEST_COLORS[i - mark_at]
            elif ch.isspace():
                style = ""
            else:
                style = ANSIBLE_TEAL_DARK
            out.append(ch, style=style)
        yield out


def _encodes_unicode(stream: IO[str]) -> bool:
    encoding = getattr(stream, "encoding", None) or "ascii"
    try:
        UNICODE_GLYPHS["ok"].encode(encoding)
    except (LookupError, UnicodeEncodeError):
        return False
    return True


class Console:
    def __init__(
        self,
        *,
        stdout: Optional[IO[str]] = None,
        stderr: Optional[IO[str]] = None,
        quiet: bool = False,
        color: Optional[bool] = None,
        env: Optional[dict] = None,
        style: str = "basic",
    ) -> None:
        self._stdout = stdout if stdout is not None else sys.stdout
        self._stderr = stderr if stderr is not None else sys.stderr
        self.quiet = quiet
        self.style = "basic" if quiet else style
        environ = os.environ if env is None else env
        tty = self._stdout.isatty() if hasattr(self._stdout, "isatty") else False
        if color is None:
            color = tty and not environ.get("NO_COLOR")
        self.color = bool(color)
        self.glyphs = UNICODE_GLYPHS if _encodes_unicode(self._stdout) else ASCII_GLYPHS
        # A live spinner only makes sense on a real terminal. Pipes and tee
        # get the basic log even when the requested style is rich.
        self._live = self.style == "rich" and tty and not quiet
        self._rich: Optional[RichConsole] = None
        self._status: Optional[Status] = None
        self._tasks: List["_Task"] = []
        self._active: Optional[int] = None
        self._detail = ""
        self._detail_started = 0.0
        self._title = ""
        self._title_done = False
        # Reused so a refresh does not restart the animation on frame one.
        self._spinners: dict = {}
        self._task_live: Optional[Live] = None
        if self._live:
            # soft_wrap lets the terminal wrap a line Rich counted as one,
            # and the live region then leaves the previous frame behind.
            self._rich = RichConsole(
                file=self._stdout,
                highlight=False,
                soft_wrap=False,
                no_color=not self.color,
            )

    # -- primitives ---------------------------------------------------------

    def _paint(self, text: str, color: Optional[str]) -> str:
        if not self.color or color is None:
            return text
        return f"{_COLORS[color]}{text}{_RESET}"

    def _write(self, stream: IO[str], text: str, color: Optional[str]) -> None:
        """Write one line and flush it.

        The flush matters when stdout is not a TTY: Python would otherwise
        block-buffer a long deploy until the process exits.
        """
        if self.quiet:
            return
        if self._rich is not None and stream is self._stdout:
            self._rich_print(text, color)
            return
        stream.write(self._paint(text, color) + "\n")
        try:
            stream.flush()
        except (AttributeError, ValueError):  # pragma: no cover - closed stream
            pass

    def _rich_print(self, text: str, color: Optional[str]) -> None:
        assert self._rich is not None
        if "\033" in text:
            self._rich.print(Text.from_ansi(text), soft_wrap=True)
            return
        styles = {
            "red": "red",
            "green": "green",
            "teal": ANSIBLE_TEAL,
            "yellow": "yellow",
            "bold": "bold",
            "dim": "dim",
        }
        style = styles.get(color or "")
        self._rich.print(text, style=style, highlight=False, markup=False, soft_wrap=True)

    def _ensure_status(self, text: str) -> None:
        if self._rich is None or self._tasks:
            return
        if self._status is None:
            self._status = Status(
                text,
                console=self._rich,
                spinner="dots",
                spinner_style=f"bold {ANSIBLE_TEAL}",
            )
            self._status.start()
        else:
            self._status.update(text)

    def _stop_status(self) -> None:
        if self._status is None:
            return
        self._status.stop()
        self._status = None

    def _spinner(self, key: str) -> Spinner:
        spinner = self._spinners.get(key)
        if spinner is None:
            spinner = Spinner("dots", style=_TEAL_BOLD)
            self._spinners[key] = spinner
        return spinner

    def _parent_cells(self) -> Tuple[object, object]:
        if self._title_done:
            return (
                Text(self.glyphs["ok"], style=ANSIBLE_TEAL),
                Text(self._title, style=ANSIBLE_TEAL),
            )
        return (self._spinner("parent"), Text(self._title, style=ANSIBLE_TEAL))

    def _timed_label(self, task: "_Task", text: str, *, style: str) -> Text:
        label = Text(text, style=style)
        if not task.timed or not task.started:
            return label
        seconds = task.elapsed if task.state == "done" else time.monotonic() - task.started
        label.append(f"  {format_elapsed(seconds)}", style=ANSIBLE_TEAL)
        return label

    def _task_mark(self, task: "_Task") -> Tuple[object, object]:
        if task.state == "done":
            # Finished steps stay primary teal, and they are not bold.
            return (
                Text(self.glyphs["ok"], style=ANSIBLE_TEAL),
                self._timed_label(task, task.note or task.title, style=ANSIBLE_TEAL),
            )
        if task.state == "failed":
            return (
                Text(self.glyphs["fail"], style="red"),
                Text(task.note or task.title, style="red"),
            )
        if task.state == "active":
            return (
                self._spinner("active"),
                self._timed_label(task, task.title, style=_TEAL_BOLD),
            )
        box = "☐" if self.glyphs is UNICODE_GLYPHS else "[ ]"
        return (Text(box, style="dim"), Text(task.title, style="dim"))

    def _render_tasks(self) -> Group:
        """The whole checklist, parent included, so finished rows stay put.

        Printing a finished row above the live region changes its height while
        the refresh thread is drawing. A long wait (NFS) then leaves spinner
        frames in the scrollback. Rows stay in this renderable instead.
        """
        sub = Table.grid(padding=(0, 1))
        sub.add_column(width=2, justify="center")
        sub.add_column()
        for index, task in enumerate(self._tasks):
            mark, label = self._task_mark(task)
            sub.add_row(mark, label)
            for note in task.notes:
                sub.add_row("", self._nested_line(note))
            for child in task.children:
                sub.add_row("", self._child_line(child))
            if (
                index == self._active
                and self._detail
                and task.state == "active"
                and not task.children
            ):
                sub.add_row("", self._nested_line(self._detail, animate=True))
        body = Padding(sub, (0, 0, 0, len(_TASK_INDENT)))
        if not self._title:
            return Group(body)
        parent = Table.grid(padding=(0, 1))
        parent.add_column(width=2, justify="center")
        parent.add_column()
        parent.add_row(*self._parent_cells())
        return Group(parent, body)

    def _refresh_tasks(self) -> None:
        if self._task_live is not None:
            self._task_live.refresh()

    def _pause_live_refresh(self) -> bool:
        """Stop the checklist's refresh thread.

        Returns True only when this caller is now the only painter. A second
        thread calling refresh at the same time leaves the cursor mid-line,
        and the spinner looks like it never started.
        """
        live = self._task_live
        if live is None:
            return False
        thread = getattr(live, "_refresh_thread", None)
        if thread is None:
            return True
        thread.stop()
        thread.join(timeout=0.5)
        if thread.is_alive():
            return False
        live._refresh_thread = None
        return True

    def _resume_live_refresh(self) -> None:
        live = self._task_live
        if live is None or not getattr(live, "_started", False):
            return
        if getattr(live, "_refresh_thread", None) is not None:
            return
        if not getattr(live, "auto_refresh", False):
            return
        from rich.live import _RefreshThread

        live._refresh_thread = _RefreshThread(live, live.refresh_per_second)
        live._refresh_thread.start()

    def paint_while(self, func: Callable[[], _T]) -> _T:
        """Run ``func`` on a worker and keep the checklist spinner moving.

        Clean's long ``kubectl`` calls leave the refresh thread free, so the
        spinner animates. ``crc delete`` is the call that does not: it takes
        the terminal, and the refresh thread stops drawing. Pausing that
        thread and painting from here keeps a single writer for the whole wait.
        """
        if self._task_live is None:
            return func()
        paused = self._pause_live_refresh()
        box: dict = {}

        def worker() -> None:
            try:
                box["result"] = func()
            except BaseException as exc:  # noqa: BLE001 - re-raised on this thread
                box["error"] = exc

        thread = threading.Thread(target=worker, name="aap-demo-paint")
        thread.start()
        try:
            while thread.is_alive():
                if paused:
                    self._refresh_tasks()
                thread.join(1 / 12)
        finally:
            thread.join()
            if paused:
                self._resume_live_refresh()
        if "error" in box:
            raise box["error"]
        return box["result"]

    def _stop_task_live(self) -> None:
        if self._task_live is None:
            return
        self._refresh_tasks()
        self._task_live.stop()
        self._task_live = None

    def _complete_active(self, *, note: str = "") -> None:
        if self._active is None:
            return
        task = self._tasks[self._active]
        if task.state == "active":
            task.state = "done"
            task.note = note or task.title
            # The component list is only for the live wait. Checking the parent
            # off collapses it.
            task.children = []
            if task.timed and task.started:
                task.elapsed = time.monotonic() - task.started
        self._detail = ""
        self._active = None

    def finish(self) -> None:
        """Drop the live view so the shell prompt is not left on that line."""
        if self._active is not None and self._tasks[self._active].state == "active":
            self._tasks[self._active].state = "failed"
            self._refresh_tasks()
        self._stop_task_live()
        self._stop_status()

    def out(self, text: str = "", *, color: Optional[str] = None) -> None:
        self._write(self._stdout, text, color)

    def err(self, text: str = "", *, color: Optional[str] = None) -> None:
        self._write(self._stderr, text, color)

    def paint(self, text: str, color: Optional[str]) -> str:
        """Color a *fragment* of a line the caller assembles itself.

        Bash colors single tokens inside otherwise-plain lines (``status``'s
        cluster-state word, the AAP CR name in a padded namespace row). Doing
        that through ``out(..., color=...)`` would color the whole line and,
        worse, shift padded columns; this keeps the escape codes inside
        ``console.py`` (§2.2) while the caller owns the layout.
        """
        return self._paint(text, color)

    # -- report body --------------------------------------------------------

    #: Severity → color for :meth:`report` lines.
    REPORT_COLORS = {"ok": "green", "fail": "red", "warn": "yellow", "info": None}

    def report(self, text: str, *, status: str = "plain", indent: int = 0) -> None:
        """One line of *report body* — always stdout, whatever the severity.

        ``failure()``/``warn()`` write to stderr because they report actual
        error conditions. A ``status``/``diagnose``/``redhat-status`` line is
        content, not an error: bash printed every one of them to stdout, and
        routing them by severity splits a single report across two streams
        with no ordering guarantee between them. ``status`` in ("ok", "fail",
        "warn", "info") prefixes the matching glyph; anything else prints the
        text bare (bash's un-glyphed report lines).
        """
        prefix = " " * indent
        glyph = self.glyphs.get(status)
        body = f"{glyph} {text}" if glyph else text
        self.out(prefix + body, color=self.REPORT_COLORS.get(status))

    # -- semantic wrappers --------------------------------------------------

    def tasks(self, steps: Sequence[str], *, title: str = "") -> None:
        """Show the known steps. Later ``step`` calls check them off in order.

        ``title`` is the top-level task. It stays above the steps and checks
        off from :meth:`finish_checklist`.
        """
        if self.quiet:
            return
        self._stop_status()
        self._stop_task_live()
        self._title = title
        self._title_done = False
        self._spinners = {}
        self._tasks = [_Task(step) for step in steps if step]
        self._active = None
        self._detail = ""
        if self._rich is None:
            if title:
                self.out(title)
            return
        if not self._tasks and not title:
            return
        self._task_live = Live(
            get_renderable=self._render_tasks,
            console=self._rich,
            refresh_per_second=12,
            transient=False,
            auto_refresh=True,
            vertical_overflow="visible",
        )
        self._task_live.start(refresh=True)

    def task_states(self) -> List[tuple]:
        return [(task.title, task.state) for task in self._tasks]

    def checkpoint(self, text: str) -> None:
        """Check off the active step. The note stays on the basic log."""
        if self.quiet:
            return
        self._complete_active(note=text)
        self._refresh_tasks()
        if self._task_live is not None:
            self._task_live.refresh()
            return
        self.out(f"{self.glyphs['ok']} {text}", color="teal")

    def cancel_step(self) -> None:
        """Drop the active step. Nothing finished, so it is not checked off."""
        if self.quiet or self._active is None:
            return
        self._tasks.pop(self._active)
        self._active = None
        self._detail = ""
        self._refresh_tasks()

    def finish_checklist(self) -> None:
        """Check off the top-level task and leave the finished list in place."""
        if self.quiet:
            return
        self._title_done = True
        self._refresh_tasks()
        if self._task_live is not None:
            self._task_live.refresh()
        self._stop_task_live()
        self._stop_status()
        # Later steps must not attach themselves to this finished list.
        self._tasks = []
        self._active = None
        self._detail = ""

    def next_steps(self, actions: Sequence[Tuple[str, str]]) -> None:
        """What to run after a checklist, in place of a closing banner."""
        if self.quiet or not actions:
            return
        width = max(len(command) for command, _description in actions)
        self.out("")
        self.out("Next:")
        for command, description in actions:
            self.out(f"  {command:<{width}}  {description}")
        self.out("")

    def success(self, text: str) -> None:
        showed = self._active is not None and self._task_live is not None
        self._complete_active(note=text)
        self._tasks = [task for task in self._tasks if task.state != "pending"]
        self._refresh_tasks()
        self._stop_task_live()
        self._stop_status()
        if not showed:
            self.out(f"{self.glyphs['ok']} {text}", color="teal")

    def failure(self, text: str) -> None:
        """A genuine error condition — stderr. Report content uses ``report()``."""
        if self._active is not None and self._tasks[self._active].state == "active":
            self._tasks[self._active].state = "failed"
            self._refresh_tasks()
        self._stop_task_live()
        self._stop_status()
        self.err(f"{self.glyphs['fail']} {text}", color="red")

    def warn(self, text: str) -> None:
        """A genuine warning. Above the live spinner when one is running, otherwise stderr."""
        if self.quiet:
            return
        line = f"{self.glyphs['warn']} {text}"
        if self._rich is not None and (self._status is not None or self._task_live is not None):
            self._rich_print(line, "yellow")
            return
        self.err(line, color="yellow")

    def info(self, text: str) -> None:
        self.out(f"{self.glyphs['info']} {text}")

    def set_children(self, rows: Sequence[Tuple[str, str, str]]) -> None:
        """Nested component rows on the active step.

        Each row is ``(title, state, detail)`` with state ``active``, ``done``,
        ``failed``, or ``pending``. Finished rows stay visible until the parent
        step is checked off, which collapses the list.
        """
        if self.quiet or self._active is None:
            return
        task = self._tasks[self._active]
        now = time.monotonic()
        previous = {child.title: child for child in task.children}
        children: List[_Child] = []
        for title, state, detail in rows:
            started = now
            prior = previous.get(title)
            if prior is not None and prior.state == state:
                started = prior.started
            children.append(_Child(title, state, detail, started))
        task.children = children
        self._detail = ""
        self._refresh_tasks()

    def progress(self, text: str) -> None:
        """Update the live step in place.

        A repeating wait must not print a new line on every tick. The checklist
        detail or the status spinner shows the latest text, and a plain log
        prints a line only when the text changes.
        """
        if self.quiet or not text:
            return
        changed = text != self._detail
        if changed:
            self._detail_started = time.monotonic()
        self._detail = text
        if self._task_live is not None:
            if self._active is not None:
                self._refresh_tasks()
            return
        if not changed:
            return
        if self._live:
            self._ensure_status(text)
            return
        self.info(text)

    def step(self, text: str, *, timed: bool = False) -> None:
        if self.quiet:
            return
        if self._tasks:
            self._complete_active()
            index = next((i for i, task in enumerate(self._tasks) if task.title == text), None)
            if index is None:
                self._tasks.append(_Task(text))
                index = len(self._tasks) - 1
            task = self._tasks[index]
            task.state = "active"
            if timed:
                task.timed = True
                task.started = time.monotonic()
            self._active = index
            self._detail = ""
            # Paint the spinner before the next blocking command.
            self._refresh_tasks()
            if self._task_live is not None:
                return
        if self._live:
            self._ensure_status(text)
            return
        self.out(text, color="bold")

    def _nest_chars(self) -> Tuple[str, str]:
        if self.glyphs is UNICODE_GLYPHS:
            return _NEST_MARK
        return _NEST_MARK_ASCII

    def _child_mark(self) -> str:
        return "".join(self._nest_chars())

    def _child_line(self, child: _Child) -> object:
        """One component under the active step: a check, a spinner, or a box."""
        detail = f"  {child.detail}" if child.detail else ""
        if child.state == "done":
            line = Text("  ")
            line.append(f"{self.glyphs['ok']} ", style=ANSIBLE_TEAL)
            line.append(child.title, style=ANSIBLE_TEAL)
            if detail:
                line.append(detail, style=ANSIBLE_TEAL_DARK)
            return line
        if child.state == "failed":
            line = Text("  ")
            line.append(f"{self.glyphs['fail']} ", style="red")
            line.append(child.title + detail, style="red")
            return line
        if child.state == "active":
            return _NestedFlash(
                f"{child.title}{detail}",
                self._nest_chars(),
                started=child.started,
            )
        box = "☐" if self.glyphs is UNICODE_GLYPHS else "[ ]"
        return Text(f"  {box} {child.title}{detail}", style="dim")

    def _child_note(self, text: str) -> str:
        """Label-column text for a line that belongs to the step above it."""
        return f"  {self._child_mark()} {text}"

    def _nested_line(self, text: str, *, animate: bool = False) -> object:
        """A short shade ramp, then the detail in the dark teal.

        The active detail animates: one bold primary character walks the ramp
        and then the words. A stored note keeps the resting ramp.
        """
        marks = self._nest_chars()
        if animate:
            return _NestedFlash(text, marks, started=self._detail_started)
        line = Text("  ")
        for glyph, color in zip(marks, _NEST_COLORS):
            line.append(glyph, style=color)
        line.append(f" {text}", style=ANSIBLE_TEAL_DARK)
        return line

    def note(self, text: str) -> None:
        """A dark child of the active step, not its own step."""
        if self.quiet or not text:
            return
        if self._task_live is not None and self._active is not None:
            self._tasks[self._active].notes.append(text)
            self._refresh_tasks()
            return
        # Checklist pad, the mark column, and the gap before the title.
        gutter = len(_TASK_INDENT) + 2 + 1
        self.out(f"{' ' * gutter}{self._child_note(text)}", color="teal_dim")

    def detail(self, text: str) -> None:
        self.out(f"  {text}", color="dim")

    def subprocess_line(self, text: str) -> None:
        """One line of child-process output (``crc start``, ``crc setup``).

        CRC's logrus lines and its ``oc`` usage banner are rewritten so they
        don't break the step list. Errors stay visible; info stays dim.
        """
        if self.quiet:
            return
        stripped = text.strip()
        if _crc_noise(stripped):
            return
        match = _CRC_LOG.match(stripped)
        if match is None:
            self._crc_info(stripped)
            return
        message = match.group("msg")
        # CRC prints preflight as ``level=info msg="Checking ..."``. The check
        # has to run on the extracted message, or both setup and start replay it.
        if _crc_noise(message):
            return
        if match.group("level") in {"error", "fatal", "warning", "warn"}:
            self.warn(message)
            return
        self._crc_info(message)

    def _crc_info(self, message: str) -> None:
        """Fold CRC narration into the active check. Otherwise keep one dim line."""
        if self._tasks and self._active is not None:
            self.progress(_crc_status(message))
            return
        self.out(message, color="dim")

    def log_sink(self) -> "_LogSink":
        return _LogSink(self)

    def notice(self, text: str) -> None:
        """The disclaimer banner — suppressed by QUIET (bash ``show_welcome``)."""
        if self.quiet:
            return
        self.err(text, color="yellow")

    def error(self, message: str, *, hint: Optional[str] = None) -> None:
        self.failure(message)
        if hint:
            for line in hint.splitlines():
                self.err(f"  {line}")


class _LogSink:
    """Adapter so ``CommandRunner`` streaming can call ``sink.log``."""

    def __init__(self, console: Console) -> None:
        self._console = console

    def log(self, text: str) -> None:
        self._console.subprocess_line(text)


class RecordingConsole(Console):
    """Test double: keeps everything written, writes nowhere."""

    def __init__(self, *, quiet: bool = False) -> None:
        super().__init__(quiet=quiet, style="basic")
        self._live = False
        self._rich = None
        self._status = None
        self.stdout_lines: List[str] = []
        self.stderr_lines: List[str] = []
        self.quiet = quiet
        self.color = False
        self.glyphs = ASCII_GLYPHS

    def out(self, text: str = "", *, color: Optional[str] = None) -> None:
        if self.quiet:
            return
        self.stdout_lines.append(text)

    def err(self, text: str = "", *, color: Optional[str] = None) -> None:
        if self.quiet:
            return
        self.stderr_lines.append(text)

    @property
    def stdout(self) -> str:
        return "\n".join(self.stdout_lines)

    @property
    def stderr(self) -> str:
        return "\n".join(self.stderr_lines)
