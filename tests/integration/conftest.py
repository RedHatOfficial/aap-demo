"""Live-cluster fixtures (design §7.3 — the ``integration`` marker).

Every test in this package needs a real CRC/MicroShift cluster. None of them
may *fail* when one is absent: ``pyproject.toml`` deselects the marker by
default, and a developer who runs ``pytest -m integration`` with no cluster
should get skips, not red. The reachability probe below is therefore the first
thing every fixture does.

The kubeconfig comes from ``AAP_DEMO_TEST_KUBECONFIG`` when set, otherwise
from the same discovery order the tool itself uses.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Optional

import pytest

from aap_demo.core import config as config_mod
from aap_demo.core.console import RecordingConsole
from aap_demo.core.context import AppContext
from aap_demo.core.events import EventEmitter, ListSink
from aap_demo.core.paths import resolve_paths
from aap_demo.core.secrets import InMemorySecretStore
from aap_demo.exec.runner import EnvRunner, SubprocessRunner

#: Namespace the destructive tests are allowed to touch. Deliberately not the
#: default ``aap-operator``: an integration run must not delete a deployment a
#: developer is using.
TEST_NAMESPACE = "aap-demo-itest"


def _kubeconfig() -> Optional[Path]:
    explicit = os.environ.get("AAP_DEMO_TEST_KUBECONFIG") or os.environ.get("KUBECONFIG")
    if explicit:
        path = Path(explicit).expanduser()
        return path if path.is_file() else None
    for candidate in (
        Path.home() / ".aap-demo" / "kubeconfig.microshift",
        resolve_paths().kubeconfig,
    ):
        if candidate.is_file():
            return candidate
    return None


@pytest.fixture(scope="session")
def live_kubeconfig() -> Path:
    if shutil.which("kubectl") is None:
        pytest.skip("kubectl is not installed")
    path = _kubeconfig()
    if path is None:
        pytest.skip("no kubeconfig found — set AAP_DEMO_TEST_KUBECONFIG")
    probe = SubprocessRunner().run(
        ["kubectl", "get", "nodes", "-o", "name", "--request-timeout=5s"],
        env={**os.environ, "KUBECONFIG": str(path)},
    )
    if not probe.ok:
        pytest.skip(f"cluster at {path} is not reachable")
    return path


@pytest.fixture
def live_ctx(live_kubeconfig: Path, tmp_path: Path) -> AppContext:
    """An ``AppContext`` wired to the real cluster and a throwaway config root.

    ``paths`` point at ``tmp_path`` so a test run never writes to the
    developer's real config, cache or state directories.
    """
    paths = resolve_paths({"AAP_DEMO_DIR": str(tmp_path / "aap-demo")})
    env = {**os.environ, "KUBECONFIG": str(live_kubeconfig)}
    ctx = AppContext(
        config=config_mod.resolve(env={}, path=paths.config_file),
        paths=paths,
        console=RecordingConsole(),
        runner=EnvRunner(SubprocessRunner(), {"KUBECONFIG": str(live_kubeconfig)}),
        secrets=InMemorySecretStore(),
        env=env,
    )
    ctx.events = EventEmitter(sink=ListSink())
    return ctx
