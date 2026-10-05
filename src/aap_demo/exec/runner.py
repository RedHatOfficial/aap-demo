"""The single subprocess seam (design §2.2, §7.2).

Only this module may call ``subprocess``. Everything else takes a
``CommandRunner``. That is what makes "did we grant the SCCs before the first
pod-creating apply?" a one-line assertion, and it is the single place Windows
quoting, timeouts, and environment propagation are handled. ``shell=True`` is
never used, so no quoting divergence arises across platforms (§6.1).
"""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass, field
from typing import (
    Any,
    Callable,
    Dict,
    List,
    Mapping,
    Optional,
    Protocol,
    Sequence,
    Tuple,
    Union,
)

from aap_demo.core.errors import AapDemoError, PrerequisiteError


@dataclass(frozen=True)
class CompletedCommand:
    argv: Tuple[str, ...]
    returncode: int
    stdout: str = ""
    stderr: str = ""

    @property
    def ok(self) -> bool:
        return self.returncode == 0

    def check(self) -> "CompletedCommand":
        if not self.ok:
            raise CommandFailed(self)
        return self


class CommandFailed(AapDemoError):
    def __init__(self, result: CompletedCommand) -> None:
        super().__init__(
            f"command failed (exit {result.returncode}): {' '.join(result.argv)}",
            hint=(result.stderr or result.stdout or "").strip() or None,
        )
        self.result = result


class CommandRunner(Protocol):
    def run(
        self,
        argv: Sequence[str],
        *,
        input: Optional[str] = None,
        timeout: Optional[float] = None,
        env: Optional[Mapping[str, str]] = None,
        check: bool = False,
        capture: bool = True,
        cwd: Optional[str] = None,
        sink: Optional[Any] = None,
        detach: bool = False,
    ) -> CompletedCommand: ...


class SubprocessRunner:
    def __init__(self, *, base_env: Optional[Mapping[str, str]] = None) -> None:
        self._base_env = dict(base_env) if base_env is not None else None

    def _env_for(self, env: Optional[Mapping[str, str]]) -> Optional[Dict[str, str]]:
        if env is None and self._base_env is None:
            return None
        merged = dict(self._base_env if self._base_env is not None else os.environ)
        if env:
            merged.update(env)
        return merged

    def run(
        self,
        argv: Sequence[str],
        *,
        input: Optional[str] = None,
        timeout: Optional[float] = None,
        env: Optional[Mapping[str, str]] = None,
        check: bool = False,
        capture: bool = True,
        cwd: Optional[str] = None,
        sink: Optional[Any] = None,
        detach: bool = False,
    ) -> CompletedCommand:
        args = [str(a) for a in argv]
        if sink is not None:
            result = self._run_streaming(
                args, env=env, cwd=cwd, sink=sink, timeout=timeout, detach=detach
            )
        else:
            result = self._run_captured(
                args,
                input=input,
                timeout=timeout,
                env=env,
                capture=capture,
                cwd=cwd,
                detach=detach,
            )
        if check:
            result.check()
        return result

    def _run_captured(
        self,
        args: List[str],
        *,
        input: Optional[str],
        timeout: Optional[float],
        env: Optional[Mapping[str, str]],
        capture: bool,
        cwd: Optional[str],
        detach: bool = False,
    ) -> CompletedCommand:
        try:
            # A detached child must not read the terminal. Otherwise crc delete
            # waits for a second Enter and the checklist never appears.
            proc = subprocess.run(  # noqa: S603 - argv list, never shell=True
                args,
                input=input,
                stdin=subprocess.DEVNULL if detach and input is None else None,
                capture_output=capture,
                text=True,
                timeout=timeout,
                env=self._env_for(env),
                cwd=cwd,
                start_new_session=detach,
            )
        except FileNotFoundError as exc:
            raise PrerequisiteError(
                f"required command not found: {args[0]}",
                hint=f"Install {args[0]} and make sure it is on PATH.",
            ) from exc
        except subprocess.TimeoutExpired as exc:
            raise AapDemoError(f"command timed out after {timeout}s: {' '.join(args)}") from exc
        return CompletedCommand(
            argv=tuple(args),
            returncode=proc.returncode,
            stdout=proc.stdout or "",
            stderr=proc.stderr or "",
        )

    def _run_streaming(
        self,
        args: List[str],
        *,
        env: Optional[Mapping[str, str]],
        cwd: Optional[str],
        sink: Any,
        timeout: Optional[float],
        detach: bool = False,
    ) -> CompletedCommand:
        """Line-by-line stdout/stderr as ``kind="log"`` events (§9.4)."""
        lines: List[str] = []
        try:
            proc = subprocess.Popen(  # noqa: S603 - argv list, never shell=True
                args,
                stdin=subprocess.DEVNULL if detach else None,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env=self._env_for(env),
                cwd=cwd,
                start_new_session=detach,
            )
        except FileNotFoundError as exc:
            raise PrerequisiteError(
                f"required command not found: {args[0]}",
                hint=f"Install {args[0]} and make sure it is on PATH.",
            ) from exc

        assert proc.stdout is not None
        for line in proc.stdout:
            text = line.rstrip("\n")
            lines.append(text)
            sink.log(text)
        proc.wait(timeout=timeout)
        return CompletedCommand(
            argv=tuple(args), returncode=proc.returncode, stdout="\n".join(lines)
        )


