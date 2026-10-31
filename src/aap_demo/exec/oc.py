"""Run ``oc`` against the aap-demo kubeconfig.

``aap-demo oc cluster-info`` is ``oc cluster-info`` with ``KUBECONFIG`` set to
the state file. The process is replaced, the same way ``aap-demo ssh``
replaces itself with ``ssh``, so a terminal session and ``oc``'s exit code
pass through unchanged.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Mapping, Optional, Sequence

from aap_demo.core.errors import AapDemoError, PrerequisiteError
from aap_demo.core.paths import display_path


def exec_oc(
    kubeconfig: Path,
    args: Sequence[str],
    *,
    env: Optional[Mapping[str, str]] = None,
    exec_func: Callable[..., Any] = os.execvpe,
    run_func: Callable[..., Any] = subprocess.run,
    exit_func: Callable[[int], Any] = sys.exit,
    is_windows: Optional[bool] = None,
) -> None:
    """Replace this process with ``oc`` using ``kubeconfig`` as ``KUBECONFIG``."""
    child_env = dict(os.environ if env is None else env)
    if not kubeconfig.is_file():
        home = Path(child_env.get("HOME") or Path.home())
        raise AapDemoError(
            f"Kubeconfig not found: {display_path(kubeconfig, home)}",
            hint="Run 'aap-demo create' or 'aap-demo kubeconfig' first.",
        )
    child_env["KUBECONFIG"] = str(kubeconfig)
    argv = ["oc", *args]
    windows = os.name == "nt" if is_windows is None else is_windows
    if windows:
        try:
            completed = run_func(argv, env=child_env)  # noqa: S603 - argv list, inherited stdio
        except FileNotFoundError as exc:
            raise PrerequisiteError(
                "oc not found",
                hint="Install the OpenShift CLI and make sure it is on PATH.",
            ) from exc
        exit_func(int(completed.returncode))
        return
    try:
        exec_func(argv[0], argv, child_env)  # noqa: S606 - documented exec-bypass, same as ssh
    except FileNotFoundError as exc:
        raise PrerequisiteError(
            "oc not found",
            hint="Install the OpenShift CLI and make sure it is on PATH.",
        ) from exc
