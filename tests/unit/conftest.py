"""Keeps unit tests away from the tools installed on the developer's machine."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

#: The only programs a unit test may really run. Anything else could change the
#: machine. ``crc``, for one, shells out to ``/usr/bin/security``, and on macOS
#: that can raise a Keychain dialog.
_ALLOWED = frozenset({"bash", "git", "openssl", Path(sys.executable).name})

#: Stand-ins that fail, ahead of the real tools on PATH. They stop what an allowed
#: program, such as a bash script under test, starts on its own.
_STUBBED = ("crc", "kubectl", "oc", "podman", "security", "ssh", "sudo")

_RealPopen = subprocess.Popen


class _GuardedPopen(_RealPopen):  # type: ignore[type-arg]
    """Treat every other installed program as missing, on every machine."""

    def __init__(self, args: Any, *pargs: Any, **kwargs: Any) -> None:
        program = str(args if isinstance(args, (str, Path)) else args[0])
        allowed = program == sys.executable or Path(program).name in _ALLOWED
        if shutil.which(program) and not allowed:
            raise FileNotFoundError(2, "blocked in unit tests", program)
        super().__init__(args, *pargs, **kwargs)


@pytest.fixture(scope="session")
def _stub_dir(tmp_path_factory: pytest.TempPathFactory) -> Path:
    directory = tmp_path_factory.mktemp("stubbed-tools")
    for name in _STUBBED:
        stub = directory / name
        stub.write_text("#!/bin/sh\nexit 127\n", encoding="utf-8")
        stub.chmod(0o755)
    return directory


@pytest.fixture(autouse=True)
def _no_host_tools(monkeypatch: pytest.MonkeyPatch, _stub_dir: Path) -> None:
    monkeypatch.setenv("PATH", f"{_stub_dir}{os.pathsep}{os.environ.get('PATH', '')}")
    # subprocess.run and check_output look Popen up here, so this also covers
    # code that does not go through SubprocessRunner.
    monkeypatch.setattr(subprocess, "Popen", _GuardedPopen)