@dataclass
class EnvRunner:
    """Wraps a runner so every call carries a fixed environment overlay.

    This is how bash's ``export KUBECONFIG=...`` (``setup_kubeconfig``,
    aap-demo.sh:264) survives the port: the preflight resolves the kubeconfig
    once and wraps ``ctx.runner``, so every later ``kubectl``/``oc``/``ssh``
    call sees it without threading an ``env=`` argument through every call
    site. A per-call ``env`` still wins over the overlay.
    """

    inner: Any
    env: Dict[str, str]

    def run(
        self,
        argv: Sequence[str],
        *,
        input: Optional[str] = None,
        timeout: Optional[float] = None,
        env: Optional[Mapping[str, str]] = None,
        check: bool = False,
        capture: bool = True,
        cwd: Optional[str] = None,
        sink: Optional[Any] = None,
        detach: bool = False,
    ) -> CompletedCommand:
        merged = dict(self.env)
        if env:
            merged.update(env)
        return self.inner.run(
            argv,
            input=input,
            timeout=timeout,
            env=merged,
            check=check,
            capture=capture,
            cwd=cwd,
            sink=sink,
            detach=detach,
        )


Result = Union[CompletedCommand, Callable[..., CompletedCommand], BaseException]


@dataclass
class Invocation:
    argv: Tuple[str, ...]
    input: Optional[str] = None
    env: Optional[Dict[str, str]] = None
    cwd: Optional[str] = None
    timeout: Optional[float] = None


@dataclass
class FakeRunner:
    """Test double registered as ``argv-prefix-pattern -> result``.

    Any invocation with no registered match **fails the test**. That is the whole
    point: an unexpected command is a defect, not something to shrug at, and it
    is the SCC-grant-timing class of bug ADR-010 flagged as a drift risk.
    """

    _rules: List[Tuple[Tuple[str, ...], Result]] = field(default_factory=list)
    calls: List[Invocation] = field(default_factory=list)

    def register(self, pattern: Union[str, Sequence[str]], result: Result) -> "FakeRunner":
        prefix = tuple(pattern.split()) if isinstance(pattern, str) else tuple(pattern)
        self._rules.append((prefix, result))
        return self

    def ok(self, pattern: Union[str, Sequence[str]], stdout: str = "") -> "FakeRunner":
        prefix = tuple(pattern.split()) if isinstance(pattern, str) else tuple(pattern)
        return self.register(prefix, CompletedCommand(argv=prefix, returncode=0, stdout=stdout))

    def fail(
        self, pattern: Union[str, Sequence[str]], returncode: int = 1, stderr: str = ""
    ) -> "FakeRunner":
        prefix = tuple(pattern.split()) if isinstance(pattern, str) else tuple(pattern)
        return self.register(
            prefix, CompletedCommand(argv=prefix, returncode=returncode, stderr=stderr)
        )

    def _match(self, args: Tuple[str, ...]) -> Result:
        for prefix, result in self._rules:
            if _matches(args, prefix):
                return result
        raise AssertionError(
            "FakeRunner: unregistered command: "
            + " ".join(args)
            + "\nregistered prefixes: "
            + "; ".join(" ".join(p) for p, _ in self._rules)
        )

    def run(
        self,
        argv: Sequence[str],
        *,
        input: Optional[str] = None,
        timeout: Optional[float] = None,
        env: Optional[Mapping[str, str]] = None,
        check: bool = False,
        capture: bool = True,
        cwd: Optional[str] = None,
        sink: Optional[Any] = None,
        detach: bool = False,
    ) -> CompletedCommand:
        del detach
        args = tuple(str(a) for a in argv)
        self.calls.append(
            Invocation(
                argv=args,
                input=input,
                env=dict(env) if env else None,
                cwd=cwd,
                timeout=timeout,
            )
        )
        result = self._match(args)
        if isinstance(result, BaseException):
            raise result
        if callable(result):
            result = result(args)
        result = CompletedCommand(
            argv=args,
            returncode=result.returncode,
            stdout=result.stdout,
            stderr=result.stderr,
        )
        if sink is not None:
            for line in result.stdout.splitlines():
                sink.log(line)
        if check:
            result.check()
        return result

    # -- assertions ---------------------------------------------------------

    @property
    def commands(self) -> List[str]:
        return [" ".join(call.argv) for call in self.calls]

    def called(self, pattern: Union[str, Sequence[str]]) -> bool:
        prefix = tuple(pattern.split()) if isinstance(pattern, str) else tuple(pattern)
        return any(_matches(call.argv, prefix) for call in self.calls)

    def index_of(self, pattern: Union[str, Sequence[str]]) -> int:
        prefix = tuple(pattern.split()) if isinstance(pattern, str) else tuple(pattern)
        for i, call in enumerate(self.calls):
            if _matches(call.argv, prefix):
                return i
        raise AssertionError(f"FakeRunner: never called: {' '.join(prefix)}")


def _matches(args: Tuple[str, ...], prefix: Tuple[str, ...]) -> bool:
    """Prefix match with ``*`` as a single-token wildcard."""
    if len(prefix) > len(args):
        return False
    for actual, expected in zip(args, prefix):
        if expected == "*":
            continue
        if expected.startswith("~"):
            if not re.search(expected[1:], actual):
                return False
            continue
        if actual != expected:
            return False
    return True
