"""``make check-secrets`` stays pinned and does not rewrite the baseline."""

from __future__ import annotations

from pathlib import Path

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
