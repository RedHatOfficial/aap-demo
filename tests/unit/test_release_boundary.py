"""The v2 beta stays 2.0.0.devN and does not publish 2.0.0."""

from __future__ import annotations

import importlib.util
import io
import re
import urllib.error
from contextlib import nullcontext
from pathlib import Path

import pytest

from aap_demo import __version__

ROOT = Path(__file__).resolve().parents[2]


def _state_script():
    path = ROOT / ".github/scripts/pypi_version_state.py"
    spec = importlib.util.spec_from_file_location("pypi_version_state", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _http_error(code: int):
    def opener(url: str, timeout: int):
        raise urllib.error.HTTPError(url, code, "error", None, io.BytesIO())  # type: ignore[arg-type]

    return opener


def test_package_version_stays_a_development_release() -> None:
    assert _state_script().is_allowed(__version__)


def test_the_check_reads_the_real_package_version() -> None:
    text = (ROOT / "src/aap_demo/__init__.py").read_text(encoding="utf-8")
    assert _state_script().read_version(text) == __version__


@pytest.mark.parametrize("version", ["2.0.0", "2.0.0rc1", "2.0.0.dev", "2.1.0.dev1", "2.0.0.dev1x"])
def test_only_a_2_0_0_development_version_may_publish(version: str) -> None:
    assert not _state_script().is_allowed(version)


def test_a_version_on_pypi_is_published() -> None:
    assert _state_script().is_published("2.0.0.dev1", opener=lambda url, timeout: nullcontext())


def test_a_version_missing_from_pypi_is_not_published() -> None:
    assert not _state_script().is_published("2.0.0.dev9", opener=_http_error(404))


def test_a_pypi_outage_fails_instead_of_uploading() -> None:
    with pytest.raises(urllib.error.HTTPError):
        _state_script().is_published("2.0.0.dev9", opener=_http_error(503))


def test_pypi_workflow_publishes_from_main_only() -> None:
    workflow = (ROOT / ".github/workflows/pypi-publish.yaml").read_text(encoding="utf-8")
    # PyYAML 1.1 would read ``on`` as true, so keep this a text check.
    push = workflow.split("on:", 1)[1].split("jobs:", 1)[0]
    assert "branches: [main]" in push
    assert "v2" not in push
    assert "src/aap_demo/__init__.py" in push
    assert re.search(r"(?<![\w.])2\.0\.0(?!\.)", workflow) is None

    jobs = workflow.split("jobs:", 1)[1]
    assert "if: needs.check.outputs.published == 'false'" in jobs
    assert "needs: build" in jobs

    note = (ROOT / "docs/v2-to-main.md").read_text(encoding="utf-8")
    assert '__version__ = "2.0.0.dev2"' in note or "`2.0.0.dev2`" in note
    assert "Do not publish `2.0.0`" in note
    assert "src/aap_demo/__init__.py" in note
