from __future__ import annotations

import os
from pathlib import Path

import pytest

from aap_demo.core import config as config_mod
from aap_demo.core.console import RecordingConsole
from aap_demo.core.context import AppContext
from aap_demo.core.events import EventEmitter, ListSink
from aap_demo.core.paths import Paths
from aap_demo.core.secrets import InMemorySecretStore
from aap_demo.exec.runner import FakeRunner

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def fixtures_dir() -> Path:
    return FIXTURES


@pytest.fixture
def fake_runner() -> FakeRunner:
    return FakeRunner()


@pytest.fixture
def tmp_paths(tmp_path: Path) -> Paths:
    """Isolated XDG-style roots, without touching the real user directories."""
    return Paths(
        config_dir=tmp_path / "config",
        cache_dir=tmp_path / "cache",
        state_dir=tmp_path / "state",
        legacy_dir=tmp_path / "home" / ".aap-demo",
        collapsed=False,
    )


@pytest.fixture
def clean_env(monkeypatch: pytest.MonkeyPatch) -> dict:
    """An environment with every aap-demo variable removed."""
    from aap_demo.core import schema

    for var in list(schema.env_map()) + [
        "AAP_DEMO_DIR",
        "AAP_DEMO_CONFIG",
        "AAP_DEMO_KUBECONFIG",
        "AAP_DEMO_SKIP_MIGRATION",
        "KUBECONFIG",
    ]:
        monkeypatch.delenv(var, raising=False)
    return dict(os.environ)


@pytest.fixture
def app_ctx(tmp_paths: Paths, fake_runner: FakeRunner) -> AppContext:
    config = config_mod.resolve(env={}, path=tmp_paths.config_file)
    console = RecordingConsole()
    ctx = AppContext(
        config=config,
        paths=tmp_paths,
        console=console,
        runner=fake_runner,
        secrets=InMemorySecretStore(),
        env={},
    )
    ctx.events = EventEmitter(sink=ListSink())
    return ctx
