"""The release job attaches the files PyPI serves, checked against PyPI's sha256."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
WHEEL = b"wheel bytes"
SDIST = b"sdist bytes"


def _script():
    path = ROOT / ".github/scripts/pypi_release_files.py"
    spec = importlib.util.spec_from_file_location("pypi_release_files", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _entry(name: str, kind: str, data: bytes, *, digest: str = "") -> dict:
    return {
        "filename": name,
        "packagetype": kind,
        "url": f"https://files.example/{name}",
        "digests": {"sha256": digest or hashlib.sha256(data).hexdigest()},
    }


def _opener(files: list, blobs: dict):
    def opener(url: str, timeout: int):
        if url.endswith("/json"):
            return io.BytesIO(json.dumps({"urls": files}).encode())
        return io.BytesIO(blobs[url])

    return opener


def test_release_files_need_a_wheel_and_an_sdist() -> None:
    files = [_entry("aap_demo-2.0.0rc1-py3-none-any.whl", "bdist_wheel", WHEEL)]
    with pytest.raises(SystemExit, match="needs a wheel and an sdist"):
        _script().release_files("2.0.0rc1", opener=_opener(files, {}))


def test_downloads_match_pypi_sha256(tmp_path: Path) -> None:
    files = [
        _entry("aap_demo-2.0.0rc1-py3-none-any.whl", "bdist_wheel", WHEEL),
        _entry("aap_demo-2.0.0rc1.tar.gz", "sdist", SDIST),
    ]
    blobs = {files[0]["url"]: WHEEL, files[1]["url"]: SDIST}
    script = _script()
    opener = _opener(files, blobs)
    for entry in script.release_files("2.0.0rc1", opener=opener):
        script.download(entry, tmp_path, opener=opener)
    assert (tmp_path / "aap_demo-2.0.0rc1-py3-none-any.whl").read_bytes() == WHEEL
    assert (tmp_path / "aap_demo-2.0.0rc1.tar.gz").read_bytes() == SDIST


def test_a_mismatched_download_fails_and_writes_nothing(tmp_path: Path) -> None:
    entry = _entry("aap_demo-2.0.0rc1.tar.gz", "sdist", SDIST, digest="0" * 64)
    with pytest.raises(SystemExit, match="does not match"):
        _script().download(entry, tmp_path, opener=_opener([], {entry["url"]: SDIST}))
    assert not list(tmp_path.iterdir())


def test_a_pypi_filename_cannot_leave_the_destination(tmp_path: Path) -> None:
    entry = _entry("../escape.tar.gz", "sdist", SDIST)
    path = _script().download(entry, tmp_path, opener=_opener([], {entry["url"]: SDIST}))
    assert path.parent == tmp_path


def _release_job() -> str:
    workflow = (ROOT / ".github/workflows/pypi-publish.yaml").read_text(encoding="utf-8")
    return workflow.split("\n  release:\n", 1)[1]


def test_release_job_runs_after_publish_or_an_existing_upload_on_main_only() -> None:
    job = _release_job()
    assert "needs: [check, publish]" in job
    assert "github.ref == 'refs/heads/main'" in job
    assert "needs.check.result == 'success'" in job
    assert "needs.publish.result == 'success'" in job
    assert "needs.publish.result == 'skipped' && needs.check.outputs.published == 'true'" in job


def test_only_the_release_job_can_write_contents() -> None:
    workflow = (ROOT / ".github/workflows/pypi-publish.yaml").read_text(encoding="utf-8")
    head, job = workflow.split("\n  release:\n", 1)
    assert "contents: write" not in head
    assert "contents: write" in job


def test_release_tags_the_commit_that_set_the_version() -> None:
    job = _release_job()
    assert '-S "__version__ = \\"$VERSION\\""' in job
    assert '--target "$target"' in job
    assert "--prerelease" in job
    assert 'gh release view "v$VERSION"' in job


def test_release_runs_queue_per_version() -> None:
    job = _release_job()
    assert "group: github-release-${{ needs.check.outputs.version }}" in job
    assert "cancel-in-progress: false" in job


def test_only_a_missing_release_counts_as_missing() -> None:
    job = _release_job()
    assert "grep -q 'release not found'" in job
    assert ">/dev/null 2>&1" not in job


def test_check_reports_the_version_for_the_release_job() -> None:
    workflow = (ROOT / ".github/workflows/pypi-publish.yaml").read_text(encoding="utf-8")
    assert "version: ${{ steps.state.outputs.version }}" in workflow
    script = (ROOT / ".github/scripts/pypi_version_state.py").read_text(encoding="utf-8")
    assert 'output.write(f"version={version}\\n")' in script
