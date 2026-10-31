"""The v2 beta stays 2.0.0.dev1 and does not publish 2.0.0."""

from __future__ import annotations

import re
from pathlib import Path

from aap_demo import __version__

ROOT = Path(__file__).resolve().parents[2]


def test_package_version_stays_2_0_0_dev1() -> None:
    assert __version__ == "2.0.0.dev1"


def test_pypi_workflow_publishes_from_main_only() -> None:
    workflow = (ROOT / ".github/workflows/pypi-publish.yaml").read_text(encoding="utf-8")
    # PyYAML 1.1 would read ``on`` as true, so keep this a text check.
    push = workflow.split("on:", 1)[1].split("jobs:", 1)[0]
    assert "branches: [main]" in push
    assert "v2" not in push
    assert "src/aap_demo/__init__.py" in push
    assert re.search(r"(?<![\w.])2\.0\.0(?!\.)", workflow) is None

    note = (ROOT / "docs/v2-to-main.md").read_text(encoding="utf-8")
    assert '__version__ = "2.0.0.dev1"' in note or "`2.0.0.dev1`" in note
    assert "Do not publish `2.0.0`" in note
    assert "src/aap_demo/__init__.py" in note
