"""The release job attaches the files PyPI serves, checked against PyPI's sha256."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import subprocess
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
    assert 'github_release_state.py "$VERSION"' in job


def test_release_runs_queue_per_version() -> None:
    job = _release_job()
    assert "group: github-release-${{ needs.check.outputs.version }}" in job
    assert "cancel-in-progress: false" in job


def _state():
    path = ROOT / ".github/scripts/github_release_state.py"
    spec = importlib.util.spec_from_file_location("github_release_state", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class _Gh:
    """Stands in for gh: answers ``release view`` and records every call."""

    def __init__(self, view: subprocess.CompletedProcess, delete_rc: int = 0) -> None:
        self.view = view
        self.delete_rc = delete_rc
        self.calls: list = []

    def __call__(self, argv: list) -> subprocess.CompletedProcess:
        self.calls.append(argv)
        if argv[:3] == ["gh", "release", "view"]:
            return self.view
        if argv[:3] == ["gh", "release", "delete"]:
            return subprocess.CompletedProcess(argv, self.delete_rc, "", "delete failed")
        raise AssertionError(f"unexpected gh call {argv}")


def _view(rc: int = 0, *, draft: bool = False, author: str = "", stderr: str = ""):
    stdout = json.dumps({"isDraft": draft, "author": {"login": author}}) if rc == 0 else ""
    return subprocess.CompletedProcess(["gh"], rc, stdout, stderr)


def test_a_published_release_is_left_alone() -> None:
    gh = _Gh(_view(draft=False, author="github-actions[bot]"))
    assert _state().release_exists("2.0.0rc1", run=gh) is True
    assert len(gh.calls) == 1


def test_a_missing_release_is_created() -> None:
    gh = _Gh(_view(1, stderr="release not found"))
    assert _state().release_exists("2.0.0rc1", run=gh) is False


def test_an_api_error_fails_instead_of_looking_missing() -> None:
    gh = _Gh(_view(1, stderr="HTTP 502: Bad Gateway"))
    with pytest.raises(SystemExit, match="HTTP 502"):
        _state().release_exists("2.0.0rc1", run=gh)


def test_a_draft_left_by_an_interrupted_run_is_deleted_and_recreated() -> None:
    gh = _Gh(_view(draft=True, author="github-actions[bot]"))
    assert _state().release_exists("2.0.0rc1", run=gh) is False
    assert gh.calls[-1] == ["gh", "release", "delete", "v2.0.0rc1", "--yes"]


def test_a_failed_draft_delete_fails_the_job() -> None:
    gh = _Gh(_view(draft=True, author="github-actions[bot]"), delete_rc=1)
    with pytest.raises(SystemExit, match="delete v2.0.0rc1 failed"):
        _state().release_exists("2.0.0rc1", run=gh)


def test_a_draft_someone_else_made_is_never_deleted() -> None:
    gh = _Gh(_view(draft=True, author="aknochow"))
    with pytest.raises(SystemExit, match="draft release made by aknochow"):
        _state().release_exists("2.0.0rc1", run=gh)
    assert all(call[:3] != ["gh", "release", "delete"] for call in gh.calls)


def test_a_stalled_gh_call_fails_instead_of_hanging(monkeypatch) -> None:
    state = _state()

    def stalled(*args, **kwargs):
        assert kwargs["timeout"] == state.GH_TIMEOUT_SECONDS
        raise subprocess.TimeoutExpired(args[0], kwargs["timeout"])

    monkeypatch.setattr(state.subprocess, "run", stalled)
    with pytest.raises(SystemExit, match="did not finish within"):
        state.release_exists("2.0.0rc1")


def test_check_reports_the_version_for_the_release_job() -> None:
    workflow = (ROOT / ".github/workflows/pypi-publish.yaml").read_text(encoding="utf-8")
    assert "version: ${{ steps.state.outputs.version }}" in workflow
    script = (ROOT / ".github/scripts/pypi_version_state.py").read_text(encoding="utf-8")
    assert 'output.write(f"version={version}\\n")' in script
