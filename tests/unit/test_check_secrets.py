"""``make check-secrets`` stays pinned and does not rewrite the baseline."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from typing import Any, Dict, List

ROOT = Path(__file__).resolve().parents[2]


def test_secret_scan_is_pinned_and_read_only() -> None:
    script = (ROOT / "scripts/check-secrets.sh").read_text(encoding="utf-8")
    workflow = (ROOT / ".github/workflows/lint.yaml").read_text(encoding="utf-8")
    makefile = (ROOT / "lint.mk").read_text(encoding="utf-8")
    hook = (ROOT / ".pre-commit-config.yaml").read_text(encoding="utf-8")

    assert "detect-secrets==1.5.0" in workflow
    assert "detect-secrets==1.5.0" in hook
    assert "check-secrets.sh" in makefile
    assert "detect-secrets scan --baseline" not in script
    assert "git diff --exit-code -- .secrets.baseline" in script
    assert "1.5.0" in script
    assert "compare_secrets.py" in script


def _document(path: Path, results: Dict[str, List[Dict[str, Any]]]) -> str:
    path.write_text(json.dumps({"results": results}), encoding="utf-8")
    return str(path)


def _finding(secret: str, line: int = 1) -> Dict[str, Any]:
    return {"type": "Hex High Entropy String", "hashed_secret": secret, "line_number": line}


def _compare() -> Any:
    spec = importlib.util.spec_from_file_location(
        "compare_secrets", ROOT / "scripts/compare_secrets.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_a_replaced_secret_is_caught_when_the_total_stays_the_same(tmp_path: Path) -> None:
    baseline = _document(tmp_path / "base.json", {"a.py": [_finding("old")]})
    scan = _document(tmp_path / "scan.json", {"a.py": [_finding("new")]})
    assert list(_compare().new_findings(scan, baseline)) == [
        ("a.py", "Hex High Entropy String", "new")
    ]


def test_a_moved_or_removed_secret_passes(tmp_path: Path) -> None:
    baseline = _document(tmp_path / "base.json", {"a.py": [_finding("x"), _finding("y", 2)]})
    scan = _document(tmp_path / "scan.json", {"a.py": [_finding("x", 9)]})
    assert not _compare().new_findings(scan, baseline)


def test_a_second_copy_of_a_known_secret_is_caught(tmp_path: Path) -> None:
    baseline = _document(tmp_path / "base.json", {"a.py": [_finding("x")]})
    scan = _document(tmp_path / "scan.json", {"a.py": [_finding("x"), _finding("x", 2)]})
    assert _compare().new_findings(scan, baseline)
